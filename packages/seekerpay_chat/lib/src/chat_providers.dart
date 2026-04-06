import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:seekerpay_core/seekerpay_core.dart';

import 'chat_service.dart';
import 'models/chat_message.dart';
import 'outbox_manager.dart';
import 'storage/arweave_client.dart';
import 'storage/chat_cache.dart';

// ---------------------------------------------------------------------------
// Infrastructure singletons
// ---------------------------------------------------------------------------

/// Shared [ArweaveClient] — stateless, safe to reuse across providers.
final arweaveClientProvider = Provider<ArweaveClient>((ref) {
  return ArweaveClient();
});

/// Shared [ChatCache] — wraps the SQLite database.
final chatCacheProvider = Provider<ChatCache>((ref) {
  return ChatCache();
});

/// Shared [ChatOutboxManager] — SharedPreferences-backed retry queue.
final chatOutboxProvider = Provider<ChatOutboxManager>((ref) {
  return ChatOutboxManager();
});

// ---------------------------------------------------------------------------
// Main chat service
// ---------------------------------------------------------------------------

/// Auto-disposing [ChatService] scoped to the currently connected wallet.
///
/// Rebuilds automatically when the wallet address changes (e.g. on
/// disconnect/reconnect). [ChatService] initialises [ChatCrypto] and
/// [IrysClient] internally on first use — no external async setup needed.
///
/// **Read state (conversations list):**
/// ```dart
/// final chatState = ref.watch(chatServiceProvider);
/// final conversations = chatState.conversations;
/// ```
///
/// **Send a message:**
/// ```dart
/// final service = ref.read(chatServiceProvider.notifier);
/// await service.sendText(peerAddress, 'Hello!');
/// await service.sendPaymentRequest(peerAddress, url, caption: 'Pay me');
/// ```
final chatServiceProvider =
    StateNotifierProvider.autoDispose<ChatService, ChatState>((ref) {
  final wallet = ref.watch(walletStateProvider);
  return ChatService(
    myAddress: wallet.address ?? '',
    cache: ref.watch(chatCacheProvider),
    outbox: ref.watch(chatOutboxProvider),
    arweave: ref.watch(arweaveClientProvider),
  );
});

// ---------------------------------------------------------------------------
// Per-conversation messages
// ---------------------------------------------------------------------------

/// Returns the full message list for the conversation with [peerAddress].
///
/// Re-evaluates on every poll tick that delivers new messages, keeping the
/// chat screen in sync without manual refreshes.
///
/// ```dart
/// final messagesAsync = ref.watch(conversationMessagesProvider('7xKX…abc'));
/// messagesAsync.when(
///   data: (msgs) => ListView(...),
///   loading: () => CircularProgressIndicator(),
///   error: (e, _) => Text('$e'),
/// );
/// ```
final conversationMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, peerAddress) async {
  // Watching chatServiceProvider ensures this re-runs on every state update.
  ref.watch(chatServiceProvider);
  return ref.read(chatServiceProvider.notifier).getMessages(peerAddress);
});
