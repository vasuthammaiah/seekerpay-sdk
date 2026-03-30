## 1.0.7

* Fix Seeker Genesis Token verification: each Seeker device has a unique per-device mint, so SGT ownership is now verified against the official collection group address (`GT22s89nU4iWFkNXj1Bw6uYhJJWDRPpShHt4Bk8f99Te`) instead of a single hardcoded mint address.
* Add dual-layer verification: Helius DAS (primary, checks grouping field) + standard RPC Token-2022 fallback (secondary, no Helius required).
* Chapter 2 Preorder Token (`2DMMamkkxQ6zDMBtkFp8KH7FoWzBMBA1CGTYwom4QH6Z`) continues to be verified by shared mint address.
* Bump seekerpay_core to ^1.0.7.

## 1.0.6

* Bump seekerpay_core to ^1.0.6.

## 1.0.5

* Bump seekerpay_core to ^1.0.5.

## 1.0.4

* Fix genesis token verification not detecting fungible Token-2022 tokens (Seeker Genesis Token and Chapter 2 Preorder Token) in connected wallets.

## 1.0.3

* Fix genesis token verification logic.

## 1.0.2

* Add dartdoc comments to all public APIs.
* Add pub.dev topics for discoverability.

## 1.0.1

* Add example pubspec.yaml referencing published package versions.

## 1.0.0

* Initial open-source release under MIT License.