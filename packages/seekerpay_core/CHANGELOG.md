## 1.0.7

* Add `getToken22BalanceByMint` RPC method: checks a wallet's Token-2022 token balance by mint using the Token-2022 program directly, no Helius key required.
* Add `hasToken22InGroup` RPC method: inspects Token-2022 mint account extensions (groupMember / groupMemberPointer) and mint authority to verify collection membership without Helius.
* Fix `getAssetsByOwner`: add `page: 1` parameter for reliable Helius DAS pagination.

## 1.0.6

* Fix received SKR activities not showing: sort merged signatures by blockTime before applying the 20-tx limit so receives are not pushed out by sends.

## 1.0.5

* Fix received SKR activity not showing: merge v0 lookup-table addresses into parser, guard accountIndex overflow, fix skrActivity flag for new ATAs.
* Fix activity service: add _isRefreshing guard to prevent concurrent loads, mounted checks, and silent error handling when cached data exists.
* Add 8-second background refresh timer to ActivityService.

## 1.0.4

* Align version with all other SeekerPay packages.

## 1.0.3

* Add `showFungible` parameter to `getAssetsByOwner` to support fungible Token-2022 asset lookups.

## 1.0.2

* Add dartdoc comments to all public APIs.
* Add pub.dev topics for discoverability.

## 1.0.1

* Add example pubspec.yaml referencing published package versions.

## 1.0.0

* Initial open-source release under MIT License.