import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:seekerpay_core/seekerpay_core.dart';
import 'package:solana_web3/solana_web3.dart' as web3;
import 'domain_cache.dart';

/// Resolves .skr, .sol, and .solana domain names to Solana wallet addresses.
///
/// .skr domains use the AllDomains (ANS) protocol:
///   Program  : ALTNSZ46uaAUU7XUV6awvdorLGqAsPwa9shm7h4uP2FK
///   Hash     : SHA-256("ALT Name Service" + name)
///   Root key : 3mX9b4AZaQehNoQGfckVcmgmA6bkBoFcbLj9RMmMyNcU
///   Owner    : account bytes [40-71]  (8-byte Anchor disc + 32-byte parent)
///
/// .sol / .solana domains use Bonfida SNS:
///   Program  : namesLPArUqS98px7zmx8SndX2C7M95E1S3Y8R6K
///   Hash     : SHA-256("\x00" + name)
///   Root key : 3mDfpdbSoE7kKpq5yZSWKBiLRppbBfRoFqcwGb8SSUR
///   Owner    : account bytes [32-63]
class SnsResolver extends ChangeNotifier {
  final _cache = <String, String?>{};
  final _reverseCache = <String, String>{};
  final RpcClient _rpc;
  final DomainCache? _persistentCache;

  // ── AllDomains / ANS protocol (.skr) ──────────────────────────────────────
  static const _ansProgramId  = 'ALTNSZ46uaAUU7XUV6awvdorLGqAsPwa9shm7h4uP2FK';
  static const _ansRootKey    = '3mX9b4AZaQehNoQGfckVcmgmA6bkBoFcbLj9RMmMyNcU';
  static const _ansHashPrefix = 'ALT Name Service';
  static const _ansOwnerOffset = 40; // 8-byte Anchor discriminator + 32-byte parentName

  // ── Bonfida SNS protocol (.sol / .solana) ────────────────────────────────
  static const _snsProgramId   = 'namesLPArUqS98px7zmx8SndX2C7M95E1S3Y8R6K';
  static const _snsRootKey     = '3mDfpdbSoE7kKpq5yZSWKBiLRppbBfRoFqcwGb8SSUR';
  static const _snsHashPrefix  = '\x00';
  static const _snsOwnerOffset = 32; // no discriminator in Bonfida SNS

  // ── Ed25519 constants for PDA derivation ──────────────────────────────────
  static final _p = BigInt.parse(
    '7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed',
    radix: 16,
  );
  static final _d = BigInt.parse(
    '52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3',
    radix: 16,
  );

  static const _base58Chars =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  SnsResolver(this._rpc, [this._persistentCache]);

  // ── Public API ────────────────────────────────────────────────────────────

  Future<String?> resolve(String domain) async {
    final input = domain.trim();
    if (input.isEmpty) return null;

    if (!isDomain(input)) {
      try {
        web3.Pubkey.fromBase58(input);
        return input;
      } catch (_) {
        return null;
      }
    }

    final cleanDomain = input.toLowerCase();

    // 1. Memory cache
    if (_cache.containsKey(cleanDomain)) return _cache[cleanDomain];

    // 2. SQLite persistent cache
    if (_persistentCache != null) {
      final cached = await _persistentCache.resolve(cleanDomain);
      if (cached != null) {
        _updateCache(cleanDomain, cached);
        return cached;
      }
    }

    print('SnsResolver: Resolving "$cleanDomain"…');
    String? owner;

    if (cleanDomain.endsWith('.skr')) {
      // 3. AllDomains HTTP API
      owner = await _resolveViaTldHouseApi(cleanDomain);
      // 4. On-chain ANS PDA resolution (always-available fallback)
      owner ??= await _resolveOnChainAns(cleanDomain);
    } else {
      // 3. Bonfida SNS HTTP API
      owner = await _resolveViaBonfidaApi(cleanDomain);
      // 4. On-chain Bonfida SNS PDA resolution
      owner ??= await _resolveOnChainSns(cleanDomain);
    }

    if (owner != null) {
      _updateCache(cleanDomain, owner);
      await _persistentCache?.saveDomains({cleanDomain: owner});
      print('SnsResolver: "$cleanDomain" → $owner');
    } else {
      print('SnsResolver: "$cleanDomain" not found on-chain.');
    }
    return owner;
  }

