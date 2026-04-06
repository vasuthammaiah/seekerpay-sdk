import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// A tag attached to an Irys / Arweave data item.
class IrysTag {
  final String name;
  final String value;
  const IrysTag(this.name, this.value);
}

/// Uploads small data items (<100 KiB) to Arweave via the Irys bundler network.
///
/// ### Why free?
/// Irys accepts uploads under 100 KiB at zero cost. Text chat messages
/// are ~0.5–2 KiB including encryption overhead — well within the limit.
///
/// ### Upload flow
/// 1. A dedicated **Ed25519 signing keypair** is generated once and stored in
///    [SharedPreferences]. This is separate from the user's Solana wallet —
///    no MWA approval is required for each message.
/// 2. Each upload is formatted as an **ANS-104 data item** (the Arweave bundle
///    spec) signed with the Ed25519 key (Irys signature type 3 = Solana).
/// 3. Tags are **Avro-encoded** inside the data item as per the ANS-104 spec.
/// 4. The signed data item is POSTed to a public Irys node.
///    Response: `{ "id": "<arweave_tx_id>" }`.
///
/// The returned `txId` can be fetched immediately via
/// `https://arweave.net/<txId>` from the Irys gateway.
class IrysClient {
  static const _prefSignPriv = 'skr_chat_irys_sign_priv';
  static const _prefSignPub = 'skr_chat_irys_sign_pub';

  /// Irys node that accepts Solana / Ed25519 signed data items.
  /// Primary: new uploader node. Fallback: legacy node2.
  static const _nodeUrl = 'https://uploader.irys.xyz';
  static const _legacyNodeUrl = 'https://node2.irys.xyz';

  static final _ed25519 = Ed25519();

  final SimpleKeyPair _signingKeyPair;
  final Uint8List _signingPublicKeyBytes;

  IrysClient._(this._signingKeyPair, this._signingPublicKeyBytes);

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  /// Loads or creates the persistent Ed25519 signing keypair.
  static Future<IrysClient> init() async {
    final prefs = await SharedPreferences.getInstance();
    final privB64 = prefs.getString(_prefSignPriv);
    final pubB64 = prefs.getString(_prefSignPub);

    if (privB64 != null && pubB64 != null) {
      final privBytes = base64.decode(privB64);
      final pubBytes = base64.decode(pubB64);
      final kp = SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
      return IrysClient._(kp, Uint8List.fromList(pubBytes));
    }

    final kp = await _ed25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final priv = await kp.extractPrivateKeyBytes();
    await prefs.setString(_prefSignPriv, base64.encode(priv));
    await prefs.setString(_prefSignPub, base64.encode(pub.bytes));
    return IrysClient._(kp as SimpleKeyPair, Uint8List.fromList(pub.bytes));
  }

  // ---------------------------------------------------------------------------
  // Public upload API
  // ---------------------------------------------------------------------------

  /// Uploads [data] with [tags] to Arweave via Irys.
  ///
  /// Tries the primary uploader node (`/upload/solana`), then falls back to
  /// the legacy node (`/tx/solana`). Returns the Arweave transaction ID.
  /// Throws [IrysUploadException] on HTTP or signing errors.
  Future<String> upload(Uint8List data, List<IrysTag> tags) async {
    final dataItem = await _buildDataItem(data, tags);

    // Try new uploader endpoint first, then legacy node as fallback.
    final uploadUrls = [
      '$_nodeUrl/upload/solana',
      '$_legacyNodeUrl/tx/solana',
    ];

    IrysUploadException? lastError;

    for (final url in uploadUrls) {
      http.Response response;
      try {
        response = await http
            .post(
              Uri.parse(url),
              headers: {
                'Content-Type': 'application/octet-stream',
                'Accept': 'application/json',
              },
              body: dataItem,
            )
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        lastError = IrysUploadException('Network error: $e', 0);
        continue;
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final txId = body['id'] as String?;
        if (txId == null || txId.isEmpty) {
          throw IrysUploadException('Irys returned empty tx id', response.statusCode);
        }
        return txId;
      }

      // 4xx = client/format error — don't try other nodes, it will fail there too.
      if (response.statusCode >= 400 && response.statusCode < 500) {
        throw IrysUploadException(
          'Irys rejected upload (${response.statusCode}): ${response.body}',
          response.statusCode,
        );
      }

      // 5xx = server error — try next node.
      lastError = IrysUploadException(
        'Irys server error (${response.statusCode}): ${response.body}',
        response.statusCode,
      );
    }

    throw lastError ?? IrysUploadException('All Irys nodes failed', 503);
  }

  // ---------------------------------------------------------------------------
  // ANS-104 data item builder
  // ---------------------------------------------------------------------------

