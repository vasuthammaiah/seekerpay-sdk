import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:seekerpay_core/seekerpay_core.dart';
import 'genesis_checker.dart';
import 'sns_resolver.dart';
import 'domain_cache.dart';
import 'domain_sync_service.dart';

final domainCacheProvider = Provider<DomainCache>((ref) {
  return DomainCache();
});

final domainSyncServiceProvider = Provider<DomainSyncService>((ref) {
  final cache = ref.watch(domainCacheProvider);
  return DomainSyncService(cache);
});

final snsResolverProvider = ChangeNotifierProvider<SnsResolver>((ref) {
  final rpc = ref.watch(rpcClientProvider);
  final persistentCache = ref.watch(domainCacheProvider);
  return SnsResolver(rpc, persistentCache);
});

final genesisCheckerProvider = Provider<GenesisChecker>((ref) {
  final rpc = ref.watch(rpcClientProvider);
  return GenesisChecker(rpc);
});

final isSeekerVerifiedProvider = FutureProvider<bool>((ref) async {
  final wallet = ref.watch(walletStateProvider);
  if (wallet.address == null) return false;
  return ref.read(genesisCheckerProvider).hasGenesisToken(wallet.address!);
});

final isAddressVerifiedProvider = FutureProvider.family<bool, String>((ref, address) async {
  if (address.isEmpty) return false;
  return ref.read(genesisCheckerProvider).hasGenesisToken(address);
});
