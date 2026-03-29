# seekerpay_domains

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

Domain name resolution and Seeker identity for the SeekerPay SDK. Supports `.skr` domains (AllDomains/ANS protocol) and `.sol` / `.solana` domains (Bonfida SNS), with local SQLite caching, remote suggestions, and Seeker Genesis Token verification.

---

## Features

- **`.skr` resolution** — On-chain PDA derivation using the AllDomains (ANS) protocol. Program: `ALTNSZ46uaAUU7XUV6awvdorLGqAsPwa9shm7h4uP2FK`.
- **`.sol` / `.solana` resolution** — Bonfida SNS on-chain resolution. Program: `namesLPArUqS98px7zmx8SndX2C7M95E1S3Y8R6K`.
- **Multi-tier lookup** — Memory cache → SQLite cache → HTTP APIs → on-chain PDA (automatic fallback).
- **Paginated domain directory** — List registered `.skr` domains with `listSkrDomains()` (25 per page, scrollable).
- **Search & autocomplete** — `search()` queries the local SQLite cache instantly; `fetchRemoteSuggestions()` appends live results.
- **Seeker Genesis Token (SGT)** — Verify whether a wallet holds an SGT using the Helius DAS API. SGT group mint: `GT22s89nU4iWFkNXj1Bw6uYhJJWDRPpShHt4Bk8f99Te`.

---

## Installation

```yaml
dependencies:
  seekerpay_domains:
    path: ../packages/seekerpay_domains
```

---

## Usage

### Resolve a domain

```dart
// Via Riverpod provider (recommended)
final resolver = ref.read(snsResolverProvider);
final address = await resolver.resolve('alice.skr');
print(address); // 'CvH5vB...' or null if not found

// Also works for .sol domains
final solAddress = await resolver.resolve('solana.sol');
```

### Check if a string is a domain

```dart
resolver.isDomain('alice.skr');  // true
resolver.isDomain('alice.sol');  // true
resolver.isDomain('CvH5vB...');  // false — it's already an address
```

### Search / autocomplete

```dart
// Instant — queries local SQLite cache
final cached = await resolver.search('ali');
// [{'domain': 'alice.skr', 'address': 'CvH5vB...'}, ...]

// Live — queries remote APIs and appends new results
final remote = await resolver.fetchRemoteSuggestions('ali');
```

### List the `.skr` directory (paginated)

```dart
// First page (25 domains, sorted alphabetically)
final page0 = await resolver.listSkrDomains(page: 0, limit: 25);

// Search within the directory
final results = await resolver.listSkrDomains(page: 0, limit: 25, search: 'pay');
// [{'domain': 'pay.skr', 'address': '...'}, ...]
```

### Verify Seeker Genesis Token

```dart
// Current connected wallet
final isVerified = await ref.read(isSeekerVerifiedProvider.future);

// Any arbitrary address
final isAliceVerified = await ref.read(isAddressVerifiedProvider('CvH5vB...').future);
```

### Riverpod providers

```dart
// SnsResolver instance
final resolver = ref.watch(snsResolverProvider);

// Genesis verification for current wallet (AsyncValue<bool>)
final isVerified = ref.watch(isSeekerVerifiedProvider).value ?? false;

// Genesis verification for a specific address
final isAliceVerified = ref.watch(isAddressVerifiedProvider(address)).value ?? false;
```

---

## Protocol Details

### AllDomains ANS (`.skr`)

```
Program:      ALTNSZ46uaAUU7XUV6awvdorLGqAsPwa9shm7h4uP2FK
Root key:     3mX9b4AZaQehNoQGfckVcmgmA6bkBoFcbLj9RMmMyNcU
Hash prefix:  'ALT Name Service'
PDA seed:     SHA-256('ALT Name Service' + domainName)
Owner bytes:  account_data[40..72]   (8-byte discriminator + 32-byte parent + 32-byte owner)
```

### Bonfida SNS (`.sol` / `.solana`)

```
Program:      namesLPArUqS98px7zmx8SndX2C7M95E1S3Y8R6K
Root key:     3mDfpdbSoE7kKpq5yZSWKBiLRppbBfRoFqcwGb8SSUR
Hash prefix:  '\x00'
PDA seed:     SHA-256('\x00' + domainName)
Owner bytes:  account_data[32..64]   (no discriminator)
```

### Seeker Genesis Token (SGT)

The SGT is a **Token-2022 group NFT** — each Seeker device receives a unique member token belonging to the group mint `GT22s89nU4iWFkNXj1Bw6uYhJJWDRPpShHt4Bk8f99Te`. Standard `getTokenAccountsByOwner` with a mint filter cannot detect group members. This SDK uses the **Helius DAS API** (`getAssetsByOwner`) and checks `grouping[].group_value` against the group mint address. Requires a Helius API key configured via `seekerpay_core`.

---

## License

MIT — see [LICENSE](../../LICENSE).
