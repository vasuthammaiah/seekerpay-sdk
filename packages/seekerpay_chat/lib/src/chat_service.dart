import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'crypto/chat_crypto.dart';
import 'models/chat_conversation.dart';
import 'models/chat_message.dart';
import 'outbox_manager.dart';
import 'storage/arweave_client.dart';
import 'storage/chat_cache.dart';
import 'storage/irys_client.dart';

class _TransientChatException implements Exception {
  final String message;
  const _TransientChatException(this.message);

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Immutable state for [ChatService].
class ChatState {
  /// All known conversations, sorted by last activity (newest first).
  final List<ChatConversation> conversations;

  /// True only during the very first cold-start cache load (< 100 ms).
  final bool isLoading;

  /// Non-null when an unrecoverable error occurred during init.
  final String? error;

  /// True once the local X25519 key is registered on Arweave (or confirmed
  /// via local cache). Always true after the first successful launch.
  final bool isKeyRegistered;

  const ChatState({
    this.conversations = const [],
    this.isLoading = false,
    this.error,
    this.isKeyRegistered = false,
  });

  ChatState copyWith({
    List<ChatConversation>? conversations,
    bool? isLoading,
    String? error,
    bool? isKeyRegistered,
  }) {
    return ChatState(
      conversations: conversations ?? this.conversations,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isKeyRegistered: isKeyRegistered ?? this.isKeyRegistered,
    );
  }
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Riverpod [StateNotifier] that orchestrates E2E encrypted chat over Arweave.
///
/// ### Performance model
/// Every user-visible action (send, receive) is **optimistic-first**:
/// - Messages are inserted into sqflite and the UI updates immediately.
/// - Network work (Irys upload, Arweave poll) runs in the background.
/// - Failed uploads go into the outbox and are retried on the next poll tick.
///
/// ### Key registration
/// The local X25519 public key is stored in sqflite on first launch so that
/// self-messaging works immediately without waiting for Arweave indexing.
/// The Arweave registration (for peers on other devices) is kicked off in
/// the background; its completion status is cached in SharedPreferences so
/// the Arweave query never runs twice.
class ChatService extends StateNotifier<ChatState> {
  final String _myAddress;
  final ChatCache _cache;
  final ChatOutboxManager _outbox;
  final ArweaveClient _arweave;

  static const _pollInterval = Duration(seconds: 3);
  static const _appName = 'SKR-Chat';
  static const _protocol = '1';
  static const _maxOutboxAttempts = 10;
  // Per-address SharedPreferences flag: set after Arweave key registration succeeds.
  static const _prefKeyRegPrefix = 'skr_chat_key_reg_';

  Timer? _pollTimer;
  bool _isPolling = false;
  int _lastSeenTimestamp = 0;

  ChatCrypto? _crypto;
  IrysClient? _irys;

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[ChatService] $message');
    }
  }