  /// Builds a signed ANS-104 data item for Irys with Ed25519 / Solana
  /// signature type (type 4).
  ///
  /// Layout:
  /// ```
  /// [2B  LE] signature type  = 4  (Solana/Ed25519)
  /// [64B   ] Ed25519 signature
  /// [32B   ] owner public key
  /// [1B    ] target presence  = 0 (no target)
  /// [1B    ] anchor presence  = 0 (no anchor)
  /// [8B  LE] tag count
  /// [8B  LE] tag byte count
  /// [NB    ] Avro-encoded tags
  /// [MB    ] data
  /// ```
  Future<Uint8List> _buildDataItem(
    Uint8List data,
    List<IrysTag> tags,
  ) async {
    // Signature type 4 = Solana (Ed25519, 64-byte sig + 32-byte owner) in the
    // current arbundles spec used by Irys nodes. Type 3 is Ethereum (secp256k1,
    // 65+65 bytes) and causes the parser to compute the wrong tags offset,
    // which makes tags_size appear astronomically large → "Tags are too large".
    const sigType = 4; // Solana / Ed25519
    final tagsAvro = _encodeTagsAvro(tags);

    // Build signing message via deepHash.
    final signingData = _deepHash([
      utf8.encode('dataitem'),
      utf8.encode('1'),
      utf8.encode(sigType.toString()),
      _signingPublicKeyBytes, // owner
      Uint8List(0), // target (empty)
      Uint8List(0), // anchor (empty)
      tagsAvro,
      data,
    ]);

    // Sign with Ed25519.
    final sig = await _ed25519.sign(signingData, keyPair: _signingKeyPair);
    final sigBytes = Uint8List.fromList(sig.bytes);

    // Assemble data item bytes.
    final builder = BytesBuilder();
    builder.add(_uint16LE(sigType));
    builder.add(sigBytes); // 64 bytes
    builder.add(_signingPublicKeyBytes); // 32 bytes
    builder.addByte(0); // no target
    builder.addByte(0); // no anchor
    builder.add(_uint64LE(tags.length));
    builder.add(_uint64LE(tagsAvro.length));
    builder.add(tagsAvro);
    builder.add(data);

    return builder.toBytes();
  }

  // ---------------------------------------------------------------------------
  // Arweave deepHash (SHA-384 based)
  // ---------------------------------------------------------------------------

  /// Computes the Arweave deepHash of [data], which is either a [Uint8List]
  /// (leaf) or a [List] of recursively hashable items.
  ///
  /// ```
  /// deepHash(bytes)  = SHA-384("blob" || len(bytes).toString() || bytes)
  /// deepHash(list)   = fold over items:
  ///     acc = SHA-384("list" || len(list).toString())
  ///     for each item: acc = SHA-384(acc || deepHash(item))
  /// ```
  static Uint8List _deepHash(dynamic data) {
    if (data is Uint8List || data is List<int>) {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
      final tag = utf8.encode('blob');
      final length = utf8.encode(bytes.length.toString());
      return Uint8List.fromList(
        pkg_crypto.sha384.convert([...tag, ...length, ...bytes]).bytes,
      );
    }

    if (data is List) {
      final tag = utf8.encode('list');
      final length = utf8.encode(data.length.toString());
      var acc = Uint8List.fromList(
        pkg_crypto.sha384.convert([...tag, ...length]).bytes,
      );
      for (final item in data) {
        final child = _deepHash(item);
        acc = Uint8List.fromList(
          pkg_crypto.sha384.convert([...acc, ...child]).bytes,
        );
      }
      return acc;
    }

    throw ArgumentError('deepHash: unsupported type ${data.runtimeType}');
  }

  // ---------------------------------------------------------------------------
  // Avro tag encoding (ANS-104 spec)
  // ---------------------------------------------------------------------------

  /// Encodes [tags] using the Apache Avro binary format required by ANS-104.
  ///
  /// Each tag is a `{name: bytes, value: bytes}` record. The array is prefixed
  /// with a zigzag-encoded element count and terminated with a 0 byte.
  static Uint8List _encodeTagsAvro(List<IrysTag> tags) {
    final buf = <int>[];
    _writeZigzag(buf, tags.length);
    for (final tag in tags) {
      final nameBytes = utf8.encode(tag.name);
      final valueBytes = utf8.encode(tag.value);
      _writeZigzag(buf, nameBytes.length);
      buf.addAll(nameBytes);
      _writeZigzag(buf, valueBytes.length);
      buf.addAll(valueBytes);
    }
    buf.add(0); // end-of-array marker
    return Uint8List.fromList(buf);
  }

  /// Writes [value] as an Avro zigzag-encoded variable-length integer.
  static void _writeZigzag(List<int> buf, int value) {
    int n = (value << 1) ^ (value >> 63);
    while ((n & ~0x7F) != 0) {
      buf.add((n & 0x7F) | 0x80);
      n >>>= 7;
    }
    buf.add(n & 0x7F);
  }

  // ---------------------------------------------------------------------------
  // Little-endian helpers
  // ---------------------------------------------------------------------------

  static Uint8List _uint16LE(int value) {
    return Uint8List(2)
      ..[0] = value & 0xFF
      ..[1] = (value >> 8) & 0xFF;
  }

  static Uint8List _uint64LE(int value) {
    final result = Uint8List(8);
    var v = value;
    for (int i = 0; i < 8; i++) {
      result[i] = v & 0xFF;
      v >>= 8;
    }
    return result;
  }
}

/// Thrown when an Irys upload fails.
class IrysUploadException implements Exception {
  final String message;
  final int statusCode;
  const IrysUploadException(this.message, this.statusCode);

  @override
  String toString() => 'IrysUploadException($statusCode): $message';
}
