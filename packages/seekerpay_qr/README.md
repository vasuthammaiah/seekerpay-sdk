# seekerpay_qr

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

Solana Pay-compatible QR code generation and URL decoding for the SeekerPay SDK.

---

## Features

- **`SolanaPayUrl`** — Encode and decode `solana:` payment URLs per the [Solana Pay spec](https://docs.solanapay.com).
- Supports `recipient`, `amount` (auto-converted between display and base units), `spl-token`, `label`, and `message` fields.
- Handles Base58 case-sensitivity in URL decoding.
- Pairs with [`qr_flutter`](https://pub.dev/packages/qr_flutter) for on-screen QR rendering.

---

## Installation

```yaml
dependencies:
  seekerpay_qr: ^1.3.0
  qr_flutter: ^4.1.0   # for QrImageView rendering
```

---

## Usage

### Generate a payment QR

```dart
import 'package:seekerpay_qr/seekerpay_qr.dart';
import 'package:seekerpay_core/seekerpay_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

final url = SolanaPayUrl(
  recipient: 'RECIPIENT_WALLET_ADDRESS',
  amount: BigInt.from(5_000_000),   // 5.000000 SKR
  splToken: SKRToken.mintAddress,
  label: 'Coffee',
).encode();
// 'solana:RECIPIENT_WALLET_ADDRESS?amount=5.0&spl-token=SKR...&label=Coffee'

QrImageView(
  data: url,
  version: QrVersions.auto,
  size: 200,
  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
)
```

### Decode a Solana Pay URL (e.g. scanned from another wallet)

```dart
final parsed = SolanaPayUrl.decode('solana:ADDR?amount=2.5&spl-token=SKR...&label=Lunch');

print(parsed.recipient);             // 'ADDR'
print(parsed.amount);                // BigInt.from(2_500_000)
print(parsed.label);                 // 'Lunch'
```

### Amount conversion

All `amount` values in the SDK use **base units** (6 decimals for SKR):

```dart
// Display → base units
final base = BigInt.from((displayAmount * 1_000_000).toInt());

// Base units → display
final display = amount.toDouble() / 1_000_000;
```

---

## `SolanaPayUrl` API

| Parameter | Type | Description |
|-----------|------|-------------|
| `recipient` | `String` | **Required.** Base58 destination wallet address |
| `amount` | `BigInt?` | Amount in base units (6 decimals). `null` = open amount |
| `splToken` | `String?` | SPL token mint. Use `SKRToken.mintAddress` for SKR payments |
| `label` | `String?` | Short description shown in the wallet |
| `message` | `String?` | Optional longer description |

**`encode()`** — Returns a `solana:` URL string.  
**`SolanaPayUrl.decode(url)`** — Parses a `solana:` URL string. Throws `FormatException` if not a valid Solana Pay URL.

---

## License

MIT — see [LICENSE](../../LICENSE).
