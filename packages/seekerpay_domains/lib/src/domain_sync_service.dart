import 'domain_cache.dart';

/// Manages the local SQLite domain cache.
///
/// Domains are resolved on-demand by [SnsResolver] and persisted here
/// automatically after each successful resolution.  There is no background
/// sync or pre-populated domain list — every entry in the cache is the result
/// of a real, verified on-chain or API lookup.
class DomainSyncService {
  final DomainCache _cache;

  DomainSyncService(this._cache);

  /// Ensures the local SQLite database is open and ready.
  /// Called at app startup so the first lookup doesn't pay the DB-open cost.
  Future<void> syncSkrDomains() async {
    await _cache.init();
    print('DomainSync: Cache initialised (${await _cache.getCount()} entries).');
  }

  Future<List<Map<String, String>>> search(String query) async {
    return _cache.search(query);
  }

  Future<int> getCachedCount() async {
    return _cache.getCount();
  }
}
