import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
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
/// Irys accepts uploads under 100 KiB at zero cost. Order backups are typically
/// 1–5 KiB — well within the limit.
///
/// ### Upload flow
/// 1. A dedicated **Ed25519 signing keypair** is generated once and stored in
///    [SharedPreferences]. This is separate from the user's Solana wallet.
/// 2. Each upload is formatted as an **ANS-104 data item** signed with Ed25519
///    (Irys signature type 4 = Solana/Ed25519).
/// 3. Tags are **Avro-encoded** inside the data item per the ANS-104 spec.
/// 4. The signed data item is POSTed to a public Irys node.
class IrysClient {
  static const _prefSignPriv = 'skr_shop_irys_sign_priv';
  static const _prefSignPub = 'skr_shop_irys_sign_pub';

  /// Irys node that accepts Solana / Ed25519 signed data items.
  static const _node1Url = 'https://node1.irys.xyz';
  static const _node2Url = 'https://node2.irys.xyz';

  static final _ed25519 = Ed25519();

  final SimpleKeyPair _signingKeyPair;
  final Uint8List _signingPublicKeyBytes;
  final Uint8List _signingPrivateKeyBytes;

  IrysClient._(
      this._signingKeyPair, this._signingPublicKeyBytes, this._signingPrivateKeyBytes);

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  static Future<IrysClient> init() async {
    final prefs = await SharedPreferences.getInstance();
    final privB64 = prefs.getString(_prefSignPriv);
    final pubB64 = prefs.getString(_prefSignPub);

    if (privB64 != null && pubB64 != null) {
      debugPrint('[SKR-Irys] init: loaded existing Ed25519 keypair from prefs');
      final privBytes = base64.decode(privB64);
      final pubBytes = base64.decode(pubB64);
      final kp = SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
      return IrysClient._(
        kp,
        Uint8List.fromList(pubBytes),
        Uint8List.fromList(privBytes),
      );
    }

    debugPrint('[SKR-Irys] init: generating new Ed25519 keypair (first run)');
    final kp = await _ed25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final priv = await kp.extractPrivateKeyBytes();
    await prefs.setString(_prefSignPriv, base64.encode(priv));
    await prefs.setString(_prefSignPub, base64.encode(pub.bytes));
    debugPrint('[SKR-Irys] init: new keypair saved — pubKey=${base64.encode(pub.bytes).substring(0, 12)}…');
    return IrysClient._(
      kp,
      Uint8List.fromList(pub.bytes),
      Uint8List.fromList(priv),
    );
  }

  /// Raw private key bytes — used by [ArweaveOrderService] to derive an
  /// encryption key via HKDF, so orders are encrypted to this device's key.
  Uint8List get privateKeyBytes => _signingPrivateKeyBytes;

  // ---------------------------------------------------------------------------
  // Public upload API
  // ---------------------------------------------------------------------------

  Future<String> upload(Uint8List data, List<IrysTag> tags) async {
    debugPrint('[SKR-Irys] upload: building ANS-104 data item  dataSize=${data.length} bytes  tags=${tags.map((t) => "${t.name}=${t.value}").toList()}');
    final dataItem = await _buildDataItem(data, tags);
    debugPrint('[SKR-Irys] upload: data item size=${dataItem.length} bytes');

    final uploadUrls = [
      '$_node1Url/tx/solana',
      '$_node2Url/tx/solana',
    ];

    IrysUploadException? lastError;

    for (final url in uploadUrls) {
      debugPrint('[SKR-Irys] upload: POST $url');
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
        debugPrint('[SKR-Irys] upload: ❌ network error at $url  error=$e');
        lastError = IrysUploadException('Network error at $url: $e', 0);
        continue;
      }

      debugPrint('[SKR-Irys] upload: response status=${response.statusCode}  body=${response.body.substring(0, response.body.length.clamp(0, 300))}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final txId = body['id'] as String?;
        if (txId == null || txId.isEmpty) {
          debugPrint('[SKR-Irys] upload: ❌ empty txId in response  body=${response.body}');
          throw IrysUploadException(
              'Irys returned empty tx id', response.statusCode);
        }
        debugPrint('[SKR-Irys] upload: ✅ success  txId=$txId');
        return txId;
      }

      // 429 (rate limit): try next node.
      if (response.statusCode == 429) {
        debugPrint('[SKR-Irys] upload: ❌ rate limited at $url (429) — trying next node');
        lastError = IrysUploadException(
          'Irys rate limited at $url (429): ${response.body}',
          response.statusCode,
        );
        continue;
      }

      // 400/401/403/422 = definite client/auth error — abort immediately.
      if (response.statusCode >= 400 && response.statusCode < 500) {
        debugPrint('[SKR-Irys] upload: ❌ client error ${response.statusCode} at $url — aborting  body=${response.body}');
        throw IrysUploadException(
          'Irys rejected upload at $url (${response.statusCode}): ${response.body}',
          response.statusCode,
        );
      }

      // 5xx — try next node.
      debugPrint('[SKR-Irys] upload: ❌ ${response.statusCode} at $url — trying next node  body=${response.body}');
      lastError = IrysUploadException(
        'Irys error at $url (${response.statusCode}): ${response.body}',
        response.statusCode,
      );
    }

    debugPrint('[SKR-Irys] upload: ❌ all nodes failed  lastError=$lastError');
    throw lastError ?? IrysUploadException('All Irys nodes failed', 503);
  }

  // ---------------------------------------------------------------------------
  // ANS-104 data item builder
  // ---------------------------------------------------------------------------

  Future<Uint8List> _buildDataItem(Uint8List data, List<IrysTag> tags) async {
    // Signature type 4 = Solana/Ed25519 (64-byte sig + 32-byte owner).
    const sigType = 4;
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

    // THE CRITICAL FIX: The Irys SDK for Solana signs the HEX STRING ASCII BYTES 
    // of the deepHash, not the raw bytes.
    final signingDataHex = utf8.encode(_bytesToHex(signingData));

    final sig = await _ed25519.sign(signingDataHex, keyPair: _signingKeyPair);
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

  /// Computes the Arweave deepHash of [data], which is either a [Uint8List]
  /// (leaf) or a [List] of recursively hashable items.
  static Uint8List _deepHash(dynamic data) {
    if (data is Uint8List || data is List<int>) {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
      final tag = utf8.encode('blob');
      final length = utf8.encode(bytes.length.toString());
      
      // Arweave Deep Hash Leaf: sha384( sha384("blob" + len) + sha384(data) )
      final tagHash = pkg_crypto.sha384.convert([...tag, ...length]).bytes;
      final dataHash = pkg_crypto.sha384.convert(bytes).bytes;
      return Uint8List.fromList(
        pkg_crypto.sha384.convert([...tagHash, ...dataHash]).bytes,
      );
    }

    if (data is List) {
      final tag = utf8.encode('list');
      final length = utf8.encode(data.length.toString());
      
      // Arweave Deep Hash List: sha384( sha384("list" + len) ) -> acc
      // Then fold: acc = sha384( acc + deepHash(item) )
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

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

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
