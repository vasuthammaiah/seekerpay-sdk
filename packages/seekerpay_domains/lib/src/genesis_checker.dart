import 'package:seekerpay_core/seekerpay_core.dart';

/// Verifies whether a wallet holds a recognised SeekerPay genesis token.
///
/// Accepted tokens (Token-2022, verified via Helius DAS `getAssetsByOwner`):
///   • Seeker Genesis Token  — 7CGD8hiRaEESMqYKs5LYn7Q9aR3h48saYVLms4qFfZPH
///   • Chapter 2 Preorder Token — 2DMMamkkxQ6zDMBtkFp8KH7FoWzBMBA1CGTYwom4QH6Z
///
/// Standard `getTokenAccountsByOwner` cannot surface Token-2022 assets, so the
/// Helius DAS API is used instead. Each asset's `id` field is the mint address.
class GenesisChecker {
  final RpcClient _rpc;

  /// All mint addresses that grant verified status.
  static const _verifiedMints = {
    '7CGD8hiRaEESMqYKs5LYn7Q9aR3h48saYVLms4qFfZPH', // Seeker Genesis Token
    '2DMMamkkxQ6zDMBtkFp8KH7FoWzBMBA1CGTYwom4QH6Z', // Chapter 2 Preorder Token
  };

  GenesisChecker(this._rpc);

  /// Returns `true` when [address] holds at least one verified genesis token.
  Future<bool> hasGenesisToken(String address) async {
    try {
      final assets = await _rpc.getAssetsByOwner(address);
      for (final asset in assets) {
        if (_verifiedMints.contains(asset['id'])) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
