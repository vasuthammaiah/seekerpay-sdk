# SeekerPay SDK

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS-blue)](https://flutter.dev)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Solana](https://img.shields.io/badge/Solana-Mainnet-9945FF?logo=solana)](https://solana.com)

The official open-source Flutter SDK for building Solana payment experiences on the **Seeker mobile platform** — supporting SKR token transfers, `.skr` / `.sol` domain resolution, Seeker Genesis Token verification, NFC tap-to-pay, Bluetooth P2P handoff, QR payments, group bill splitting, and on-chain encrypted chat.

---

## Packages

| Package | Version | Description |
|---------|---------|-------------|
| [`seekerpay_core`](./packages/seekerpay_core) | 1.3.0 | Solana RPC, wallet adapter, SKR/SOL payments, activity history |
| [`seekerpay_domains`](./packages/seekerpay_domains) | 1.3.0 | `.skr` and `.sol` domain resolution, Seeker Genesis verification |
| [`seekerpay_qr`](./packages/seekerpay_qr) | 1.3.0 | Solana Pay-compatible QR code generation and decoding |
| [`seekerpay_ui`](./packages/seekerpay_ui) | 1.3.0 | Dark theme, `PaymentPreviewSheet`, NFC pulse animation |
| [`seekerpay_nfc`](./packages/seekerpay_nfc) | 1.4.0 | NFC tap-to-pay via NDEF payloads |
| [`seekerpay_bluetooth`](./packages/seekerpay_bluetooth) | 1.4.0 | P2P payment handoff via Google Nearby Connections |
| [`seekerpay_split`](./packages/seekerpay_split) | 1.3.0 | Group bill splitting with on-chain payment verification |
| [`seekerpay_chat`](./packages/seekerpay_chat) | 1.1.0 | End-to-end encrypted, on-chain (Arweave/Irys) chat |
| [`seekerpay_shop`](./packages/seekerpay_shop) | 1.1.0 | Product catalog, AI-powered MRP scanning, and shop utilities |

---

## Quick Start

### 1. Add dependencies

Add the SeekerPay packages you need to your `pubspec.yaml`:

```yaml
dependencies:
  seekerpay_core: ^1.3.0
  seekerpay_ui: ^1.3.0
  # Add other packages as needed
```

### 2. Configure the wallet identity

Call `MwaClient.instance.configure()` **before** `runApp` so the user sees your app name and domain in the wallet signing dialog:

```dart
import 'package:seekerpay_core/seekerpay_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  MwaClient.instance.configure(
    identityName: 'My App',                        // shown in wallet signing dialog
    identityUri: Uri.parse('https://myapp.com'),   // your app's domain
  );
  runApp(const ProviderScope(child: MyApp()));
}
```

If `configure()` is not called the defaults are `seekerpay` / `seekerpay.live`.

### 3. Bootstrap Riverpod

All stateful services use [Riverpod](https://riverpod.dev). Wrap your app in `ProviderScope` (shown above).

### 4. Send your first SKR payment

```dart
import 'package:seekerpay_core/seekerpay_core.dart';
import 'package:seekerpay_ui/seekerpay_ui.dart';

// Inside a ConsumerWidget
final notifier = ref.read(paymentServiceProvider.notifier);

showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  builder: (_) => PaymentPreviewSheet(
    request: PaymentRequest(
      recipient: 'RECIPIENT_WALLET_ADDRESS',
      amount: BigInt.from(1_000_000), // 1.000000 SKR (6 decimals)
    ),
    onConfirm: (offlineReady) {
      notifier.pay(
        PaymentRequest(recipient: 'RECIPIENT_WALLET_ADDRESS', amount: BigInt.from(1_000_000)),
        offlineReady: offlineReady,
      );
    },
  ),
);
```

### 5. Resolve a .skr domain

```dart
import 'package:seekerpay_domains/seekerpay_domains.dart';

final resolver = ref.read(snsResolverProvider);
final address = await resolver.resolve('alice.skr');
// address == 'CvH5vB...' (mainnet wallet)
```

---

## Architecture

```
seekerpay_core          ← foundation (RPC, wallet, payments, activity)
    ↑
seekerpay_domains       ← domain resolution + genesis verification (uses core)
seekerpay_qr            ← QR generation + Solana Pay URL codec (uses core)
seekerpay_split         ← group splits + on-chain verification (uses core)
seekerpay_ui            ← UI components + theme (uses core)
seekerpay_nfc           ← NFC tap-to-pay (uses core)
seekerpay_bluetooth     ← Nearby P2P (uses core)
```

All packages depend on `seekerpay_core`. Packages do **not** depend on each other (except `seekerpay_domains` and `seekerpay_ui` which import `seekerpay_core`).

---

## Key Concepts

### SKR Token

The native token of the Seeker ecosystem. Defined in `seekerpay_core`:

```dart
SKRToken.mintAddress  // 'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3'
SKRToken.decimals     // 6
```

All `amount` fields across the SDK are in **base units** (i.e. lamport-equivalent: `1 SKR = 1_000_000`).

### Solana Mobile Wallet Adapter (MWA)

Payments are signed by the user's on-device wallet via the [Solana Mobile Wallet Adapter protocol](https://docs.solanamobile.com/getting-started/overview). No private keys are ever handled by this SDK.

### Seeker Genesis Token

The Seeker Genesis Token (SGT) identifies genuine Seeker device owners. It is a **Token-2022 group NFT** with group mint `GT22s89nU4iWFkNXj1Bw6uYhJJWDRPpShHt4Bk8f99Te`. Verification is done via the Helius DAS API:

```dart
final isVerified = await ref.read(isSeekerVerifiedProvider.future);
```

### Helius API Key

Several features (activity history, genesis verification) use the [Helius](https://helius.dev) enhanced Solana RPC. Configure it via:

```dart
await ref.read(rpcUrlProvider.notifier).setHeliusKey('YOUR_HELIUS_API_KEY');
```

---

## Requirements

- Flutter **3.x** or later
- Dart **3.x** or later
- Android **8.0+** (API 26) — for Solana Mobile Wallet Adapter
- A [Helius API key](https://dashboard.helius.dev) (free tier available) for full activity history

---

## Contributing

Contributions are welcome! Please open an issue or pull request.

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Commit your changes with a clear message
4. Open a pull request against `main`

Please ensure all public APIs are documented with dartdoc comments.

---

## Author

**Vasu Thammaiah** — [@vasuthammaiah](https://github.com/vasuthammaiah)

---

## License

SeekerPay SDK is released under the [MIT License](./LICENSE).
ammaiah)

---

## License

SeekerPay SDK is released under the [MIT License](./LICENSE).
