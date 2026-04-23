# seekerpay_core

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

The foundation of the SeekerPay SDK. Provides Solana RPC communication, SKR token payment processing via the Mobile Wallet Adapter, wallet state management, activity history parsing, token pricing, and offline payment queuing.

---

## Features

- **Solana RPC Client** — JSON-RPC calls for balances, token accounts, blockhash, transaction simulation, send, and confirmation polling. Includes Helius DAS `getAssetsByOwner` for NFT/Token-2022 queries.
- **SKR Token** — Mint address, decimals, SPL transfer instruction builder, and multi-recipient batch transfer.
- **Payment Service** — High-level API (`pay`, `payMulti`) that builds, simulates, signs via MWA, sends, and confirms transactions. Status flows: `idle → building → simulating → signing → sending → confirming → success / failed`.
- **Offline Payments** — Transactions can be pre-signed while online and queued for submission later (`offlineReady: true`). `PendingTransactionManager` persists the queue.
- **Activity Service** — Fetches the wallet's SKR transaction history from Helius (7-day rolling window) and parses send/receive records.
- **Price Service** — Real-time SOL and SKR prices via CoinGecko with local caching.
- **Recent Wallets** — Tracks the last 10 wallets paid to, with domain labels.
- **Balance Providers** — Reactive Riverpod providers for SOL and SKR balances with configurable RPC endpoint.

---

## Installation

```yaml
dependencies:
  seekerpay_core: ^1.3.0
```

---

## Setup

Wrap your app in `ProviderScope` and call `MwaClient.instance.configure()` **before** `runApp` to set the app name and domain shown to the user during wallet signing:

```dart
void main() {
  MwaClient.instance.configure(
    identityName: 'My App',                        // shown in wallet signing dialog
    identityUri: Uri.parse('https://myapp.com'),   // your app's domain
  );
  runApp(const ProviderScope(child: MyApp()));
}
```

If `configure()` is not called the defaults are `seekerpay` / `seekerpay.live`.

Optionally configure a [Helius](https://dashboard.helius.dev) API key for reliable RPC and activity history:

```dart
// Call once after app startup (e.g., in initState or a splash screen)
await ref.read(rpcUrlProvider.notifier).setHeliusKey('YOUR_HELIUS_API_KEY');
```

---

## Usage

### Connect wallet

```dart
// Watch wallet state
final wallet = ref.watch(walletStateProvider);

// Connect via Solana Mobile Wallet Adapter
await ref.read(walletStateProvider.notifier).connect();

print(wallet.address); // 'CvH5vB...'
```

### Check balances

```dart
// Reactive — rebuilds when balance changes
final skr = ref.watch(skrBalanceProvider);
final sol = ref.watch(solBalanceProvider);

skr.when(
  data: (bal) => Text('${(bal.toDouble() / 1e6).toStringAsFixed(2)} SKR'),
  loading: () => const CircularProgressIndicator(),
  error: (e, _) => Text('Error: $e'),
);
```

### Send SKR

```dart
final request = PaymentRequest(
  recipient: 'RECIPIENT_WALLET_ADDRESS',
  amount: BigInt.from(2_500_000), // 2.5 SKR
  label: 'Coffee',
);

// Watch payment state
ref.listen<PaymentState>(paymentServiceProvider, (_, state) {
  if (state.status == PaymentStatus.success) {
    print('Sent! Signature: ${state.signature}');
  }
});

await ref.read(paymentServiceProvider.notifier).pay(request);
```

### Send to multiple recipients

```dart
await ref.read(paymentServiceProvider.notifier).payMulti([
  PaymentRequest(recipient: 'ADDR_1', amount: BigInt.from(1_000_000)),
  PaymentRequest(recipient: 'ADDR_2', amount: BigInt.from(1_000_000)),
]);
```

### Offline-ready payment

```dart
// Pre-sign while online; send later even if connectivity drops
await ref.read(paymentServiceProvider.notifier).pay(request, offlineReady: true);

// When back online, flush queued transactions
await ref.read(paymentServiceProvider.notifier).submitPendingTransactions();
```

### Activity history

```dart
// Load the current wallet's SKR history
await ref.read(activityServiceProvider.notifier).load();

final activity = ref.watch(activityServiceProvider);
for (final tx in activity.transactions) {
  final skr = tx.amount.toDouble() / 1e6;
  print('${tx.type == TransactionType.send ? "Sent" : "Received"} $skr SKR — ${tx.counterparty}');
}
```

### Token price

```dart
final rpc = ref.read(rpcUrlProvider);
final prices = await PriceService().fetchPrices();
print('SKR: \$${prices.skrUsd}  SOL: \$${prices.solUsd}');
```

### Raw RPC access

```dart
final rpc = RpcClient(rpcUrl: 'https://mainnet.helius-rpc.com/?api-key=YOUR_KEY');

final balance = await rpc.getBalance('WALLET_ADDRESS');         // lamports
final blockhash = await rpc.getLatestBlockhash();
final assets = await rpc.getAssetsByOwner('WALLET_ADDRESS');    // Helius DAS
```

---

## API Reference

### `PaymentRequest`

| Field | Type | Description |
|-------|------|-------------|
| `recipient` | `String` | Base58 wallet address |
| `amount` | `BigInt` | Amount in base units (1 SKR = 1 000 000) |
| `label` | `String?` | Human-readable label (shown in wallet) |

### `PaymentStatus` enum

`idle` → `building` → `simulating` → `signing` → `sending` → `confirming` → **`success`** / **`failed`**

### `TransactionRecord`

| Field | Type | Description |
|-------|------|-------------|
| `signature` | `String` | Transaction signature |
| `timestamp` | `DateTime` | Block time |
| `amount` | `BigInt` | Token amount in base units |
| `type` | `TransactionType` | `send` / `receive` / `unknown` |
| `counterparty` | `String` | Other wallet address |
| `decimals` | `int` | Always 6 for SKR |

### `SKRToken`

```dart
SKRToken.mintAddress  // 'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3'
SKRToken.decimals     // 6
```

---

## License

MIT — see [LICENSE](../../LICENSE).
