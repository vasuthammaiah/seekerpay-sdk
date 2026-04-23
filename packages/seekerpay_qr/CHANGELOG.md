## 1.3.0

* Add native SOL payment support and multi-token utilities.
* Synchronize with seekerpay_core 1.3.0.

## 1.2.1

* Fix `SolanaPayUrl.encode()` to use RFC 3986 percent-encoding (`%20`) instead of
  Dart's `Uri.queryParameters` form-encoding (`+` for spaces), which caused QR codes
  to be unrecognised by Phantom, Solflare, and other external Solana wallets.
* Strip trailing `.0` from whole-number amounts in the encoded URL (e.g. `1` not `1.0`).

## 1.2.0

* Feature updates and internal improvements for the 1.2.0 release.
* Update internal dependencies to versioned hosted source.

## 1.1.1

* Bump version to match seekerpay_core 1.1.1.
* Improved MWA signing compatibility with external wallets (Jupiter on Samsung).
* Better RPC error handling with exponential backoff and rate-limit guidance.

## 1.1.0

* Bump seekerpay_core to ^1.1.0.
* Update example to call `MwaClient.instance.configure()` at startup for customisable wallet identity (app name + domain).

## 1.0.9

* Bump seekerpay_core dependency to ^1.0.9 (MWA identity fix: wallet now shows "Seeker Pay" with bitcoinvision.ai domain).

## 1.0.7

* Bump seekerpay_core to ^1.0.7.

## 1.0.6

* Bump seekerpay_core to ^1.0.6.

## 1.0.5

* Bump seekerpay_core to ^1.0.5.

## 1.0.4

* Align version with all other SeekerPay packages. Bump seekerpay_core to ^1.0.4.

## 1.0.3

* Bump seekerpay_core dependency to ^1.0.3.

## 1.0.2

* Add dartdoc comments to all public APIs.
* Add pub.dev topics for discoverability.

## 1.0.1

* Add example pubspec.yaml referencing published package versions.

## 1.0.0

* Initial open-source release under MIT License.