  ChatService({
    required String myAddress,
    required ChatCache cache,
    required ChatOutboxManager outbox,
    required ArweaveClient arweave,
  })  : _myAddress = myAddress,
        _cache = cache,
        _outbox = outbox,
        _arweave = arweave,
        super(const ChatState()) {
    _init();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Init — fast path, nothing blocks the UI
  // ---------------------------------------------------------------------------

  Future<void> _init() async {
    if (_myAddress.isEmpty) return;
    _log('init wallet=$_myAddress');

    // 1. Load conversations from sqflite — instant, no network.
    await _refreshConversations();

    // 2. Init crypto & Irys signing key from SharedPreferences — fast.
    try {
      _crypto = await ChatCrypto.init();
      _irys = await IrysClient.init();
      _log('crypto and irys initialized');
    } catch (e) {
      if (mounted) state = state.copyWith(error: 'Crypto init failed: $e');
      _log('crypto init failed: $e');
      return;
    }

    // 3. Save own X25519 key to sqflite immediately.
    //    This makes self-messaging and local key lookups instant — no Arweave needed.
    final myPubKey = await _crypto!.publicKeyBytes;
    final myOwnerHash = ChatCrypto.hashAddress(_myAddress);
    await _cache.saveKeyRegistration(
      ownerHash: myOwnerHash,
      x25519PublicKey: myPubKey,
      arweaveTxId: 'local',
    );

    // 4. Check SharedPreferences cache — if key was registered before, skip Arweave.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('$_prefKeyRegPrefix$_myAddress') == true) {
      if (mounted) state = state.copyWith(isKeyRegistered: true);
      _log('key registration already known');
    } else {
      // Run Arweave key registration in background — don't block the UI.
      _ensureKeyRegisteredInBackground(myPubKey, myOwnerHash, prefs);
    }

    // 5. Start polling immediately — service is ready.
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      if (mounted) _poll();
    });

    // Flush any queued messages immediately after startup instead of waiting
    // for the first poll tick.
    await _retryOutbox();
  }

  // ---------------------------------------------------------------------------
  // Key registration (background, non-blocking)
  // ---------------------------------------------------------------------------

  /// Registers the local X25519 public key on Arweave in the background.
  /// Uses a SharedPreferences flag so the Arweave query only ever runs once.
  Future<void> _ensureKeyRegisteredInBackground(
    Uint8List myPubKey,
    String ownerHash,
    SharedPreferences prefs,
  ) async {
    try {
      // Check if already registered on Arweave (only runs the very first time).
      final existing = await _arweave.queryKeyRegistration(ownerHash);
      if (existing != null) {
        await prefs.setBool('$_prefKeyRegPrefix$_myAddress', true);
        if (mounted) state = state.copyWith(isKeyRegistered: true);
        await _retryOutbox();
        return;
      }

      // Upload key registration (~200 bytes, free on Irys).
      final data = Uint8List.fromList(
        utf8.encode(jsonEncode({'x25519_pub': base64.encode(myPubKey)})),
      );
      final tags = [
        IrysTag('App-Name', _appName),
        IrysTag('Protocol', _protocol),
        IrysTag('Type', 'key_reg'),
        IrysTag('Owner-Hash', ownerHash),
      ];
      await _irys!.upload(data, tags);
      await prefs.setBool('$_prefKeyRegPrefix$_myAddress', true);
      if (mounted) state = state.copyWith(isKeyRegistered: true);
      await _retryOutbox();
    } catch (e) {
      // Non-fatal: peers can still receive messages once we retry on next launch.
      print('[ChatService] background key registration failed: $e');
      _log('background key registration failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Public send API
  // ---------------------------------------------------------------------------

  /// Sends a plain-text message to [peerAddress].
  ///
  /// The message is inserted locally immediately, then uploaded in the
  /// background. Returning a [Future] keeps the API compatible with callers
  /// that already `await` message sends.
  Future<void> sendText(String peerAddress, String text) {
    return _sendMessage(
      peerAddress: peerAddress,
      type: MessageType.text,
      text: text,
    );
  }

  /// Sends a Solana Pay URL as a payment-request QR to [peerAddress].
  ///
  /// The message is inserted locally immediately, then uploaded in the
  /// background. Returning a [Future] keeps the API compatible with callers
  /// that already `await` message sends.
  Future<void> sendPaymentRequest(
    String peerAddress,
    String solanaPayUrl, {
    String? caption,
  }) {
    return _sendMessage(
      peerAddress: peerAddress,
      type: MessageType.paymentRequest,
      solanaPayUrl: solanaPayUrl,
      caption: caption,
    );
  }

  /// Retries a previously queued or failed message.
  Future<void> retryMessage(ChatMessage message) async {
    _log('manual retry requested id=${message.id}');
    final retrying = message.copyWith(
      status: MessageStatus.sending,
      clearError: true,
    );
    await _cache.upsertMessage(retrying);
    if (mounted) {
      await _refreshConversations();
    }
    // ignore: unawaited_futures
    _uploadInBackground(retrying);
  }

  /// Deletes a local cached message and any queued retry entry for it.
  Future<void> deleteMessage(String messageId) async {
    _log('delete local message id=$messageId');
    await _outbox.remove(messageId);
    await _cache.deleteMessage(messageId);
    if (mounted) {
      await _refreshConversations();
    }
  }

  // ---------------------------------------------------------------------------
  // Internal send — optimistic insert then background upload
  // ---------------------------------------------------------------------------

  Future<void> _sendMessage({
    required String peerAddress,
    required MessageType type,
    String? text,
    String? solanaPayUrl,
    String? caption,
  }) async {
    final id = const Uuid().v4();
    _log('queue local message id=$id to=$peerAddress type=${type.name}');
    final now = DateTime.now().toUtc();

    final optimistic = ChatMessage(
      id: id,
      from: _myAddress,
      to: peerAddress,
      type: type,
      text: text,
      solanaPayUrl: solanaPayUrl,
      caption: caption,
      timestamp: now,
      status: MessageStatus.sending,
      isFromMe: true,
    );

    // Insert immediately → UI shows the bubble right away.
    await _cache.upsertMessage(optimistic);
    if (mounted) await _refreshConversations();

    // Network work runs detached — caller is not blocked.
    // ignore: unawaited_futures
    _uploadInBackground(optimistic);
  }

  Future<void> _uploadInBackground(ChatMessage optimistic) async {
    if (_crypto == null || _irys == null) {
      _log('transport not ready for id=${optimistic.id}, queueing');
      await _queueForRetry(
        optimistic,
        error: 'Chat transport is still initializing',
        incrementAttempt: false,
      );
      return;
    }

    Uint8List? recipientPubKey;
    try {
      recipientPubKey = await _resolveRecipientKey(optimistic.to);
    } on _TransientChatException catch (e) {
      _log('recipient key lookup transient failure for id=${optimistic.id}: ${e.message}; falling back to public upload');
      await _uploadMessage(optimistic, null);
      return;
    }
    if (recipientPubKey == null) {
      _log('recipient key missing for to=${optimistic.to}, id=${optimistic.id}; using public upload fallback');
      await _uploadMessage(optimistic, null);
      return;
    }

    await _uploadMessage(optimistic, recipientPubKey);
  }

  /// Resolves the peer's X25519 public key.
  /// Order: sqflite cache → Arweave query.
  /// Own key is always in sqflite (saved during init) so self-messaging is instant.
  Future<Uint8List?> _resolveRecipientKey(String peerAddress) async {
    final ownerHash = ChatCrypto.hashAddress(peerAddress);

    // sqflite cache hit — covers own address and previously-seen peers.
    final cached = await _cache.getX25519PublicKey(ownerHash);
    if (cached != null) {
      _log('recipient key cache hit for $peerAddress');
      return cached;
    }

    // Arweave fallback for first contact with a new peer.
    try {
      _log('querying key registration for $peerAddress');
      final reg = await _arweave.queryKeyRegistration(ownerHash);
      if (reg == null) {
        _log('no key registration found for $peerAddress');
        return null;
      }

      final content = await _arweave.fetchContent(reg.txId);
      final json = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
      final pubKeyB64 = json['x25519_pub'] as String?;
      if (pubKeyB64 == null) return null;

      final pubKeyBytes = base64.decode(pubKeyB64);
      await _cache.saveKeyRegistration(
        ownerHash: ownerHash,
        x25519PublicKey: pubKeyBytes,
        arweaveTxId: reg.txId,
      );
      _log('recipient key resolved from arweave for $peerAddress tx=${reg.txId}');
      return pubKeyBytes;
    } catch (e) {
      final message = _describeLookupError(e);
      _log('recipient key lookup failed for $peerAddress: $e');
      throw _TransientChatException(message);
    }
  }

  String _describeLookupError(Object error) {
    if (error is TimeoutException) {
      return 'Arweave lookup timed out';
    }
    if (error is SocketException) {
      return 'Network error reaching Arweave';
    }
    if (error is http.ClientException) {
      return 'Network error reaching Arweave';
    }
    if (error is ArweaveQueryException) {
      return 'Arweave lookup failed';
    }
    final text = error.toString();
    if (text.contains('Failed host lookup')) {
      return 'Network error reaching Arweave';
    }
    return 'Arweave lookup failed';
  }

  Future<void> _uploadMessage(ChatMessage message, Uint8List? recipientPubKey) async {
    try {
      final payload = <String, dynamic>{
        'id': message.id,
        'from': message.from,
        'to': message.to,
        'type': message.type.name,
        if (message.text != null) 'text': message.text,
        if (message.solanaPayUrl != null) 'url': message.solanaPayUrl,
        if (message.caption != null) 'cap': message.caption,
        'ts': message.timestamp.toIso8601String(),
      };

      final bool isEncrypted = recipientPubKey != null;
      payload['enc'] = isEncrypted ? 'x25519' : 'none';

      _log('uploading message id=${message.id} to=${message.to} mode=${isEncrypted ? 'encrypted' : 'public'}');

      final Uint8List data;
      if (isEncrypted) {
        final plaintext = jsonEncode(payload);
        final encrypted = await _crypto!.encrypt(plaintext, recipientPubKey);
        data = encrypted.toBytes();
      } else {
        data = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      }


      final tags = [
        IrysTag('App-Name', _appName),
        IrysTag('Protocol', _protocol),
        IrysTag('Type', 'dm'),
        IrysTag('To-Hash', ChatCrypto.hashAddress(message.to)),
        IrysTag('Encryption', isEncrypted ? 'x25519' : 'none'),
      ];

      final txId = await _irys!.upload(data, tags);
      _log('upload success id=${message.id} tx=$txId');
      await _cache.upsertMessage(
          message.copyWith(txId: txId, status: MessageStatus.sent));
      await _outbox.remove(message.id);
      if (mounted) await _refreshConversations();
    } catch (e) {
      // Always print the raw Irys response so it's visible in both debug and
      // release logs — helps diagnose node/endpoint issues quickly.
      debugPrint('[ChatService] upload failed id=${message.id}: $e');
      final errorMessage = _describeUploadError(e);
      await _queueForRetry(
        message,
        error: errorMessage,
        incrementAttempt: false,
        lastError: errorMessage,
      );
    }
  }

  String _describeUploadError(Object error) {
    if (error is TimeoutException) {
      return 'Irys upload timed out';
    }
    if (error is IrysUploadException) {
      if (error.statusCode >= 500) {
        return 'Irys server error (${error.statusCode})';
      }
      if (error.statusCode == 429) {
        return 'Irys rate limit reached';
      }
      if (error.statusCode >= 400) {
        return 'Irys rejected upload (${error.statusCode})';
      }
      return 'Irys upload failed (${error.statusCode})';
    }
    return 'Upload failed: ${error.runtimeType}';
  }

  Future<void> _queueForRetry(
    ChatMessage message, {
    required String error,
    required bool incrementAttempt,
    bool canFailPermanently = true,
    String? lastError,
  }) async {
    final queued = message.copyWith(
      status: MessageStatus.queued,
      error: lastError ?? error,
    );

    final attempts = await _outbox.store(
      OutboxEntry(message: queued),
      incrementAttempts: incrementAttempt,
    );
    _log('queued id=${message.id} status=${queued.status.name} attempts=$attempts reason="${lastError ?? error}"');

    if (canFailPermanently && attempts >= _maxOutboxAttempts) {
      _log('marking message failed after max retries id=${message.id}');
      await _cache.upsertMessage(
        message.copyWith(
          status: MessageStatus.failed,
          error: lastError ?? 'Delivery failed after repeated retries',
        ),
      );
      await _outbox.remove(message.id);
    } else {
      await _cache.upsertMessage(queued);
    }

    if (mounted) {
      await _refreshConversations();
    }
  }

  // ---------------------------------------------------------------------------
  // Polling
  // ---------------------------------------------------------------------------

  Future<void> _poll() async {
    if (_isPolling || _myAddress.isEmpty || _crypto == null) return;
    _isPolling = true;
    try {
      await _fetchNewMessages();
      await _retryOutbox();
    } finally {
      _isPolling = false;
    }
  }

  Future<void> _fetchNewMessages() async {
    final toHash = ChatCrypto.hashAddress(_myAddress);
    final List<ArweaveMessage> arweaveMessages;
    try {
      _log('poll inbox after=$_lastSeenTimestamp');
      arweaveMessages = await _arweave.queryInbox(
        toHash: toHash,
        afterTimestamp: _lastSeenTimestamp,
      );
    } catch (_) {
      // Network unavailable — poll will retry on next tick.
      _log('poll inbox failed');
      return;
    }
    if (arweaveMessages.isEmpty) {
      _log('poll inbox no messages');
      return;
    }
    _log('poll inbox received count=${arweaveMessages.length}');

    bool didUpdate = false;
    for (final am in arweaveMessages) {
      try {
        final rawBytes = await _arweave.fetchContent(am.txId);
        final json = await _decodeIncomingMessage(rawBytes);

        final msg = ChatMessage(
          id: json['id'] as String? ?? am.txId,
          txId: am.txId,
          from: json['from'] as String? ?? am.tags['From-Hash'] ?? '',
          to: _myAddress,
          type: MessageType.values.byName(
              (json['type'] as String?) ?? MessageType.text.name),
          text: json['text'] as String?,
          solanaPayUrl: json['url'] as String?,
          caption: json['cap'] as String?,
          timestamp: json['ts'] != null
              ? DateTime.parse(json['ts'] as String)
              : (am.blockTimestamp != null
                  ? DateTime.fromMillisecondsSinceEpoch(am.blockTimestamp! * 1000)
                  : DateTime.now().toUtc()),
          status: MessageStatus.sent,
          isFromMe: false,
        );

        await _cache.upsertMessage(msg);
        if (am.blockTimestamp != null && am.blockTimestamp! > _lastSeenTimestamp) {
          _lastSeenTimestamp = am.blockTimestamp!;
        }
        didUpdate = true;
      } catch (e) {
        _log('skipping undecryptable message ${am.txId}: $e');
      }
    }
    if (didUpdate && mounted) await _refreshConversations();
  }

  Future<Map<String, dynamic>> _decodeIncomingMessage(Uint8List rawBytes) async {
    final decoded = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
    final encryption = decoded['enc'] as String?;

    if (encryption == 'none' || decoded.containsKey('type')) {
      return decoded;
    }

    final payload = EncryptedChatPayload.fromJson(decoded);
    final plaintext = await _crypto!.decrypt(payload);
    return jsonDecode(plaintext) as Map<String, dynamic>;
  }

  Future<void> _retryOutbox() async {
    if (_crypto == null || _irys == null) return;
    final pending = await _outbox.getAll();
    if (pending.isNotEmpty) {
      _log('retry outbox count=${pending.length}');
    }
    for (final entry in pending) {
      Uint8List? recipientPubKey;
      try {
        recipientPubKey = await _resolveRecipientKey(entry.message.to);
      } on _TransientChatException catch (e) {
        _log('retry key lookup transient failure for id=${entry.message.id}: ${e.message}; trying public upload');
      }
      await _outbox.store(
        OutboxEntry(
          message: entry.message.copyWith(
            status: MessageStatus.sending,
            clearError: true,
          ),
        ),
        incrementAttempts: true,
      );
      await _cache.upsertMessage(
        entry.message.copyWith(
          status: MessageStatus.sending,
          clearError: true,
        ),
      );
      if (mounted) {
        await _refreshConversations();
      }
      await _uploadMessage(entry.message, recipientPubKey);
    }
  }

  // ---------------------------------------------------------------------------
  // Conversations list
  // ---------------------------------------------------------------------------

  Future<void> _refreshConversations() async {
    if (!mounted) return;
    final latest = await _cache.getLatestPerConversation(_myAddress);
    final conversations = latest.map((msg) {
      final peer = msg.isFromMe ? msg.to : msg.from;
      return ChatConversation(peerAddress: peer, lastMessage: msg);
    }).toList()
      ..sort((a, b) => (b.lastActivity ?? DateTime(0))
          .compareTo(a.lastActivity ?? DateTime(0)));
    if (mounted) state = state.copyWith(conversations: conversations);
  }

  // ---------------------------------------------------------------------------
  // Public data access
  // ---------------------------------------------------------------------------

  /// Returns all cached messages for the conversation with [peerAddress].
  Future<List<ChatMessage>> getMessages(String peerAddress) =>
      _cache.getConversation(myAddress: _myAddress, peerAddress: peerAddress);
}
