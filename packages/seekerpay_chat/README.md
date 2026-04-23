# seekerpay_chat

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

End-to-end encrypted, on-chain (Arweave/Irys) chat for SeekerPay .skr identities.

---

## Features

- **End-to-End Encryption** — Uses `cryptography` for secure message encryption/decryption using Ed25519 keys derived from the user's Solana wallet.
- **On-Chain Storage** — Messages are stored on Arweave via the Irys Network, ensuring data permanence and censorship resistance.
- **Identity-Based** — Chat with any .skr domain or Solana address.
- **Offline Outbox** — Messages are queued locally and synchronized with Arweave when online.
- **Local Cache** — SQLite-based local storage for fast message retrieval and conversation history.

---

## Installation

```yaml
dependencies:
  seekerpay_chat: ^1.1.0
```

---

## Usage

### Initialize Chat Service

```dart
final chatService = ref.watch(chatServiceProvider);

// Load conversations
final conversations = ref.watch(conversationsProvider);
```

### Send a Message

```dart
await ref.read(chatServiceProvider).sendMessage(
  recipientAddress: 'CvH5vB...',
  text: 'Hello, Seeker!',
);
```

### Listen for Messages

```dart
final messages = ref.watch(messagesProvider('CvH5vB...'));

messages.when(
  data: (list) => ListView.builder(
    itemCount: list.length,
    itemBuilder: (context, i) => Text(list[i].text),
  ),
  loading: () => const CircularProgressIndicator(),
  error: (e, _) => Text('Error: $e'),
);
```

---

## License

MIT — see [LICENSE](../../LICENSE).
