import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';

/// Persists chat messages and peer X25519 public key registrations in a local
/// SQLite database.
///
/// ### Schema
/// **messages** — one row per [ChatMessage]. Primary key is [ChatMessage.id].
/// **key_registry** — maps hashed wallet address → base64 X25519 public key.
///   Populated when a peer's key registration is fetched from Arweave.
class ChatCache {
  static const _dbName = 'seekerpay_chat.db';
  static const _messagesTable = 'messages';
  static const _keyRegistryTable = 'key_registry';
  static const _dbVersion = 1;

  Database? _db;

  // ---------------------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    if (_db != null) return;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      join(dbPath, _dbName),
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_messagesTable (
        id            TEXT PRIMARY KEY,
        tx_id         TEXT,
        from_addr     TEXT NOT NULL,
        to_addr       TEXT NOT NULL,
        type          TEXT NOT NULL,
        text          TEXT,
        solana_pay_url TEXT,
        caption       TEXT,
        timestamp     TEXT NOT NULL,
        status        TEXT NOT NULL,
        is_from_me    INTEGER NOT NULL,
        error         TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_messages_conv ON $_messagesTable (from_addr, to_addr, timestamp)');

    await db.execute('''
      CREATE TABLE $_keyRegistryTable (
        owner_hash      TEXT PRIMARY KEY,
        x25519_pub_b64  TEXT NOT NULL,
        arweave_tx_id   TEXT NOT NULL
      )
    ''');
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  /// Inserts or replaces a [ChatMessage] in the cache.
  Future<void> upsertMessage(ChatMessage msg) async {
    await init();
    await _db!.insert(
      _messagesTable,
      _messageToRow(msg),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Inserts or replaces a batch of messages efficiently.
  Future<void> upsertMessages(List<ChatMessage> messages) async {
    await init();
    final batch = _db!.batch();
    for (final msg in messages) {
      batch.insert(
        _messagesTable,
        _messageToRow(msg),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Returns all messages in the conversation between [myAddress] and [peerAddress],
  /// sorted oldest-first.
  Future<List<ChatMessage>> getConversation({
    required String myAddress,
    required String peerAddress,
  }) async {
    await init();
    final rows = await _db!.query(
      _messagesTable,
      where: '''
        (from_addr = ? AND to_addr = ?)
        OR
        (from_addr = ? AND to_addr = ?)
      ''',
      whereArgs: [myAddress, peerAddress, peerAddress, myAddress],
      orderBy: 'timestamp ASC',
    );
    return rows.map(_rowToMessage).toList();
  }

  /// Returns the most recent message for each distinct peer of [myAddress].
  /// Used to populate the conversations list.
  Future<List<ChatMessage>> getLatestPerConversation(String myAddress) async {
    await init();
    final rows = await _db!.rawQuery('''
      SELECT m.*
      FROM $_messagesTable m
      JOIN (
        SELECT
          CASE WHEN from_addr = ? THEN to_addr ELSE from_addr END AS peer_addr,
          MAX(timestamp) AS latest_ts
        FROM $_messagesTable
        WHERE from_addr = ? OR to_addr = ?
        GROUP BY peer_addr
      ) latest
        ON (
          CASE WHEN m.from_addr = ? THEN m.to_addr ELSE m.from_addr END
        ) = latest.peer_addr
       AND m.timestamp = latest.latest_ts
      WHERE m.from_addr = ? OR m.to_addr = ?
      ORDER BY m.timestamp DESC
    ''', [myAddress, myAddress, myAddress, myAddress, myAddress, myAddress]);
    return rows.map(_rowToMessage).toList();
  }

  /// Counts unread (incoming) messages for the conversation with [peerAddress].
  Future<int> unreadCount({
    required String myAddress,
    required String peerAddress,
  }) async {
    await init();
    final result = await _db!.rawQuery('''
      SELECT COUNT(*) FROM $_messagesTable
      WHERE from_addr = ? AND to_addr = ? AND status != ?
    ''', [peerAddress, myAddress, MessageStatus.sending.name]);
    return (result.first.values.first as int?) ?? 0;
  }

  /// Updates the [txId] and [status] of a message identified by [id].
  Future<void> updateMessageStatus(
    String id, {
    required MessageStatus status,
    String? txId,
    String? error,
  }) async {
    await init();
    final values = <String, dynamic>{
      'status': status.name,
      if (txId != null) 'tx_id': txId,
      if (error != null) 'error': error,
    };
    await _db!.update(
      _messagesTable,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Deletes a single cached message by [id].
  Future<void> deleteMessage(String id) async {
    await init();
    await _db!.delete(
      _messagesTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---------------------------------------------------------------------------
  // Key registry
  // ---------------------------------------------------------------------------

  /// Stores a peer's X25519 public key fetched from Arweave.
  Future<void> saveKeyRegistration({
    required String ownerHash,
    required Uint8List x25519PublicKey,
    required String arweaveTxId,
  }) async {
    await init();
    await _db!.insert(
      _keyRegistryTable,
      {
        'owner_hash': ownerHash,
        'x25519_pub_b64': base64.encode(x25519PublicKey),
        'arweave_tx_id': arweaveTxId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns the cached X25519 public key for [ownerHash], or `null` if not
  /// found. Call [ArweaveClient.queryKeyRegistration] to populate on cache miss.
  Future<Uint8List?> getX25519PublicKey(String ownerHash) async {
    await init();
    final rows = await _db!.query(
      _keyRegistryTable,
      where: 'owner_hash = ?',
      whereArgs: [ownerHash],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return base64.decode(rows.first['x25519_pub_b64'] as String);
  }

  // ---------------------------------------------------------------------------
  // Row ↔ model helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _messageToRow(ChatMessage msg) => {
    'id': msg.id,
    'tx_id': msg.txId,
    'from_addr': msg.from,
    'to_addr': msg.to,
    'type': msg.type.name,
    'text': msg.text,
    'solana_pay_url': msg.solanaPayUrl,
    'caption': msg.caption,
    'timestamp': msg.timestamp.toIso8601String(),
    'status': msg.status.name,
    'is_from_me': msg.isFromMe ? 1 : 0,
    'error': msg.error,
  };

  ChatMessage _rowToMessage(Map<String, dynamic> row) => ChatMessage(
    id: row['id'] as String,
    txId: row['tx_id'] as String?,
    from: row['from_addr'] as String,
    to: row['to_addr'] as String,
    type: MessageType.values.byName(row['type'] as String),
    text: row['text'] as String?,
    solanaPayUrl: row['solana_pay_url'] as String?,
    caption: row['caption'] as String?,
    timestamp: DateTime.parse(row['timestamp'] as String),
    status: MessageStatus.values.byName(row['status'] as String),
    isFromMe: (row['is_from_me'] as int) == 1,
    error: row['error'] as String?,
  );
}
