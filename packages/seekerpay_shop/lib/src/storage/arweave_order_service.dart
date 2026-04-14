import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../order_model.dart';
import 'arweave_order_client.dart';
import 'irys_client.dart';

/// Result of a background sync operation.
class ArweaveSyncResult {
  /// Orders uploaded to Arweave that were only in local storage.
  final int uploaded;

  /// Orders pulled from Arweave that were not in local storage.
  final List<Order> pulled;

  const ArweaveSyncResult({required this.uploaded, required this.pulled});

  bool get hasChanges => uploaded > 0 || pulled.isNotEmpty;
}

/// Backs up and restores [Order] records on Arweave / Irys.
///
/// ### Storage model
/// Each order is uploaded as a separate small (<10 KiB) data item, making
/// every backup free (Irys charges nothing for uploads under 100 KiB).
///
/// ### Encryption
/// Orders are encrypted with **AES-256-GCM** before upload. The encryption key
/// is derived from the **wallet address** using HKDF-SHA256:
///
/// ```
/// keyMaterial = SHA-256(walletAddress + ":SKR-Shop-Orders-v1")
/// encKey      = HKDF(keyMaterial, info="SKR-Shop-Orders-v1", len=32)
/// ```
///
/// Because the key is derived from the wallet address (not a device-local key),
/// it is identical on every device and survives app uninstall/reinstall. Any
/// install that presents the same wallet address can decrypt its own backups.
///
/// ### Tagging
/// Each upload uses:
/// - `App-Name = SKR-Shop`
/// - `Protocol = 1`
/// - `Type = order_backup`
/// - `Owner-Hash = SHA256(walletAddress + ":SKR-Shop-v1")`
/// - `Order-Id = <order.id>`
class ArweaveOrderService {
  static const _appName = 'SKR-Shop';
  static const _protocol = '1';
  static const _hkdfInfo = 'SKR-Shop-Orders-v1';

  /// SharedPreferences key storing a JSON list of order IDs already backed up.
  static const _prefSyncedIds = 'skr_shop_arweave_synced';

  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  final IrysClient _irys;
  final ArweaveOrderClient _arweave;
  final SecretKey _encKey;

