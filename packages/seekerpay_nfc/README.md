# seekerpay_nfc

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

NFC tap-to-pay for the SeekerPay SDK. Writes Solana Pay URLs to NFC tags and reads them from tags or other devices using NDEF records via a native Android/iOS platform channel.

---

## Features

- **Write payment tags** — Write a `solana:` Solana Pay URL to any writable NFC tag.
- **Read payment requests** — Start a continuous NFC session and receive Solana Pay URLs as they are scanned.
- **Availability check** — Detect whether the device supports NFC before prompting the user.
- **Settings deep-link** — Open the device NFC settings screen directly.

---

## Installation

```yaml
dependencies:
  seekerpay_nfc: ^1.3.0
```

### Android setup

Ensure the following permission is in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.NFC" />
<uses-feature android:name="android.hardware.nfc" android:required="false" />
```

---

## Usage

### Check availability

```dart
import 'package:seekerpay_nfc/seekerpay_nfc.dart';

final nfc = NfcHandler();
final available = await nfc.isAvailable();
if (!available) {
  // Show a "NFC not supported" message or open settings
  await nfc.openSettings();
}
```

### Read NFC tags (continuous)

```dart
await nfc.startReading(
  onTagRead: (String solanaPayUrl) {
    print('Received: $solanaPayUrl');
    // Parse it with SolanaPayUrl.decode(solanaPayUrl)
    nfc.stopReading(); // stop after first tag if desired
  },
);
```

### Read a single tag (helper)

```dart
// Waits for a single tag to be read, then stops scanning automatically
final url = await nfc.readTag();
print('Received: $url');
```

### Write a payment tag

```dart
import 'package:seekerpay_qr/seekerpay_qr.dart';
import 'package:seekerpay_core/seekerpay_core.dart';

final url = SolanaPayUrl(
  recipient: myWalletAddress,
  amount: BigInt.from(1_000_000), // 1.00 SKR
  splToken: SKRToken.mintAddress,
  label: 'Pay me 1 SKR',
).encode();

// Helper for single tag write
await nfc.writeTagOnce(url);

// Or with more control:
await nfc.writeNdefTag(
  solanaPayUrl: url,
  onTagWritten: () => print('Tag written successfully'),
  onTagWriteError: (e) => print('Write failed: $e'),
);
```

### Riverpod provider

```dart
// Access the singleton NfcHandler
final nfc = ref.read(nfcHandlerProvider);
```

---

## `NfcHandler` API

| Method | Description |
|--------|-------------|
| `isAvailable()` | Returns `true` if the device has NFC hardware |
| `startReading({onTagRead})` | Begin scanning; callback fires for each scanned tag |
| `readTag()` | Wait for a single tag to be read and return its URL |
| `stopReading()` | Stop the active NFC scan session |
| `writePaymentTag(url)` | Write a Solana Pay URL to a tag (fire-and-forget) |
| `writeNdefTag({url, onTagWritten, onTagWriteError})` | Write with completion/error callbacks |
| `writeTagOnce(url)` | Wait for a single tag and write to it |
| `openSettings()` | Open device NFC settings |

---

## License

MIT — see [LICENSE](../../LICENSE).
