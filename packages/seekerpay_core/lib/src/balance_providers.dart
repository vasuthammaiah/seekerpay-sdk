import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'rpc_client.dart';
import 'skr_token.dart';
import 'wallet_state.dart';

const _defaultRpcUrl = 'https://api.mainnet-beta.solana.com';
const _heliusBaseUrl = 'https://mainnet.helius-rpc.com/?api-key=';

/// Riverpod [StateNotifier] that manages the active Solana RPC endpoint URL.
///
/// Helius key takes priority over a custom URL; both fall back to the public
/// mainnet endpoint. Values are persisted to [SharedPreferences].
class RpcUrlNotifier extends StateNotifier<String> {
  String? _customRpcUrl;
  String? _heliusKey;

  RpcUrlNotifier() : super(_defaultRpcUrl) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _customRpcUrl = prefs.getString('rpc_url')?.trim();
    _heliusKey = prefs.getString('helius_api_key')?.trim();
    _recompute();
  }

  void _recompute() {
    // Helius key takes priority — keeps state consistent with the Helius
    // status shown in the profile screen regardless of any legacy custom URL.
    if (_heliusKey != null && _heliusKey!.isNotEmpty) {
      state = '$_heliusBaseUrl${_heliusKey!}';
      return;
    }
    if (_customRpcUrl != null && _customRpcUrl!.isNotEmpty) {
      state = _customRpcUrl!;
      return;
    }
    state = _defaultRpcUrl;
  }

  /// Persists and activates a custom RPC endpoint [url].
  /// Passing an empty string clears the override and reverts to the default.
  Future<void> setRpcUrl(String url) async {
    final normalized = url.trim();
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await prefs.remove('rpc_url');
      _customRpcUrl = null;
      _recompute();
      return;
    }
    await prefs.setString('rpc_url', normalized);
    _customRpcUrl = normalized;
    _recompute();
  }

  /// Persists and activates a Helius API [key], which takes priority over any
  /// custom RPC URL. Passing an empty string removes the key.
  Future<void> setHeliusKey(String key) async {
    final normalized = key.trim();
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await prefs.remove('helius_api_key');
      _heliusKey = null;
      _recompute();
      return;
    }
    await prefs.setString('helius_api_key', normalized);
    _heliusKey = normalized;
    _recompute();
  }
}

/// Provider exposing the currently active RPC endpoint URL as a [String].
final rpcUrlProvider = StateNotifierProvider<RpcUrlNotifier, String>((ref) {
  return RpcUrlNotifier();
});

/// Derived provider that is `true` when the active RPC URL points to Helius.
final hasHeliusKeyProvider = Provider<bool>((ref) {
  final rpcUrl = ref.watch(rpcUrlProvider);
  return rpcUrl.contains('helius-rpc.com');
});

/// Provider that creates an [RpcClient] from the current [rpcUrlProvider] value.
final rpcClientProvider = Provider<RpcClient>((ref) {
  final rpcUrl = ref.watch(rpcUrlProvider);
  return RpcClient(rpcUrl: rpcUrl);
});

/// Generic Riverpod [StateNotifier] for a wallet balance expressed as [BigInt].
///
/// Initialises from a [SharedPreferences] cache to avoid flicker, then fires a
/// live RPC refresh. Network errors are silently swallowed when data is already
/// available to preserve the last known value.
class BalanceNotifier extends StateNotifier<AsyncValue<BigInt>> {
  final String _cacheKey;
  final Future<BigInt> Function() _fetcher;

  BalanceNotifier(this._cacheKey, this._fetcher) : super(const AsyncValue.loading()) {
    _loadFromCache();
    refresh();
  }

  Future<void> _loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    if (cached != null) {
      state = AsyncValue.data(BigInt.parse(cached));
    }
  }

  /// Calls the underlying fetcher, updates state, and persists the result.
  Future<void> refresh() async {
    try {
      // Don't set to loading if we already have data to avoid flicker
      final balance = await _fetcher();
      state = AsyncValue.data(balance);
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, balance.toString());
    } catch (e, st) {
      if (state.hasValue) {
        // Only log if it's not a common network failure
        final errorStr = e.toString().toLowerCase();
        final isNetworkError = errorStr.contains('socketexception') || 
                              errorStr.contains('host lookup') || 
                              errorStr.contains('failed to connect') ||
                              errorStr.contains('xmlhttprequest');
        
        if (!isNetworkError) {
          print('Error refreshing balance: $e');
        }
      } else {
        state = AsyncValue.error(e, st);
      }
    }
  }
}

/// Provider that tracks the SKR token balance (in base units) for the connected wallet.
final skrBalanceProvider = StateNotifierProvider<BalanceNotifier, AsyncValue<BigInt>>((ref) {
  final walletState = ref.watch(walletStateProvider);
  final rpcClient = ref.watch(rpcClientProvider);
  
  return BalanceNotifier(
    'cached_skr_balance_${walletState.address}',
    () async {
      if (walletState.address == null) return BigInt.zero;
      return await rpcClient.getTokenAccountsByOwner(walletState.address!, SKRToken.mintAddress);
    },
  );
});

/// Provider that tracks the SOL balance (in lamports) for the connected wallet.
final solBalanceProvider = StateNotifierProvider<BalanceNotifier, AsyncValue<BigInt>>((ref) {
  final walletState = ref.watch(walletStateProvider);
  final rpcClient = ref.watch(rpcClientProvider);
  
  return BalanceNotifier(
    'cached_sol_balance_${walletState.address}',
    () async {
      if (walletState.address == null) return BigInt.zero;
      return await rpcClient.getBalance(walletState.address!);
    },
  );
});
