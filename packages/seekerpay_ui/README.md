# seekerpay_ui

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

The official UI component library for the SeekerPay SDK — high-contrast dark theme, payment confirmation sheet, and NFC pulse animation.

---

## Features

- **`AppTheme.darkTheme`** — Material 3 dark theme optimised for OLED displays. Rounded corners, white-on-black palette, custom `AppBar`, `Card`, `Button`, and `TextField` styles.
- **`AppColors`** — Full colour palette including `primary`, `surface`, `background`, `textSecondary`, `textDisabled`, and vibrant icon accents (`purple`, `green`, `blue`, `orange`, `pink`).
- **`PaymentPreviewSheet`** — Bottom sheet that shows recipient, amount, offline-ready toggle, and a confirm button. Designed to be shown with `showModalBottomSheet`.
- **`NfcPulseAnimation`** — Animated concentric ring pulse for NFC scanning screens.

---

## Installation

```yaml
dependencies:
  seekerpay_ui: ^1.3.0
```

---

## Usage

### Apply the theme

```dart
import 'package:seekerpay_ui/seekerpay_ui.dart';

MaterialApp(
  theme: AppTheme.darkTheme,
  home: const MyHomePage(),
)
```

### Colours

```dart
Container(color: AppColors.surface)
Text('Label', style: TextStyle(color: AppColors.textSecondary))
Icon(Icons.send, color: AppColors.primary)
```

### Payment Preview Sheet

```dart
import 'package:seekerpay_core/seekerpay_core.dart';
import 'package:seekerpay_ui/seekerpay_ui.dart';

showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (_) => PaymentPreviewSheet(
    request: PaymentRequest(
      recipient: 'RECIPIENT_WALLET_ADDRESS',
      amount: BigInt.from(1_000_000), // 1.00 SKR
      label: 'Lunch',
    ),
    onConfirm: (bool offlineReady) {
      // offlineReady == true when user toggled offline mode
      ref.read(paymentServiceProvider.notifier).pay(request, offlineReady: offlineReady);
    },
  ),
);
```

### NFC Pulse Animation

```dart
SizedBox(
  width: 240,
  height: 240,
  child: NfcPulseAnimation(size: 240),
)
```

The animation runs automatically and loops indefinitely. It renders three concentric rings that expand outward from a central NFC icon. Stop the animation by removing the widget from the tree.

---

## `AppColors` reference

| Name | Usage |
|------|-------|
| `background` | Scaffold background |
| `surface` | Cards, bottom sheets, input fields |
| `primary` | Primary accent (white) |
| `textSecondary` | Subtitles, labels |
| `textDisabled` | Placeholder text, icons |
| `purple` / `green` / `blue` / `orange` / `pink` | Icon & avatar accents |

---

## License

MIT — see [LICENSE](../../LICENSE).
