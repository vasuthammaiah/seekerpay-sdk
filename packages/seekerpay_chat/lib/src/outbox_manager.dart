import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models/chat_message.dart';

/// An outbound [ChatMessage] queued for upload when a previous attempt failed
/// or the device was offline.
class OutboxEntry {
  /// The full message to retry.
  final ChatMessage message;

  /// Number of upload attempts made so far.
  final int attempts;

  /// Timestamp of the last failed attempt, or null on first enqueue.
  final DateTime? lastAttempt;

  const OutboxEntry({
    required this.message,
    this.attempts = 0,
    this.lastAttempt,
  });

  OutboxEntry copyWith({int? attempts, DateTime? lastAttempt}) => OutboxEntry(
        message: message,
        attempts: attempts ?? this.attempts,
        lastAttempt: lastAttempt ?? this.lastAttempt,
      );

  Map<String, dynamic> toJson() => {
        'message': message.toJson(),
        'attempts': attempts,
        'lastAttempt': lastAttempt?.toIso8601String(),
      };

  factory OutboxEntry.fromJson(Map<String, dynamic> json) => OutboxEntry(
        message: ChatMessage.fromJson(json['message'] as Map<String, dynamic>),
        attempts: json['attempts'] as int? ?? 0,
        lastAttempt: json['lastAttempt'] != null
            ? DateTime.parse(json['lastAttempt'] as String)
            : null,
      );
}

/// Persists outgoing [ChatMessage] objects that failed to upload to Irys.
///
/// Works identically to [PendingTransactionManager] in seekerpay_core:
/// entries are serialised as JSON strings in [SharedPreferences] under a
/// single list key. [ChatService] calls [retryAll] on every successful
/// network connection or on the periodic poll tick.
class ChatOutboxManager {
  static const _key = 'skr_chat_outbox';

  /// Stores [entry] in the outbox.
  ///
  /// When [incrementAttempts] is true, the stored attempt count is increased and
  /// [lastAttempt] is set to now. The updated attempt count is returned.
  Future<int> store(
    OutboxEntry entry, {
    bool incrementAttempts = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    final index = current.indexWhere((e) => e.message.id == entry.message.id);

    final existing = index == -1 ? null : current[index];
    final attempts = incrementAttempts
        ? ((existing?.attempts ?? entry.attempts) + 1)
        : (existing?.attempts ?? entry.attempts);
    final merged = entry.copyWith(
      attempts: attempts,
      lastAttempt: incrementAttempts
          ? DateTime.now()
          : (existing?.lastAttempt ?? entry.lastAttempt),
    );

    if (index == -1) {
      current.add(merged);
    } else {
      current[index] = merged;
    }
    await _persist(prefs, current);
    return attempts;
  }

  /// Backward-compatible wrapper for older call sites.
  Future<void> add(OutboxEntry entry) async {
    await store(entry);
  }

  /// Backward-compatible wrapper for older call sites.
  Future<void> recordAttempt(String messageId) async {
    final current = await getAll();
    final index = current.indexWhere((e) => e.message.id == messageId);
    if (index == -1) return;
    await store(current[index], incrementAttempts: true);
  }

  /// Removes the outbox entry for [messageId] after a successful upload.
  Future<void> remove(String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    current.removeWhere((e) => e.message.id == messageId);
    await _persist(prefs, current);
  }

  /// Returns all pending outbox entries.
  Future<List<OutboxEntry>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final strings = prefs.getStringList(_key) ?? [];
    return strings
        .map((s) => OutboxEntry.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> _persist(
      SharedPreferences prefs, List<OutboxEntry> entries) async {
    await prefs.setStringList(
        _key, entries.map((e) => jsonEncode(e.toJson())).toList());
  }
}