  /// Lists .skr domains sorted alphabetically with pagination.
  /// Tries remote API first; falls back to local SQLite cache.
  Future<List<Map<String, String>>> listSkrDomains({
    int page = 0,
    int limit = 25,
    String search = '',
  }) async {
    final offset = page * limit;
    final cleanSearch = search.trim().toLowerCase().replaceAll(RegExp(r'\.skr$'), '');
    final qParam = cleanSearch.isNotEmpty ? '&search=${Uri.encodeComponent(cleanSearch)}' : '';
    final qParam2 = cleanSearch.isNotEmpty ? '&q=${Uri.encodeComponent(cleanSearch)}' : '';

    final endpoints = [
      'https://api.all-domains.id/v1/domains?tld=skr&offset=$offset&limit=$limit&sort=name$qParam',
      'https://api.tld.house/v1/domains?tld=.skr&page=$page&limit=$limit$qParam2',
    ];

    for (final url in endpoints) {
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final items = _parseSkrSearchResponse(jsonDecode(res.body));
          if (items.isNotEmpty) {
            if (_persistentCache != null) {
              final toSave = <String, String>{};
              for (final r in items) {
                if (r['address']!.isNotEmpty) toSave[r['domain']!] = r['address']!;
              }
              if (toSave.isNotEmpty) await _persistentCache.saveDomains(toSave);
            }
            return items;
          }
        }
      } catch (_) {}
    }

    // Fallback: local SQLite cache
    if (_persistentCache == null) return [];
    final local = await _persistentCache.search(cleanSearch);
    local.sort((a, b) => a['domain']!.compareTo(b['domain']!));
    final end = (offset + limit).clamp(0, local.length);
    if (offset >= local.length) return [];
    return local.sublist(offset, end);
  }

  /// Searches only the local SQLite cache — instant, no network.
  Future<List<Map<String, String>>> search(String query) async {
    if (_persistentCache == null) return [];
    return _persistentCache.search(query);
  }

  /// Fetches .skr domain suggestions from the AllDomains API that start with
  /// [query], caches any results that include an address, and returns them.
  /// Call this after [search] to append live remote suggestions to the UI.
  Future<List<Map<String, String>>> fetchRemoteSuggestions(String query) async {
    final prefix = query.trim().toLowerCase().replaceAll(RegExp(r'\.skr$'), '');
    if (prefix.isEmpty) return [];

    final remote = await _fetchSkrSuggestions(prefix);
    if (remote.isEmpty) return [];

    // Cache entries that already have a resolved address
    if (_persistentCache != null) {
      final toSave = <String, String>{};
      for (final r in remote) {
        if (r['address']!.isNotEmpty) toSave[r['domain']!] = r['address']!;
      }
      if (toSave.isNotEmpty) await _persistentCache.saveDomains(toSave);
    }
    return remote;
  }

  Future<List<Map<String, String>>> _fetchSkrSuggestions(String prefix) async {
    final encoded = Uri.encodeComponent(prefix);
    final endpoints = [
      'https://api.all-domains.id/v1/domains/search?q=$encoded&tld=skr',
      'https://api.all-domains.id/v1/domains?query=$encoded&tld=skr',
      'https://api.tld.house/v1/search?q=$encoded&tld=.skr',
      'https://api.tld.house/v1/domains?q=$encoded&tld=.skr',
    ];

    for (final url in endpoints) {
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          final items = _parseSkrSearchResponse(jsonDecode(res.body));
          if (items.isNotEmpty) return items;
        }
      } catch (_) {}
    }
    return [];
  }

  static List<Map<String, String>> _parseSkrSearchResponse(dynamic data) {
    List? raw;
    if (data is Map) {
      raw = data['domains'] as List? ??
            data['results'] as List? ??
            data['data'] as List?;
    } else if (data is List) {
      raw = data;
    }
    if (raw == null) return [];

    final out = <Map<String, String>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      var domain = ((item['domain'] ?? item['name'] ?? '') as String).toLowerCase();
      if (domain.isEmpty) continue;
      if (!domain.endsWith('.skr')) domain = '$domain.skr';
      final address = ((item['owner'] ?? item['address'] ?? item['wallet'] ?? '') as String);
      out.add({'domain': domain, 'address': address});
    }
    return out;
  }

  Future<String?> resolveAddress(String address) async {
    if (_reverseCache.containsKey(address)) return _reverseCache[address];
    if (_persistentCache != null) {
      final results = await _persistentCache.search(address);
      for (final res in results) {
        if (res['address'] == address) {
          final domain = res['domain']!;
          _reverseCache[address] = domain;
          _cache[domain] = address;
          notifyListeners();
          return domain;
        }
      }
    }
    return null;
  }

  String? reverseResolve(String address) => _reverseCache[address];

  bool isDomain(String input) =>
      input.endsWith('.skr') ||
      input.endsWith('.sol') ||
      input.endsWith('.solana');

  // ── HTTP: AllDomains / TLD House ──────────────────────────────────────────

  Future<String?> _resolveViaTldHouseApi(String domain) async {
    final endpoints = [
      'https://api.all-domains.id/v1/resolve?name=$domain',
      'https://api.tld.house/v1/resolve?name=$domain',
    ];
    for (final url in endpoints) {
      try {
        final res =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final address = data['address'] as String?;
          if (address != null && address.isNotEmpty) return address;
        }
      } catch (_) {}
    }
    return null;
  }

  // ── HTTP: Bonfida SNS ─────────────────────────────────────────────────────

  Future<String?> _resolveViaBonfidaApi(String domain) async {
    final endpoints = [
      'https://sns-api.bonfida.com/v2/resolve/$domain',
      'https://sns-api.bonfida.com/resolve/$domain',
    ];
    for (final url in endpoints) {
      try {
        final res =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final result = data['result'];
          if (result is String &&
              result.isNotEmpty &&
              result != 'not_found' &&
              result != 'error') {
            return result;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  // ── On-chain: ANS/AllDomains (.skr) ──────────────────────────────────────
  //
  // Resolution steps for e.g. "vasjav.skr":
  //   1. TLD PDA  = findPDA([SHA256("ALT Name Service.skr"), 0s, ROOT_ANS], ANS_PROG)
  //   2. Name PDA = findPDA([SHA256("ALT Name Servicevasjav"), 0s, tld_pda], ANS_PROG)
  //   3. getAccountData(name_pda)
  //   4. owner = bytes[40..71]   (8-byte Anchor discriminator + 32-byte parentName)

  Future<String?> _resolveOnChainAns(String cleanDomain) async {
    try {
      final parts = cleanDomain.split('.');
      if (parts.length != 2) return null;
      final name = parts[0];
      final tld  = '.${parts[1]}'; // include the dot: ".skr"

      final prog    = _base58Decode(_ansProgramId);
      final rootKey = _base58Decode(_ansRootKey);

      // TLD PDA: hash(".skr") with ROOT_ANS as parent
      final tldHash  = _ansHash(tld);
      final tldPda   = _findProgramAddress([tldHash, Uint8List(32), rootKey], prog);
      print('SnsResolver: ANS TLD PDA ($tld) = ${_base58Encode(tldPda)}');

      // Domain PDA: hash("vasjav") with tldPda as parent
      final nameHash = _ansHash(name);
      final domPda   = _findProgramAddress([nameHash, Uint8List(32), tldPda], prog);
      final domAddr  = _base58Encode(domPda);
      print('SnsResolver: ANS domain PDA ($cleanDomain) = $domAddr');

      final data = await _rpc.getAccountData(domAddr);
      if (data == null || data.length < _ansOwnerOffset + 32) {
        print('SnsResolver: No ANS account at $domAddr for "$cleanDomain".');
        return null;
      }

      final ownerBytes = data.sublist(_ansOwnerOffset, _ansOwnerOffset + 32);
      return _base58Encode(ownerBytes);
    } catch (e) {
      print('SnsResolver: ANS on-chain error for "$cleanDomain": $e');
      return null;
    }
  }

  // ── On-chain: Bonfida SNS (.sol / .solana) ────────────────────────────────
  //
  // Resolution steps for e.g. "alice.sol":
  //   1. Name PDA = findPDA([SHA256("\x00alice"), 0s, SNS_ROOT], SNS_PROG)
  //   2. getAccountData(name_pda)
  //   3. owner = bytes[32..63]

  Future<String?> _resolveOnChainSns(String cleanDomain) async {
    try {
      final parts = cleanDomain.split('.');
      if (parts.length != 2) return null;
      final name = parts[0];

      final prog    = _base58Decode(_snsProgramId);
      final rootKey = _base58Decode(_snsRootKey);

      final nameHash = _snsHash(name);
      final domPda   = _findProgramAddress([nameHash, Uint8List(32), rootKey], prog);
      final domAddr  = _base58Encode(domPda);

      final data = await _rpc.getAccountData(domAddr);
      if (data == null || data.length < _snsOwnerOffset + 32) return null;

      final ownerBytes = data.sublist(_snsOwnerOffset, _snsOwnerOffset + 32);
      return _base58Encode(ownerBytes);
    } catch (e) {
      print('SnsResolver: SNS on-chain error for "$cleanDomain": $e');
      return null;
    }
  }

  // ── Hashing ───────────────────────────────────────────────────────────────

  /// ANS hash: SHA-256("ALT Name Service" + name)
  static Uint8List _ansHash(String name) {
    final bytes = utf8.encode('$_ansHashPrefix$name');
    return Uint8List.fromList(sha256.convert(bytes).bytes);
  }

  /// Bonfida SNS hash: SHA-256("\x00" + name)
  static Uint8List _snsHash(String name) {
    final bytes = utf8.encode('$_snsHashPrefix$name');
    return Uint8List.fromList(sha256.convert(bytes).bytes);
  }

  // ── PDA derivation ────────────────────────────────────────────────────────

  static Uint8List _findProgramAddress(
    List<Uint8List> seeds,
    Uint8List programId,
  ) {
    final marker = utf8.encode('ProgramDerivedAddress');
    for (var nonce = 255; nonce >= 0; nonce--) {
      final buf = <int>[];
      for (final s in seeds) buf.addAll(s);
      buf.add(nonce);
      buf.addAll(programId);
      buf.addAll(marker);
      final candidate = Uint8List.fromList(sha256.convert(buf).bytes);
      if (!_isOnEd25519Curve(candidate)) return candidate;
    }
    throw StateError('findProgramAddress: no valid PDA found');
  }

  static bool _isOnEd25519Curve(Uint8List point) {
    if (point.length != 32) return false;
    final yb = Uint8List.fromList(point);
    yb[31] &= 0x7F;
    var y = BigInt.zero;
    for (var i = 31; i >= 0; i--) {
      y = (y << 8) | BigInt.from(yb[i]);
    }
    if (y >= _p) return false;
    final y2 = y * y % _p;
    final u  = (y2 - BigInt.one) % _p;
    final v  = (_d * y2 + BigInt.one) % _p;
    if (v == BigInt.zero) return false;
    final x2 = u * v.modPow(_p - BigInt.two, _p) % _p;
    if (x2 == BigInt.zero) return true;
    return x2.modPow((_p - BigInt.one) ~/ BigInt.two, _p) == BigInt.one;
  }

  // ── Base58 encode / decode ────────────────────────────────────────────────

  static String _base58Encode(List<int> bytes) {
    var n = BigInt.zero;
    for (final b in bytes) n = n * BigInt.from(256) + BigInt.from(b);
    final out = <String>[];
    while (n > BigInt.zero) {
      out.insert(0, _base58Chars[(n % BigInt.from(58)).toInt()]);
      n ~/= BigInt.from(58);
    }
    for (final b in bytes) {
      if (b != 0) break;
      out.insert(0, '1');
    }
    return out.join();
  }

  static Uint8List _base58Decode(String s) {
    var n = BigInt.zero;
    for (final ch in s.runes) {
      final idx = _base58Chars.indexOf(String.fromCharCode(ch));
      if (idx < 0) throw ArgumentError('Invalid base58 char: $ch');
      n = n * BigInt.from(58) + BigInt.from(idx);
    }
    final bytes = <int>[];
    while (n > BigInt.zero) {
      bytes.insert(0, (n % BigInt.from(256)).toInt());
      n ~/= BigInt.from(256);
    }
    while (bytes.length < 32) bytes.insert(0, 0);
    return Uint8List.fromList(bytes);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _updateCache(String domain, String address) {
    _cache[domain] = address;
    _reverseCache[address] = domain;
    notifyListeners();
  }
}
