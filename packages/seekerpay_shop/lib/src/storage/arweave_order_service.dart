import 'dart:convert';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
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
    debugPrint('[SKR-Arweave] init — deriving enc key for wallet …${walletAddress.substring(walletAddress.length - 6)}');

    final irys = await IrysClient.init();
    final arweave = ArweaveOrderClient();

    final keyMaterial = utf8.encode('$walletAddress:$_hkdfInfo');
    final keyHash = pkg_crypto.sha256.convert(keyMaterial).bytes;
    final encKey = await _hkdf.deriveKey(
      secretKey: SecretKey(keyHash),
      info: utf8.encode(_hkdfInfo),
    );

    debugPrint('[SKR-Arweave] init done — IrysClient + ArweaveOrderClient ready');
    return ArweaveOrderService._(irys, arweave, encKey);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Uploads [order] to Arweave tagged with [walletAddress].
  ///
  /// Throws [IrysUploadException] on upload failure.
  Future<String> saveOrder(Order order, String walletAddress) async {
    debugPrint('[SKR-Arweave] saveOrder: orderId=${order.id}  items=${order.items.length}  totalUsd=${order.totalUsd}');
    final ownerHash = hashAddress(walletAddress);
    final plaintext = utf8.encode(jsonEncode(order.toJson()));
    debugPrint('[SKR-Arweave] saveOrder: plaintext size=${plaintext.length} bytes');
    final cipherBytes = await _encrypt(plaintext);
    debugPrint('[SKR-Arweave] saveOrder: encrypted size=${cipherBytes.length} bytes');

    final tags = [
      IrysTag('App-Name', _appName),
      IrysTag('Protocol', _protocol),
      IrysTag('Type', 'order_backup'),
      IrysTag('Owner-Hash', ownerHash),
      IrysTag('Order-Id', order.id),
    ];

    debugPrint('[SKR-Arweave] saveOrder: uploading to Irys with tags=${tags.map((t) => "${t.name}=${t.value}").toList()}');
    final txId = await _irys.upload(cipherBytes, tags);
    debugPrint('[SKR-Arweave] saveOrder: ✅ uploaded — txId=$txId');
    return txId;
  }

  /// Fetches and decrypts all backed-up orders for [walletAddress] from Arweave.
  ///
  /// Records that fail decryption are silently skipped (e.g. if they were
  /// uploaded by a different wallet address variant or are corrupted).
  Future<List<Order>> restoreOrders(String walletAddress) async {
    final ownerHash = hashAddress(walletAddress);
    debugPrint('[SKR-Arweave] restoreOrders: querying GraphQL  ownerHash=$ownerHash');
    final records = await _arweave.queryOrders(ownerHash: ownerHash);
    debugPrint('[SKR-Arweave] restoreOrders: found ${records.length} records on Arweave');

    final orders = <Order>[];
    for (int i = 0; i < records.length; i++) {
      final record = records[i];
      debugPrint('[SKR-Arweave] restoreOrders: [${i + 1}/${records.length}] fetching txId=${record.txId}  orderId=${record.tags["Order-Id"]}');
      try {
        final cipherBytes = await _arweave.fetchContent(record.txId);
        debugPrint('[SKR-Arweave] restoreOrders: fetched ${cipherBytes.length} bytes, decrypting…');
        final plainBytes = await _decrypt(cipherBytes);
        final json = jsonDecode(utf8.decode(plainBytes)) as Map<String, dynamic>;
        final order = Order.fromJson(json);
        debugPrint('[SKR-Arweave] restoreOrders: ✅ decrypted order id=${order.id}  items=${order.items.length}');
        orders.add(order);
      } catch (e) {
        debugPrint('[SKR-Arweave] restoreOrders: ❌ skipping txId=${record.txId}  error=$e');
      }
    }
    debugPrint('[SKR-Arweave] restoreOrders: returning ${orders.length} valid orders');
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
    void Function(String status)? onProgress,
  }) async {
    final syncedIds = await _loadSyncedIds();
    final localIdSet = {for (final o in localOrders) o.id};
    debugPrint('[SKR-Arweave] sync: localOrders=${localOrders.length}  alreadySynced=${syncedIds.length}');

    // --- Upload pass ---
    int uploaded = 0;
    final unsynced = localOrders.where((o) => !syncedIds.contains(o.id)).toList();
    debugPrint('[SKR-Arweave] sync: upload pass — ${unsynced.length} orders need upload  ids=${unsynced.map((o) => o.id).toList()}');

    for (int i = 0; i < unsynced.length; i++) {
      final order = unsynced[i];
      onProgress?.call('Uploading ${i + 1}/${unsynced.length}...');
      debugPrint('[SKR-Arweave] sync: uploading [${i + 1}/${unsynced.length}] orderId=${order.id}');
      try {
        await saveOrder(order, walletAddress);
        await _markSynced(order.id, syncedIds);
        uploaded++;
        debugPrint('[SKR-Arweave] sync: ✅ uploaded orderId=${order.id}');
      } catch (e) {
        debugPrint('[SKR-Arweave] sync: ❌ upload failed for orderId=${order.id}  error=$e');
      }
    }
    debugPrint('[SKR-Arweave] sync: upload pass done — $uploaded/${unsynced.length} succeeded');

    // --- Download pass ---
    final pulled = <Order>[];
    try {
      onProgress?.call('Checking Arweave...');
      debugPrint('[SKR-Arweave] sync: download pass — querying Arweave for remote orders…');
      final remote = await restoreOrders(walletAddress);
      debugPrint('[SKR-Arweave] sync: remote total=${remote.length}  localIdSet=${localIdSet.length}');
      final newRemote = remote.where((o) => !localIdSet.contains(o.id)).toList();
      debugPrint('[SKR-Arweave] sync: new remote orders (not in local)=${newRemote.length}  ids=${newRemote.map((o) => o.id).toList()}');
      for (int i = 0; i < newRemote.length; i++) {
        onProgress?.call('Pulling ${i + 1}/${newRemote.length}...');
        debugPrint('[SKR-Arweave] sync: pulling [${i + 1}/${newRemote.length}] orderId=${newRemote[i].id}');
        pulled.add(newRemote[i]);
        await _markSynced(newRemote[i].id, syncedIds);
      }
    } catch (e, st) {
      debugPrint('[SKR-Arweave] sync: ❌ download pass error: $e');
      debugPrint('[SKR-Arweave] sync: stack: $st');
    }
    debugPrint('[SKR-Arweave] sync: download pass done — ${pulled.length} pulled');

    return ArweaveSyncResult(uploaded: uploaded, pulled: pulled);
  }

  /// Marks [orderId] as successfully backed up so the next sync skips it.
  Future<void> markSynced(String orderId) async {
    debugPrint('[SKR-Arweave] markSynced: orderId=$orderId');
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
