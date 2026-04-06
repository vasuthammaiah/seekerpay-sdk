import 'dart:convert';
import 'dart:typed_data';

/// The type of content carried by a [ChatMessage].
enum MessageType {
  /// Plain UTF-8 text.
  text,

  /// A Solana Pay URL rendered as a scannable QR code with a Pay button.
  /// The receiver uses seekerpay_qr's QrImageView(data: solanaPayUrl) locally —
  /// no image bytes are transmitted; only the URL string is stored on-chain.
  paymentRequest,
}

/// Lifecycle / delivery status of a [ChatMessage].
enum MessageStatus {
  /// Actively being processed for delivery right now.
  sending,

  /// Waiting in the local outbox for retry or for the peer chat key.
  queued,

  /// Uploaded to Irys; will appear on Arweave after bundling (~2 min).
  sent,

  /// Delivery failed permanently and is no longer being retried.
  failed,
}

/// An immutable, decrypted chat message as held in local state and sqflite cache.
class ChatMessage {
  /// Locally-generated UUID — primary key before [txId] is known.
  final String id;

  /// Arweave transaction ID assigned by Irys after a successful upload.
  /// Null while [status] is [MessageStatus.sending] or [MessageStatus.failed].
  final String? txId;

  /// Sender's Solana wallet address (Base58).
  final String from;

  /// Recipient's Solana wallet address (Base58).
  final String to;

  /// Content type.
  final MessageType type;

  /// Decrypted plain-text content — populated only when [type] is [MessageType.text].
  final String? text;

  /// Solana Pay URL (e.g. `solana:ADDRESS?amount=5&spl-token=...`) —
  /// populated only when [type] is [MessageType.paymentRequest].
  final String? solanaPayUrl;

  /// Optional human-readable caption shown below the QR code.
  final String? caption;

  /// UTC creation time (set locally; used for display ordering).
  final DateTime timestamp;

  /// Current delivery status.
  final MessageStatus status;

  /// True when this message was sent by the local wallet (used for bubble alignment).
  final bool isFromMe;

  /// Last error detail when [status] is [MessageStatus.failed].
  final String? error;

  const ChatMessage({
    required this.id,
    this.txId,
    required this.from,
    required this.to,
    required this.type,
    this.text,
    this.solanaPayUrl,
    this.caption,
    required this.timestamp,
    required this.status,
    required this.isFromMe,
    this.error,
  });

  /// Returns a copy with selected fields replaced.
  ChatMessage copyWith({
    String? txId,
    MessageStatus? status,
    String? error,
    bool clearError = false,
  }) {
    return ChatMessage(
      id: id,
      txId: txId ?? this.txId,
      from: from,
      to: to,
      type: type,
      text: text,
      solanaPayUrl: solanaPayUrl,
      caption: caption,
      timestamp: timestamp,
      status: status ?? this.status,
      isFromMe: isFromMe,
      error: clearError ? null : (error ?? this.error),
    );
  }

  /// Human-readable delivery label for UI rendering.
  ///
  /// Use this to show the three delivery states directly in the chat screen.
  String get deliveryLabel => switch (status) {
        MessageStatus.sending => 'Sending',
        MessageStatus.queued => 'Queued',
        MessageStatus.sent => 'Sent',
        MessageStatus.failed => 'Failed',
      };

  /// Returns `true` when this message has been uploaded and can be inspected
  /// on an Arweave gateway.
  bool get hasExplorerUrl => txId != null && txId!.isNotEmpty;

  /// Public Arweave gateway URL for this message upload, or `null` when the
  /// message has not been uploaded successfully yet.
  String? get explorerUrl =>
      hasExplorerUrl ? 'https://arweave.net/$txId' : null;

  /// Serialises to a JSON-compatible map (for sqflite and SharedPreferences).
  Map<String, dynamic> toJson() => {
    'id': id,
    'txId': txId,
    'from': from,
    'to': to,
    'type': type.name,
    'text': text,
    'solanaPayUrl': solanaPayUrl,
    'caption': caption,
    'timestamp': timestamp.toIso8601String(),
    'status': status.name,
    'isFromMe': isFromMe ? 1 : 0,
    'error': error,
  };

  /// Deserialises from a map produced by [toJson].
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    txId: json['txId'] as String?,
    from: json['from'] as String,
    to: json['to'] as String,
    type: MessageType.values.byName(json['type'] as String),
    text: json['text'] as String?,
    solanaPayUrl: json['solanaPayUrl'] as String?,
    caption: json['caption'] as String?,
    timestamp: DateTime.parse(json['timestamp'] as String),
    status: MessageStatus.values.byName(json['status'] as String),
    isFromMe: (json['isFromMe'] == 1 || json['isFromMe'] == true),
    error: json['error'] as String?,
  );
}

/// Wire format stored as Arweave data — the sender encrypts the inner
/// [ChatMessage] fields using ECIES (X25519 + AES-256-GCM) so that
/// only the recipient can read the content.
///
/// Layout on Arweave (JSON bytes):
/// ```json
/// { "eph": "<base64 32-byte ephemeral X25519 pubkey>",
///   "n":   "<base64 12-byte AES-GCM nonce>",
///   "c":   "<base64 ciphertext + 16-byte GCM tag>" }
/// ```
/// The plaintext encrypted inside is the JSON of a minimal message object:
/// ```json
/// { "id":"...", "type":"text"|"paymentRequest",
///   "text":"...", "solanaPayUrl":"...", "caption":"...", "ts":"<iso8601>" }
/// ```
class EncryptedChatPayload {
  /// 32-byte ephemeral X25519 public key (base64url).
  final String ephemeralPublicKeyBase64;

  /// 12-byte AES-GCM nonce (base64url).
  final String nonceBase64;

  /// AES-256-GCM ciphertext + 16-byte authentication tag (base64url).
  final String ciphertextBase64;

  const EncryptedChatPayload({
    required this.ephemeralPublicKeyBase64,
    required this.nonceBase64,
    required this.ciphertextBase64,
  });

  Map<String, dynamic> toJson() => {
    'eph': ephemeralPublicKeyBase64,
    'n': nonceBase64,
    'c': ciphertextBase64,
  };

  factory EncryptedChatPayload.fromJson(Map<String, dynamic> json) =>
      EncryptedChatPayload(
        ephemeralPublicKeyBase64: json['eph'] as String,
        nonceBase64: json['n'] as String,
        ciphertextBase64: json['c'] as String,
      );

  /// Serialises to UTF-8 JSON bytes for Irys upload.
  Uint8List toBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Deserialises from bytes fetched from Arweave.
  static EncryptedChatPayload fromBytes(Uint8List bytes) =>
      EncryptedChatPayload.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
}
