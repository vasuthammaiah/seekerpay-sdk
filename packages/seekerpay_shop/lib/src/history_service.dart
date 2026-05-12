import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'order_model.dart';
import 'product_model.dart';
import 'product_catalog_service.dart';
import 'storage/arweave_order_service.dart';

class LocalHistoryService {
  static const _fileName = 'seekerpay_history.json';
  Future<File> get _file async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }
  Future<Map<String, dynamic>> loadHistory() async {
    try {
      final f = await _file;
      if (!await f.exists()) return {};
      final s = await f.readAsString();
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) { return {}; }
  }
  Future<void> saveHistory(Map<String, dynamic> data) async {
    try {
      final f = await _file;
      await f.writeAsString(jsonEncode(data));
    } catch (_) {}
  }
}

class HistoryState {
  final List<Order> orders;
  final List<Product> scannedProducts;

  /// True while a background Arweave sync is in progress.
  final bool isSyncing;
  final Set<String> syncedOrderIds;

  /// Live status updated per step during sync (e.g. "Uploading 2/5...").
  /// Cleared when sync ends.
  final String syncStatus;

  /// Persistent summary shown in the banner after sync completes
  /// (e.g. "2 UPLOADED · 1 PULLED" or "ALREADY UP TO DATE").
  final String syncSummary;

  const HistoryState({
    this.orders = const [],
    this.scannedProducts = const [],
    this.isSyncing = false,
    this.syncedOrderIds = const {},
    this.syncStatus = '',
    this.syncSummary = '',
  });

  HistoryState copyWith({
    List<Order>? orders,
    List<Product>? scannedProducts,
    bool? isSyncing,
    Set<String>? syncedOrderIds,
    String? syncStatus,
    String? syncSummary,
  }) {
    return HistoryState(
      orders: orders ?? this.orders,
      scannedProducts: scannedProducts ?? this.scannedProducts,
      isSyncing: isSyncing ?? this.isSyncing,
      syncedOrderIds: syncedOrderIds ?? this.syncedOrderIds,
      syncStatus: syncStatus ?? this.syncStatus,
      syncSummary: syncSummary ?? this.syncSummary,
    );
  }

  Map<String, dynamic> toJson() => {
    'orders': orders.map((o) => o.toJson()).toList(),
    'scannedProducts': scannedProducts.map((p) => p.toJson()).toList(),
  };

  factory HistoryState.fromJson(Map<String, dynamic> json) => HistoryState(
    orders: (json['orders'] as List? ?? []).map((o) => Order.fromJson(o)).toList(),
    scannedProducts: (json['scannedProducts'] as List? ?? []).map((p) => Product.fromJson(p)).toList(),
  );
}

class HistoryNotifier extends Notifier<HistoryState> {
  final _localService = LocalHistoryService();
  final _catalogService = ProductCatalogService();

  ArweaveOrderService? _arweave;
  String? _arweaveWalletAddress;

  bool _syncInProgress = false;

  @override
  HistoryState build() {
    _load();
    return const HistoryState();
  }

