# seekerpay_shop

Product lookup, catalog, and shop utilities for the SeekerPay SDK.

## Features

- **Barcode scanning** — camera-based barcode scanning with Google ML Kit
- **Product lookup** — checks local catalog first, then premium Barcode Lookup API (if key provided), and finally falls back to free Open Food Facts API
- **MRP label scanning** — OCR-powered MRP/price label detection with on-device AI (Gemma 3 1B) or cloud AI (Claude Vision)
- **Product catalog** — product model, lookup service, and Riverpod providers
- **Order cart** — order model, cart management, and cart sheet UI
- **Currency conversion** — USD and multi-currency support
- **Scan history** — persistent scan history with SharedPreferences
- **Arweave/Irys storage** — decentralised order storage on Arweave via Irys

## Installation

```yaml
dependencies:
  seekerpay_shop: ^1.1.0
```

## Usage

### Scan a barcode or MRP label

```dart
await ProductScanSheet.show(context, onConfirm: (product, usdPrice) {
  // handle scanned product
});

await MrpScanSheet.show(context, onConfirm: (product, usdPrice) {
  // handle scanned MRP label
});
```

### Show the order cart

```dart
OrderCartSheet.show(context, skrPerUsd: 0.02);
```

### Configure on-device LLM or Claude Vision

```dart
ShopLlmSettings(showHeader: true)
ClaudeVisionSettings(showHeader: true)
```

## Topics

solana · payments · shop · pos · web3

## License

MIT
