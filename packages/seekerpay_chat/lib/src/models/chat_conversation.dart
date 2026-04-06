import 'chat_message.dart';

/// A summary of the chat between the local wallet and one peer.
///
/// Derived by [ChatService] from the local sqflite cache — not stored
/// separately. Rebuilt whenever new messages arrive or are sent.
class ChatConversation {
  /// The peer's Solana wallet address (Base58).
  final String peerAddress;

  /// The peer's resolved .skr (or .sol) domain, if known.
  /// Resolved lazily via seekerpay_domains and cached in memory.
  final String? peerDomain;

  /// The most recent message in this conversation, or null if none.
  final ChatMessage? lastMessage;

  /// Number of incoming messages that have not yet been read.
  final int unreadCount;

  const ChatConversation({
    required this.peerAddress,
    this.peerDomain,
    this.lastMessage,
    this.unreadCount = 0,
  });

  /// The display name shown in the conversations list:
  /// prefers [peerDomain] when available, otherwise truncates [peerAddress].
  String get displayName {
    if (peerDomain != null && peerDomain!.isNotEmpty) return peerDomain!;
    if (peerAddress.length > 12) {
      return '${peerAddress.substring(0, 6)}…${peerAddress.substring(peerAddress.length - 4)}';
    }
    return peerAddress;
  }

  /// UTC time of the last message, used for sorting the conversations list.
  DateTime? get lastActivity => lastMessage?.timestamp;

  ChatConversation copyWith({
    String? peerDomain,
    ChatMessage? lastMessage,
    int? unreadCount,
  }) {
    return ChatConversation(
      peerAddress: peerAddress,
      peerDomain: peerDomain ?? this.peerDomain,
      lastMessage: lastMessage ?? this.lastMessage,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}