  Future<Set<String>> _loadSyncedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('skr_shop_arweave_synced');
    if (raw == null) return {};
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => e as String).toSet();
    } catch (_) { return {}; }
  }

  Future<void> _load() async {
    final data = await _localService.loadHistory();
    final synced = await _loadSyncedIds();
    state = HistoryState.fromJson(data).copyWith(syncedOrderIds: synced);
  }

  Future<ArweaveOrderService?> _getArweave(String walletAddress) async {
    if (_arweave != null && _arweaveWalletAddress == walletAddress) {
      return _arweave;
    }
    try {
      _arweave = await ArweaveOrderService.init(walletAddress: walletAddress);
      _arweaveWalletAddress = walletAddress;
      return _arweave;
    } catch (e) {
      if (kDebugMode) debugPrint('[HistoryNotifier] Arweave init failed: $e');
      return null;
    }
  }

  Future<ArweaveSyncResult?> startBackgroundSync(String walletAddress) async {
    if (walletAddress.isEmpty) {
      debugPrint('[SKR-Sync] startBackgroundSync: skipped — walletAddress is empty');
      return null;
    }
    if (_syncInProgress) {
      debugPrint('[SKR-Sync] startBackgroundSync: skipped — sync already in progress');
      return null;
    }

    _syncInProgress = true;
    final syncedBefore = await _loadSyncedIds();
    debugPrint('[SKR-Sync] ── START SYNC ──────────────────────────────────');
    debugPrint('[SKR-Sync] wallet   : ${walletAddress.substring(0, 8)}…${walletAddress.substring(walletAddress.length - 4)}');
    debugPrint('[SKR-Sync] local orders  : ${state.orders.length}');
    debugPrint('[SKR-Sync] already synced: ${syncedBefore.length}  ids=$syncedBefore');
    state = state.copyWith(isSyncing: true, syncedOrderIds: syncedBefore);

    try {
      debugPrint('[SKR-Sync] initialising ArweaveOrderService…');
      final arweave = await _getArweave(walletAddress);
      if (arweave == null) {
        debugPrint('[SKR-Sync] ERROR: ArweaveOrderService.init() returned null — aborting');
        state = state.copyWith(syncSummary: 'Sync failed (init error)');
        return null;
      }
      debugPrint('[SKR-Sync] ArweaveOrderService ready');

      final result = await arweave.sync(
        walletAddress: walletAddress,
        localOrders: List.unmodifiable(state.orders),
        onProgress: (status) {
          debugPrint('[SKR-Sync] progress: $status');
          state = state.copyWith(syncStatus: status);
        },
      );

      debugPrint('[SKR-Sync] ── SYNC RESULT ──');
      debugPrint('[SKR-Sync] uploaded : ${result.uploaded}');
      debugPrint('[SKR-Sync] pulled   : ${result.pulled.length}  ids=${result.pulled.map((o) => o.id).toList()}');
      debugPrint('[SKR-Sync] hasChanges: ${result.hasChanges}');

      final syncedAfter = await _loadSyncedIds();
      debugPrint('[SKR-Sync] syncedIds after: ${syncedAfter.length}  ids=$syncedAfter');

      // Build a persistent summary to show in the UI banner.
      final String summary;
      if (!result.hasChanges) {
        summary = 'Already up to date';
      } else {
        final parts = <String>[];
        if (result.uploaded > 0) parts.add('${result.uploaded} uploaded');
        if (result.pulled.isNotEmpty) parts.add('${result.pulled.length} pulled');
        summary = parts.join(' · ');
      }
      debugPrint('[SKR-Sync] summary: $summary');

      if (result.pulled.isNotEmpty) {
        final localIds = {for (final o in state.orders) o.id};
        final newOrders = result.pulled.where((o) => !localIds.contains(o.id)).toList();
        debugPrint('[SKR-Sync] new orders to merge: ${newOrders.length}');

        if (newOrders.isNotEmpty) {
          final merged = [...state.orders, ...newOrders]
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

          final nextProducts = List<Product>.from(state.scannedProducts);
          for (final order in newOrders) {
            for (final item in order.items) {
              final i = nextProducts.indexWhere((p) => p.barcode == item.product.barcode);
              if (i >= 0) { nextProducts[i] = item.product; } else { nextProducts.add(item.product); }
            }
          }

          state = state.copyWith(orders: merged, scannedProducts: nextProducts, syncedOrderIds: syncedAfter, syncSummary: summary);
          await _localService.saveHistory(state.toJson());
          debugPrint('[SKR-Sync] local history saved with ${merged.length} total orders');
        } else {
          state = state.copyWith(syncedOrderIds: syncedAfter, syncSummary: summary);
        }
      } else {
        state = state.copyWith(syncedOrderIds: syncedAfter, syncSummary: summary);
      }

      // --- Product catalog sync (pull only; uploads happen per-save) ---
      try {
        debugPrint('[SKR-Sync] product sync: pulling catalog from Arweave…');
        final productResult = await arweave.syncProducts(
          walletAddress: walletAddress,
          localProducts: List.unmodifiable(state.scannedProducts),
          onProgress: (s) => state = state.copyWith(syncStatus: s),
        );
        if (productResult.pulled.isNotEmpty) {
          debugPrint('[SKR-Sync] product sync: merging ${productResult.pulled.length} products');
          final nextProducts = List<Product>.from(state.scannedProducts);
          for (final p in productResult.pulled) {
            final idx = nextProducts.indexWhere((e) => e.barcode == p.barcode);
            if (idx >= 0) {
              nextProducts[idx] = p;
            } else {
              nextProducts.add(p);
            }
            await _catalogService.save(p);
          }
          state = state.copyWith(scannedProducts: nextProducts);
          await _localService.saveHistory(state.toJson());
        }
        debugPrint('[SKR-Sync] product sync done — ${productResult.pulled.length} pulled');
      } catch (e) {
        debugPrint('[SKR-Sync] product sync error: $e');
      }

      debugPrint('[SKR-Sync] ── DONE ─────────────────────────────────────');
      return result;
    } catch (e, st) {
      debugPrint('[SKR-Sync] ERROR: $e');
      debugPrint('[SKR-Sync] STACK: $st');
      state = state.copyWith(syncSummary: 'Sync failed');
      return null;
    } finally {
      _syncInProgress = false;
      state = state.copyWith(isSyncing: false, syncStatus: '');
    }
  }

  Future<void> deleteOrder(String orderId) async {
    final nextOrders = state.orders.where((o) => o.id != orderId).toList();
    state = state.copyWith(orders: nextOrders);
    await _localService.saveHistory(state.toJson());
  }

  Future<void> deleteProduct(String barcode) async {
    final nextProducts = state.scannedProducts.where((p) => p.barcode != barcode).toList();
    state = state.copyWith(scannedProducts: nextProducts);
    await _localService.saveHistory(state.toJson());
    await _catalogService.delete(barcode);
  }

  Future<void> updateProduct(Product product) async {
    final nextProducts = List<Product>.from(state.scannedProducts);
    final i = nextProducts.indexWhere((p) => p.barcode == product.barcode);
    if (i >= 0) { nextProducts[i] = product; } else { nextProducts.add(product); }
    state = state.copyWith(scannedProducts: nextProducts);
    await _localService.saveHistory(state.toJson());
    // Keep ProductCatalogService in sync so scan lookup picks up ownerPriceUsd
    await _catalogService.save(product);
    // Backup to Arweave when merchant saves/updates a product
    if (_arweaveWalletAddress != null && _arweaveWalletAddress!.isNotEmpty) {
      _backupProductToArweave(product, _arweaveWalletAddress!);
    }
  }

  Future<void> decrementStock(List<OrderItem> items) async { 
    final nextProducts = List<Product>.from(state.scannedProducts); 
    bool changed = false; 
    for (final item in items) { 
      final i = nextProducts.indexWhere((p) => p.barcode == item.product.barcode); 
      if (i >= 0 && nextProducts[i].stockLevel != null) { 
        final currentStock = nextProducts[i].stockLevel!; 
        nextProducts[i] = nextProducts[i].copyWith(stockLevel: (currentStock - item.quantity).clamp(0, 999999)); 
        await _catalogService.save(nextProducts[i]); 
        changed = true; 
      } 
    } 
    if (changed) { 
      state = state.copyWith(scannedProducts: nextProducts); 
      await _localService.saveHistory(state.toJson()); 
    } 
  } 

  Future<void> saveOrder(Order order, {String? walletAddress}) async {
    final nextOrders = state.orders.where((o) => o.id != order.id).toList();
    nextOrders.add(order);

    final nextProducts = List<Product>.from(state.scannedProducts);
    for (final item in order.items) {
      final i = nextProducts.indexWhere((p) => p.barcode == item.product.barcode);
      if (i >= 0) { nextProducts[i] = item.product; } else { nextProducts.add(item.product); }
      // Keep ProductCatalogService in sync
      await _catalogService.save(item.product);
    }

    state = state.copyWith(orders: nextOrders, scannedProducts: nextProducts);
    await _localService.saveHistory(state.toJson());

    if (walletAddress != null && walletAddress.isNotEmpty) {
      _backupToArweave(order, walletAddress);
    }
  }

  Future<void> clearHistory() async {
    state = const HistoryState();
    await _localService.saveHistory(state.toJson());
  }

  void _backupToArweave(Order order, String walletAddress) {
    debugPrint('[HistoryNotifier] _backupToArweave: orderId=${order.id} for wallet=$walletAddress');
    _getArweave(walletAddress).then((arweave) {
      if (arweave == null) {
        debugPrint('[HistoryNotifier] _backupToArweave: arweave service is null, skipping');
        return;
      }
      arweave.saveOrder(order, walletAddress).then((txId) async {
        debugPrint('[HistoryNotifier] _backupToArweave: successfully saved order=${order.id} txId=$txId');
        await arweave.markSynced(order.id);
        final synced = await _loadSyncedIds();
        debugPrint('[HistoryNotifier] _backupToArweave: updated syncedIds set, count=${synced.length}');
        state = state.copyWith(syncedOrderIds: synced);
      }).catchError((Object e) {
        debugPrint('[HistoryNotifier] _backupToArweave: ❌ Arweave backup failed for ${order.id}: $e');
      });
    });
  }

  void _backupProductToArweave(Product product, String walletAddress) {
    _getArweave(walletAddress).then((arweave) {
      if (arweave == null) return;
      arweave.saveProduct(product, walletAddress).catchError((Object e) {
        if (kDebugMode) debugPrint('[HistoryNotifier] Arweave product backup failed for ${product.barcode}: $e');
      });
    });
  }
}

final historyProvider = NotifierProvider<HistoryNotifier, HistoryState>(HistoryNotifier.new);
