# seekerpay_bluetooth

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

P2P payment handoff for the SeekerPay SDK using Google Nearby Connections. Enables two Seeker devices to exchange Solana Pay URLs over Bluetooth / Wi-Fi without internet connectivity.

---

## Features

- **Advertise** — Broadcast a Solana Pay payment URL to nearby devices.
- **Discover** — Scan for nearby SeekerPay advertisers and list them in real time.
- **Connect & receive** — Connect to a discovered device and automatically receive its Solana Pay URL.
- **Auto-stop** — The session stops itself as soon as a valid `solana:` URL is received.
- **Permission handling** — Built-in `checkPermissions()` and `askPermissions()` helpers for Bluetooth and location grants.
- **Riverpod state** — Full reactive `NearbyState` with status, device list, errors, and received URL.

---

## Installation

```yaml
dependencies:
  seekerpay_bluetooth: ^1.3.0
```

### Android setup

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
```

---

## Usage

### Advertise a payment request (sender side)

```dart
import 'package:seekerpay_bluetooth/seekerpay_bluetooth.dart';
import 'package:seekerpay_qr/seekerpay_qr.dart';
import 'package:seekerpay_core/seekerpay_core.dart';

final nearby = ref.read(nearbyServiceProvider.notifier);

// 1. Build the Solana Pay URL
final url = SolanaPayUrl(
  recipient: myWalletAddress,
  amount: BigInt.from(2_000_000), // 2.00 SKR
  splToken: SKRToken.mintAddress,
).encode();

// 2. Start advertising — permissions are checked automatically
// other devices will discover this device
await nearby.startAdvertising('Alice', url);
```

### Discover and connect (recipient side)

```dart
final nearby = ref.read(nearbyServiceProvider.notifier);

// Start discovery — permissions are checked automatically
// NearbyState.discoveredDevices updates reactively
await nearby.startDiscovery('Bob');

// Watch discovered devices
final state = ref.watch(nearbyServiceProvider);
for (final device in state.discoveredDevices) {
  print('Found: ${device.name} (${device.id})');
}

// Connect to a specific device
await nearby.connectToDevice(device.id, 'Bob');

// The received Solana Pay URL appears in state.receivedUrl
ref.listen<NearbyState>(nearbyServiceProvider, (_, state) {
  if (state.receivedUrl != null) {
    final payRequest = SolanaPayUrl.decode(state.receivedUrl!);
    // Proceed with payment...
  }
});
```

### Stop all sessions

```dart
nearby.stopAll();
```

---

## `NearbyState` fields

| Field | Type | Description |
|-------|------|-------------|
| `status` | `NearbyStatus` | `idle`, `advertising`, `discovering`, `connecting`, `connected`, `error`, `deniedPermissions`, `locationDisabled` |
| `discoveredDevices` | `List<NearbyDevice>` | Devices found during discovery |
| `receivedUrl` | `String?` | Solana Pay URL received from connected device |
| `error` | `String?` | Error message if status is `error` |
| `isLocationEnabled` | `bool` | Whether device location service is on |

---

## License

MIT — see [LICENSE](../../LICENSE).
