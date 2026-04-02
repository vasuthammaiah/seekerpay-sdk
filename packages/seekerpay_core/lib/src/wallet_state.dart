import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'mwa_client.dart';

/// Immutable snapshot of the wallet connection state.
class WalletState {
  /// The Base58 public key of the connected wallet, or `null` when disconnected.
  final String? address;

  /// `true` while a connection attempt is in progress.
  final bool isConnecting;

  /// A human-readable error message from the last failed operation, if any.
  final String? error;

  WalletState({
    this.address,
    this.isConnecting = false,
    this.error,
  });

  /// Returns a copy of this state with the provided fields replaced.
  WalletState copyWith({
    String? address,
    bool? isConnecting,
    String? error,
  }) {
    return WalletState(
      address: address ?? this.address,
      isConnecting: isConnecting ?? this.isConnecting,
      error: error,
    );
  }
}

/// Riverpod [StateNotifier] that manages wallet connection lifecycle.
///
/// Persists the connected address to [SharedPreferences] so it survives
/// app restarts. Uses [MwaClient] for the actual MWA handshake.
class WalletStateNotifier extends StateNotifier<WalletState> {
  final MwaClient _mwaClient;

  WalletStateNotifier(this._mwaClient) : super(WalletState()) {
    _loadFromCache();
  }

  Future<void> _loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedAddress = prefs.getString('wallet_address');
    if (cachedAddress != null) {
      state = state.copyWith(address: cachedAddress);
    }
  }

  /// Initiates a wallet connection via MWA and persists the resulting address.
  ///
  /// Updates [WalletState.isConnecting] during the attempt and sets
  /// [WalletState.error] on failure.
  Future<void> connect() async {
    state = state.copyWith(isConnecting: true);
    try {
      final address = await _mwaClient.connectWalletAndGetAddress();
      if (address != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('wallet_address', address);
        state = state.copyWith(address: address, isConnecting: false);
      } else {
        state = state.copyWith(isConnecting: false, error: 'Connection failed');
      }
    } catch (e) {
      state = state.copyWith(isConnecting: false, error: e.toString());
    }
  }

  /// Disconnects the wallet, clears the persisted address, and resets state.
  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('wallet_address');
    _mwaClient.reset();
    state = WalletState();
  }
}

/// Global provider for [WalletStateNotifier] backed by the [MwaClient] singleton.
final walletStateProvider = StateNotifierProvider<WalletStateNotifier, WalletState>((ref) {
  return WalletStateNotifier(MwaClient.instance);
});