  ArweaveOrderService._(this._irys, this._arweave, this._encKey);

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  /// Creates an [ArweaveOrderService] bound to [walletAddress].
  ///
  /// The AES-256-GCM encryption key is derived deterministically from
  /// [walletAddress], so the same key is produced on any device / reinstall
  /// that connects the same wallet — enabling full backup recovery.
  static Future<ArweaveOrderService> init({required String walletAddress}) async {
    assert(walletAddress.isNotEmpty, 'walletAddress must not be empty');

    final irys = await IrysClient.init();
    final arweave = ArweaveOrderClient();

    // Derive a 32-byte AES-256 key from the wallet address.
    // Using wallet address as key material means any reinstall with the same
    // wallet can decrypt its backups without storing any secret locally.
    final keyMaterial = utf8.encode('$walletAddress:$_hkdfInfo');
    final keyHash = pkg_crypto.sha256.convert(keyMaterial).bytes;
    final encKey = await _hkdf.deriveKey(
      secretKey: SecretKey(keyHash),
      info: utf8.encode(_hkdfInfo),
    );

    return ArweaveOrderService._(irys, arweave, encKey);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Uploads [order] to Arweave tagged with [walletAddress].
  ///
  /// Throws [IrysUploadException] on upload failure.
  Future<String> saveOrder(Order order, String walletAddress) async {
    final ownerHash = hashAddress(walletAddress);
    final plaintext = utf8.encode(jsonEncode(order.toJson()));
    final cipherBytes = await _encrypt(plaintext);

    final tags = [
      IrysTag('App-Name', _appName),
      IrysTag('Protocol', _protocol),
      IrysTag('Type', 'order_backup'),
      IrysTag('Owner-Hash', ownerHash),
      IrysTag('Order-Id', order.id),
    ];

    final txId = await _irys.upload(cipherBytes, tags);
    return txId;
  }

  /// Fetches and decrypts all backed-up orders for [walletAddress] from Arweave.
  ///
  /// Records that fail decryption are silently skipped (e.g. if they were
  /// uploaded by a different wallet address variant or are corrupted).
  Future<List<Order>> restoreOrders(String walletAddress) async {
    final ownerHash = hashAddress(walletAddress);
    final records = await _arweave.queryOrders(ownerHash: ownerHash);

    final orders = <Order>[];
    for (final record in records) {
      try {
        final cipherBytes = await _arweave.fetchContent(record.txId);
        final plainBytes = await _decrypt(cipherBytes);
        final json =
            jsonDecode(utf8.decode(plainBytes)) as Map<String, dynamic>;
        orders.add(Order.fromJson(json));
      } catch (e) {
        print('[ArweaveOrderService] skipping record ${record.txId}: $e');
      }
    }
    return orders;
  }

  // ---------------------------------------------------------------------------
  // Sync — bidirectional: push unsynced locals up, pull Arweave-only down
  // ---------------------------------------------------------------------------

  /// Bidirectional sync for [walletAddress].
  ///
  /// - **Upload pass**: local orders not in the persisted "synced" set are
  ///   uploaded to Arweave and marked synced on success.
  /// - **Download pass**: Arweave orders not in [localOrders] are decrypted
  ///   and returned in [ArweaveSyncResult.pulled] for local merge.
  ///
  /// Individual failures are non-fatal; they'll be retried on the next call.
  Future<ArweaveSyncResult> sync({
    required String walletAddress,
    required List<Order> localOrders,
  }) async {
    final syncedIds = await _loadSyncedIds();
    final localIdSet = {for (final o in localOrders) o.id};

    // --- Upload pass ---
    int uploaded = 0;
    for (final order in localOrders) {
      if (syncedIds.contains(order.id)) continue;
      try {
        await saveOrder(order, walletAddress);
        await _markSynced(order.id, syncedIds);
        uploaded++;
      } catch (_) {
        // Leave un-synced; will retry on next call.
      }
    }

    // --- Download pass ---
    final pulled = <Order>[];
    try {
      final remote = await restoreOrders(walletAddress);
      for (final order in remote) {
        if (!localIdSet.contains(order.id)) {
          pulled.add(order);
          await _markSynced(order.id, syncedIds);
        }
      }
    } catch (_) {
      // Non-fatal; download will retry on next sync.
    }

    return ArweaveSyncResult(uploaded: uploaded, pulled: pulled);
  }

  /// Marks [orderId] as successfully backed up so the next sync skips it.
  Future<void> markSynced(String orderId) async {
    final syncedIds = await _loadSyncedIds();
    await _markSynced(orderId, syncedIds);
  }

  // ---------------------------------------------------------------------------
  // Synced-ID persistence
  // ---------------------------------------------------------------------------

  Future<Set<String>> _loadSyncedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefSyncedIds);
    if (raw == null) return {};
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => e as String).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _markSynced(String orderId, Set<String> current) async {
    current.add(orderId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSyncedIds, jsonEncode(current.toList()));
  }

  // ---------------------------------------------------------------------------
  // Encryption helpers (AES-256-GCM)
  // ---------------------------------------------------------------------------

  /// Wire format: `{ "v": 1, "n": "<nonce_b64>", "c": "<ciphertext+tag_b64>" }`
  Future<Uint8List> _encrypt(List<int> plaintext) async {
    final nonce = _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: _encKey,
      nonce: nonce,
    );
    final cipherWithTag =
        Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    final envelope = {
      'v': 1,
      'n': base64.encode(nonce),
      'c': base64.encode(cipherWithTag),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  Future<Uint8List> _decrypt(Uint8List cipherBytes) async {
    final envelope =
        jsonDecode(utf8.decode(cipherBytes)) as Map<String, dynamic>;
    final nonce = base64.decode(envelope['n'] as String);
    final cipherWithTag = base64.decode(envelope['c'] as String);

    if (cipherWithTag.length < 16) {
      throw const FormatException('Encrypted payload too short');
    }
    final cipherText =
        cipherWithTag.sublist(0, cipherWithTag.length - 16);
    final macBytes = cipherWithTag.sublist(cipherWithTag.length - 16);

    final plainBytes = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
      secretKey: _encKey,
    );
    return Uint8List.fromList(plainBytes);
  }

  // ---------------------------------------------------------------------------
  // Address hashing
  // ---------------------------------------------------------------------------

  /// SHA-256 of `"<walletAddress>:SKR-Shop-v1"` — used as the Arweave
  /// `Owner-Hash` tag so raw wallet addresses are never exposed in tags.
  static String hashAddress(String walletAddress) {
    final bytes = utf8.encode('$walletAddress:SKR-Shop-v1');
    return pkg_crypto.sha256.convert(bytes).toString();
  }
}
