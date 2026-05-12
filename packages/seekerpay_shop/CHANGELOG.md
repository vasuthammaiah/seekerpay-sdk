# Changelog

## 1.2.0

* Add tax support to `Order`: `taxRate`, `country`, `taxUsd`, `taxLabel` (auto-detects GST/VAT/TAX by country).
* Add inventory tracking to `Product`: `stockLevel`, `lowStockThreshold`, `isLowStock`, `isOutOfStock`.
* Add `OrderNotifier.setTaxRate` and `setCountry`; all mutating methods are now async with an init-completion guard.
* Add `HistoryNotifier.decrementStock` to reduce stock levels after a completed order.
* Add loyalty check to `OrderCartSheet`: scan customer wallet QR → `LoyaltyNftService.customerHasLoyaltyPass` → auto-apply discount. Accepts `loyaltyEnabled`, `loyaltyDiscountPct`, and `merchantAddress` params.
* Add `ProductScanStatus.idle` and `ProductScanNotifier.startScanning()` to prevent scans during sheet initialisation.
* Fix Irys upload: switch from signature type 4 (Solana) to type 2 (Ed25519 generic) and add `uploader.irys.xyz` + `turbo.ardrive.io` as upload endpoints.

## 1.1.0

* Add native SOL payment support and multi-token utilities.
* Enhance Order model and notifier with multi-token persistence.
* Synchronize with seekerpay_core 1.3.0.

## 1.0.5

- **UI**: Shop config tiles (`ShopLlmSettings`, `ClaudeVisionSettings`) — replaced yellow accent with white, transparent card backgrounds, consistent input fills and switch colors for dark purple shop mode theme.

## 1.0.4

- **Product Catalog Arweave Sync**:
  - `ArweaveOrderService.saveProduct()` — encrypts and uploads products to Arweave with `Type=product_catalog` tag.
  - `ArweaveOrderService.restoreProducts()` — decrypts all catalog records; deduplicates by barcode keeping the latest `savedAt` version.
  - `ArweaveOrderService.syncProducts()` — pull-only sync; merges remote products missing locally and fills in `ownerPriceUsd` from Arweave where local has none.
  - `ArweaveOrderClient.queryProducts()` — new GraphQL query targeting `Type=product_catalog` (refactored shared `_query()` helper).
  - `ArweaveProductSyncResult` model for product sync results.
- **`ownerPriceUsd` priority in scanning**:
  - `ProductScanSheet` now pre-fills price with `ownerPriceUsd` (merchant's set price) instead of `lastPriceUsd` when a local catalog match is found.
- **`HistoryNotifier` improvements**:
  - `updateProduct()` / `saveOrder()` / `deleteProduct()` now keep `ProductCatalogService` (SharedPreferences) in sync so barcode lookup always sees the latest `ownerPriceUsd`.
  - `updateProduct()` triggers an async Arweave backup immediately after save.
  - `startBackgroundSync()` now pulls the product catalog from Arweave alongside orders.
- **Order cart**:
  - Manual item entry (`ADD ITEM MANUALLY` button) — type name + price without scanning.
  - Order-level discount — flat `$` or `%` discount with live preview; stored as `discountUsd` on `Order`; backward-compatible JSON.
  - `setDiscount()` added to `OrderNotifier`.
  - Dialog overflow fixed for keyboard-up state (`insetPadding` + `SingleChildScrollView`).
- **Payment tolerance**:
  - Overpayment auto-accepts; underpayment shows orange `PARTIAL PAYMENT` banner with remaining SKR; QR updates to remaining amount.

## 1.0.3

- **Arweave/Irys Sync Fixes**:
  - Corrected Ed25519 signature implementation for Solana (Irys requires hex-encoded ASCII signing of the deepHash).
  - Standardized `deepHash` implementation to Arweave 2.0 specs.
  - Implemented multi-node GraphQL failover (node1, node2, uploader, arweave.net).
  - Increased query timeouts to 90s and added retry logic to handle network lag.
- **UI Enhancements**:
  - Redesigned configuration alerts with a modern dark theme and context-aware icons.
  - Added a 'CONFIGURE' button to jump directly to shop settings.
- **Dependencies**:
  - Added `go_router` for improved navigation handling.

## 1.0.2

- Added fallback for barcode lookup via Open Food Facts (free)
- Added documentation comments to `ProductLookupService`

## 1.0.1

- Remove unused imports, fields, and local variables
- Replace deprecated `withOpacity()` with `withValues(alpha:)`

## 1.0.0

- Initial release
- Barcode and MRP label scanning with Google ML Kit
- On-device AI (Gemma 3 1B via flutter_gemma) and cloud AI (Claude Vision) label reading
- Product lookup via Barcode Lookup API
- Order cart with SKR token pricing
- Scan and order history with SharedPreferences
- Arweave/Irys decentralised order storage
- Currency conversion utilities
- Riverpod-based state management
