import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'rpc_client.dart';
import 'wallet_state.dart';
import 'skr_token.dart';
import 'transaction_record.dart';
import 'transaction_parser.dart';
import 'balance_providers.dart';

/// Immutable state for the transaction activity feed.
class ActivityState {
  /// The list of parsed transaction records for the connected wallet.
  final List<TransactionRecord> transactions;

  /// `true` while transaction data is being fetched.
  final bool isLoading;

  /// Error message from the last failed load, if any.
  final String? error;

  /// Active filter value (e.g. `'all'`, `'send'`, `'receive'`).
  final String filter;

  ActivityState({
    required this.transactions,
    this.isLoading = false,
    this.error,
    this.filter = 'all',
  });

  /// Returns a copy of this state with the provided fields replaced.
  ActivityState copyWith({
    List<TransactionRecord>? transactions,
    bool? isLoading,
    String? error,
    String? filter,
  }) {
    return ActivityState(
      transactions: transactions ?? this.transactions,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      filter: filter ?? this.filter,
    );
  }
}

/// Riverpod [StateNotifier] that loads and caches the wallet's transaction
/// history from the Solana RPC.
///
/// Fetches up to 100 signatures for the wallet address and its SKR token
/// accounts, filters to the last 7 days, and parses each transaction into
/// [TransactionRecord] objects. Results are persisted to [SharedPreferences].
/// Requires a Helius RPC endpoint; returns an error state otherwise.
class ActivityService extends StateNotifier<ActivityState> {
  final RpcClient _rpc;
  final String _address;
  static const String _cacheKeyPrefix = 'cached_activity_';
  static const Duration _refreshInterval = Duration(seconds: 8);

  Timer? _refreshTimer;
  bool _isRefreshing = false;

  ActivityService(this._rpc, this._address)
      : super(ActivityState(transactions: [])) {
    _loadFromCache().then((_) {
      if (mounted) load();
    });
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (mounted) load();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFromCache() async {
    if (_address.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('$_cacheKeyPrefix$_address');
      if (cached != null) {
        final List<dynamic> list = jsonDecode(cached);
        final txs = list.map((e) => TransactionRecord.fromJson(e)).toList();
        state = state.copyWith(transactions: txs);
      }
    } catch (e) {
      print('Error loading activity from cache: $e');
    }
  }

  /// Updates the active transaction type filter without triggering a reload.
  void setFilter(String filter) {
    state = state.copyWith(filter: filter);
  }

  /// Fetches recent transactions from the RPC, parses them, and updates state.
  ///
  /// Only runs when a Helius API key is configured. Transactions older than
  /// 7 days are excluded. Results are cached for offline access.
  Future<void> load() async {
    if (!mounted || _address.isEmpty || _isRefreshing) return;

    if (!_rpc.rpcUrl.contains('helius-rpc.com')) {
      if (state.transactions.isEmpty) {
        state = state.copyWith(isLoading: false, error: 'Helius API key not configured');
      }
      return;
    }

    _isRefreshing = true;
    state = state.copyWith(isLoading: state.transactions.isEmpty, error: null);
    try {
      // Fetch signatures and filter to a rolling 7 days to reduce RPC load.
      final signatures = await _rpc.getSignaturesForAddress(_address, limit: 100);
      
      // Also pull signatures from the user's SKR token accounts
      final skrTokenAccounts = await _rpc.getTokenAccountAddressesByOwner(_address, SKRToken.mintAddress);
      final List<TxSignature> tokenSignatures = [];
      for (final acct in skrTokenAccounts) {
        final sigs = await _rpc.getSignaturesForAddress(acct, limit: 50);
        tokenSignatures.addAll(sigs);
      }

      final Map<String, TxSignature> merged = {
        for (final s in signatures) s.signature: s,
        for (final s in tokenSignatures) s.signature: s,
      };
      final allSignatures = merged.values.toList();
      
      if (allSignatures.isEmpty) {
        if (mounted) state = state.copyWith(isLoading: false, transactions: []);
        return;
      }

      final List<TransactionRecord> allTxs = [];
      final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
      final recentSigs = allSignatures.where((s) {
        if (s.blockTime == null) return true;
        final ts = DateTime.fromMillisecondsSinceEpoch(s.blockTime! * 1000);
        return ts.isAfter(sevenDaysAgo);
      }).toList()
        ..sort((a, b) => (b.blockTime ?? 0).compareTo(a.blockTime ?? 0));

      if (recentSigs.isEmpty) {
        if (mounted) state = state.copyWith(isLoading: false);
        return;
      }

      // To avoid flicker and long loading, only fetch what we don't have
      // or fetch a small batch first.
      const batchSize = 10;
      
      for (int i = 0; i < math.min(recentSigs.length, 20); i += batchSize) {
        final end = (i + batchSize < recentSigs.length) ? i + batchSize : recentSigs.length;
        final batch = recentSigs.sublist(i, end);
        final sigStrings = batch.map((s) => s.signature).toList();
        
        var results = await _rpc.getTransactions(sigStrings);
        final nonNullCount = results.where((r) => r != null).length;
        if (results.isEmpty || nonNullCount == 0) {
          results = [];
          for (final sig in sigStrings) {
            final single = await _rpc.getTransaction(sig);
            results.add(single);
            await Future.delayed(const Duration(milliseconds: 20));
          }
        }
        
        for (int j = 0; j < results.length; j++) {
          final data = results[j];
          if (data == null || data is! Map<String, dynamic>) {
            continue;
          }

          final records = TransactionParser.parseMany(
            txData: data,
            userAddress: _address,
            signature: batch[j].signature,
            fallbackTimestamp: batch[j].blockTime != null 
                ? DateTime.fromMillisecondsSinceEpoch(batch[j].blockTime! * 1000)
                : null,
          );
          
          for (final record in records) {
            if (record.timestamp.isAfter(sevenDaysAgo)) {
              allTxs.add(record);
            }
          }
        }
      }
      
      allTxs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      if (mounted) state = state.copyWith(isLoading: false, transactions: List.from(allTxs));

      // Cache the result
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_cacheKeyPrefix$_address', jsonEncode(allTxs.map((e) => e.toJson()).toList()));
    } catch (e) {
      if (mounted) {
        if (state.transactions.isEmpty) {
          state = state.copyWith(isLoading: false, error: e.toString());
        } else {
          state = state.copyWith(isLoading: false);
        }
      }
    } finally {
      _isRefreshing = false;
    }
  }
}

/// Auto-disposing provider for [ActivityService] scoped to the current wallet address.
final activityServiceProvider = StateNotifierProvider.autoDispose<ActivityService, ActivityState>((ref) {
  final rpc = ref.watch(rpcClientProvider);
  final wallet = ref.watch(walletStateProvider);
  return ActivityService(rpc, wallet.address ?? '');
});
