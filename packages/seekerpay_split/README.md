# seekerpay_split

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

Group bill splitting and on-chain payment verification for the SeekerPay SDK. Create a split, share individual amounts with participants, and automatically verify on-chain whether each person has paid.

---

## Features

- **Create splits** — Equal split across addresses or custom per-participant amounts.
- **On-chain verification** — `refreshSplitStatus()` scans recent transaction history to auto-mark participants as paid (tolerance ±0.005 SKR for rounding).
- **Manual mark-as-paid** — Override any participant's status with `markAsPaid()`.
- **Persistence** — All splits stored in `SharedPreferences`; survive app restarts.
- **Riverpod state** — Reactive `List<SplitBill>` via `splitBillProvider`.

---

## Installation

```yaml
dependencies:
  seekerpay_split: ^1.3.0
```

---

## Usage

### Create an equal split

```dart
import 'package:seekerpay_split/seekerpay_split.dart';

// participantInfo is a list of {'address': '...', 'domain': '...'} maps
await ref.read(splitBillProvider.notifier).createSplit(
  label: 'Dinner at Seeker Cafe',
  totalAmount: BigInt.from(6_000_000), // 6.00 SKR split equally
  participantInfo: [
    {'address': 'ADDR_ALICE', 'domain': 'alice.skr'},
    {'address': 'ADDR_BOB',   'domain': 'bob.skr'},
    {'address': 'ADDR_CAROL', 'domain': 'carol.skr'},
  ],
);
// Each participant owes 2.000000 SKR (6 / 3)
```

### Create a split with custom amounts

```dart
await ref.read(splitBillProvider.notifier).createSplitFromRecipients(
  label: 'Road trip fuel',
  participants: [
    SplitParticipant(address: 'ADDR_ALICE', amount: BigInt.from(3_000_000)), // 3 SKR
    SplitParticipant(address: 'ADDR_BOB',   amount: BigInt.from(1_500_000)), // 1.5 SKR
  ],
);
```

### Check payment status (on-chain)

```dart
// Pass the organiser's address so the SDK knows which incoming transactions to inspect
await ref.read(splitBillProvider.notifier).refreshSplitStatus(
  splitId,
  organizerAddress,
);

// Read updated state
final bills = ref.watch(splitBillProvider);
final bill = bills.firstWhere((b) => b.id == splitId);
print('${bill.paidCount} / ${bill.participants.length} paid');
```

### Manually mark a participant as paid

```dart
await ref.read(splitBillProvider.notifier).markAsPaid(splitId, participantAddress);
```

### Delete a split

```dart
await ref.read(splitBillProvider.notifier).deleteSplit(splitId);
```

---

## Data Model

### `SplitBill`

| Field | Type | Description |
|-------|------|-------------|
| `id` | `String` | Unique identifier (epoch milliseconds) |
| `label` | `String` | Display name |
| `totalAmount` | `BigInt` | Total in base units |
| `participants` | `List<SplitParticipant>` | Individual records |
| `createdAt` | `DateTime` | Creation timestamp |
| `paidCount` | `int` | Computed: number of `SplitStatus.paid` participants |

### `SplitParticipant`

| Field | Type | Description |
|-------|------|-------------|
| `address` | `String` | Wallet address |
| `domain` | `String?` | `.skr` / `.sol` domain (optional) |
| `amount` | `BigInt` | Amount owed in base units |
| `status` | `SplitStatus` | `pending` / `paid` / `overdue` |

---

## Verification Logic

`refreshSplitStatus` scans the **organiser's 40 most recent transactions** for incoming SKR transfers from each participant whose amount matches (within ±0.005 SKR) and timestamp is after the split's `createdAt` minus a 5-minute clock-drift buffer. If not found on the organiser side, it falls back to scanning the **participant's outgoing transactions** for a matching payment to the organiser.

---

## License

MIT — see [LICENSE](../../LICENSE).
