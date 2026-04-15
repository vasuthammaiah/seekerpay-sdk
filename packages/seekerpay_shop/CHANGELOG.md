# Changelog

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
