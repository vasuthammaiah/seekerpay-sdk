import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DomainCache {
  static const String _dbName = 'seekerpay_domains.db';
  static const String _tableName = 'domains';
  
  Database? _db;

  Future<void> init() async {
    if (_db != null) return;
    
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, _dbName);

    _db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            domain  TEXT PRIMARY KEY,
            address TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_domain ON $_tableName (domain)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 → v2: wipe any stale / mock data from old builds
        await db.execute('DROP TABLE IF EXISTS $_tableName');
        await db.execute('''
          CREATE TABLE $_tableName (
            domain  TEXT PRIMARY KEY,
            address TEXT NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_domain ON $_tableName (domain)');
      },
    );
  }

  Future<void> saveDomains(Map<String, String> domains) async {
    await init();
    final batch = _db!.batch();
    
    // Clear existing to avoid stale data (optional, or just use INSERT OR REPLACE)
    // For a "once at startup" sync, replacing is good.
    for (final entry in domains.entries) {
      batch.insert(
        _tableName,
        {'domain': entry.key, 'address': entry.value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, String>>> search(String query) async {
    await init();
    final results = await _db!.query(
      _tableName,
      where: 'domain LIKE ?',
      whereArgs: ['%$query%'],
      limit: 20,
    );
    
    return results.map((e) => {
      'domain': e['domain'] as String,
      'address': e['address'] as String,
    }).toList();
  }

  Future<String?> resolve(String domain) async {
    await init();
    final results = await _db!.query(
      _tableName,
      where: 'domain = ?',
      whereArgs: [domain],
      limit: 1,
    );
    
    if (results.isEmpty) return null;
    return results.first['address'] as String;
  }

  Future<int> getCount() async {
    await init();
    final result = await _db!.rawQuery('SELECT COUNT(*) FROM $_tableName');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
