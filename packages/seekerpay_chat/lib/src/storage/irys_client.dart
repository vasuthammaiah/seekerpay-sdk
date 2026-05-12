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
///    [SharedPreferences]. This is separate from the user's Solana wallet.
/// 2. Each upload is formatted as an **ANS-104 data item** signed with Ed25519
///    (Irys signature type 4 = Solana/Ed25519).
/// 3. Tags are **Avro-encoded** inside the data item per the ANS-104 spec.
/// 4. The signed data item is POSTed to a public Irys node.
class IrysClient {
  static const _prefSignPriv = 'skr_chat_irys_sign_priv';
  static const _prefSignPub = 'skr_chat_irys_sign_pub';

  static const _uploaderUrl = 'https://uploader.irys.xyz';
  static const _turboUrl   = 'https://turbo.ardrive.io';
  static const _node1Url   = 'https://node1.irys.xyz';
  static const _node2Url   = 'https://node2.irys.xyz';

  static final _ed25519 = Ed25519();

  final SimpleKeyPair _signingKeyPair;
  final Uint8List _signingPublicKeyBytes;

  IrysClient._(this._signingKeyPair, this._signingPublicKeyBytes);

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

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
    return IrysClient._(kp, Uint8List.fromList(pub.bytes));
  }

  // ---------------------------------------------------------------------------
  // Public upload API
  // ---------------------------------------------------------------------------

  Future<String> upload(Uint8List data, List<IrysTag> tags) async {
    final dataItem = await _buildDataItem(data, tags);

    final uploadUrls = [
      '$_uploaderUrl/tx/solana',
      '$_turboUrl/tx',
      '$_node1Url/tx/solana',
      '$_node2Url/tx/solana',
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

      // Any error — try next node.
      lastError = IrysUploadException(
        'Irys error at $url (${response.statusCode}): ${response.body}',
        response.statusCode,
      );
    }

    throw lastError ?? IrysUploadException('All Irys nodes failed', 503);
  }

  // ---------------------------------------------------------------------------
  // ANS-104 data item builder
  // ---------------------------------------------------------------------------

  Future<Uint8List> _buildDataItem(Uint8List data, List<IrysTag> tags) async {
    // Signature type 2 = generic Ed25519 (64-byte sig + 32-byte owner).
    // Type 4 (Solana) is no longer accepted by Irys/Turbo nodes.
    const sigType = 2;
    final tagsAvro = _encodeTagsAvro(tags);

    final signingData = _deepHash([
      utf8.encode('dataitem'),
      utf8.encode('1'),
      utf8.encode(sigType.toString()),
      _signingPublicKeyBytes,
      Uint8List(0), // target (empty)
      Uint8List(0), // anchor (empty)
      tagsAvro,
      data,
    ]);

    final sig = await _ed25519.sign(signingData, keyPair: _signingKeyPair);
    final sigBytes = Uint8List.fromList(sig.bytes);

    final builder = BytesBuilder();
    builder.add(_uint16LE(sigType));
    builder.add(sigBytes);
    builder.add(_signingPublicKeyBytes);
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

  static Uint8List _deepHash(dynamic data) {
    if (data is Uint8List || data is List<int>) {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
      final tag = utf8.encode('blob');
      final length = utf8.encode(bytes.length.toString());
      
      final tagHash = pkg_crypto.sha384.convert([...tag, ...length]).bytes;
      final dataHash = pkg_crypto.sha384.convert(bytes).bytes;
      return Uint8List.fromList(
        pkg_crypto.sha384.convert([...tagHash, ...dataHash]).bytes,
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

  static void _writeZigzag(List<int> buf, int value) {
    int n = (value << 1) ^ (value >> 63);
    while ((n & ~0x7F) != 0) {
      buf.add((n & 0x7F) | 0x80);
      n >>>= 7;
    }
    buf.add(n & 0x7F);
  }

  // ---------------------------------------------------------------------------
  // Helpers
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
