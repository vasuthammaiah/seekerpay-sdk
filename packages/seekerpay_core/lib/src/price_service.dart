import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the latest USD prices for SOL and SKR tokens.
class TokenPrices {
  /// Current USD price of SOL.
  final double solUsd;

  /// Current USD price of SKR.
  final double skrUsd;

  TokenPrices({required this.solUsd, required this.skrUsd});

  /// Serialises this object to a JSON-compatible map.
  Map<String, dynamic> toJson() => {'solUsd': solUsd, 'skrUsd': skrUsd};

  /// Deserialises [TokenPrices] from a map produced by [toJson].
  factory TokenPrices.fromJson(Map<String, dynamic> json) =>
      TokenPrices(solUsd: json['solUsd'], skrUsd: json['skrUsd']);
}

/// Fetches and caches USD prices for SOL and SKR via the CoinGecko API.
class PriceService {
  final http.Client _client = http.Client();
  static const String _skrMint = 'SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3';
  static const String _cacheKey = 'cached_token_prices';

  /// Returns the last prices written to [SharedPreferences], or `null` if none
  /// have been cached yet.
  Future<TokenPrices?> getCachedPrices() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    if (cached != null) {
      return TokenPrices.fromJson(jsonDecode(cached));
    }
    return null;
  }

  /// Fetches live SOL and SKR prices from CoinGecko, persists them, and
  /// returns the result. Falls back to cached prices (or conservative defaults)
  /// if the API is unavailable.
  Future<TokenPrices> fetchPrices() async {
    try {
      // 1. Fetch SOL price
      final solResponse = await _client.get(
        Uri.parse('https://api.coingecko.com/api/v3/simple/price?ids=solana&vs_currencies=usd'),
      );

      // 2. Fetch SKR price via Contract Address (Solana network)
      final skrResponse = await _client.get(
        Uri.parse('https://api.coingecko.com/api/v3/simple/token_price/solana?contract_addresses=$_skrMint&vs_currencies=usd'),
      );

      double solPrice = 150.0; // Default fallback
      double skrPrice = 0.02026; // Default fallback

      if (solResponse.statusCode == 200) {
        final data = jsonDecode(solResponse.body);
        solPrice = (data['solana']['usd'] as num).toDouble();
      }

      if (skrResponse.statusCode == 200) {
        final data = jsonDecode(skrResponse.body);
        if (data[_skrMint.toLowerCase()] != null) {
          skrPrice = (data[_skrMint.toLowerCase()]['usd'] as num).toDouble();
        } else if (data[_skrMint] != null) {
          skrPrice = (data[_skrMint]['usd'] as num).toDouble();
        }
      }

      final prices = TokenPrices(solUsd: solPrice, skrUsd: skrPrice);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(prices.toJson()));
      
      return prices;
    } catch (e) {
      // Return last known good or conservative defaults if API is throttled
      final cached = await getCachedPrices();
      return cached ?? TokenPrices(solUsd: 150.0, skrUsd: 0.02026);
    }
  }
}

/// Riverpod [StateNotifier] that exposes [TokenPrices] as an [AsyncValue].
///
/// Initialises immediately from the local cache, then triggers a live refresh.
class PriceNotifier extends StateNotifier<AsyncValue<TokenPrices>> {
  final PriceService _service;

  PriceNotifier(this._service) : super(const AsyncValue.loading()) {
    _init();
  }

  Future<void> _init() async {
    final cached = await _service.getCachedPrices();
    if (cached != null) {
      state = AsyncValue.data(cached);
    }
    refresh();
  }

  /// Triggers a live price fetch and updates state. If the fetch fails and
  /// prices are already loaded, the existing value is kept.
  Future<void> refresh() async {
    try {
      final prices = await _service.fetchPrices();
      state = AsyncValue.data(prices);
    } catch (e, st) {
      if (!state.hasValue) {
        state = AsyncValue.error(e, st);
      }
    }
  }
}

/// Provider that creates a singleton [PriceService].
final priceServiceProvider = Provider((ref) => PriceService());

/// Provider for [PriceNotifier] that exposes live/cached token prices.
final pricesProvider = StateNotifierProvider<PriceNotifier, AsyncValue<TokenPrices>>((ref) {
  final service = ref.watch(priceServiceProvider);
  return PriceNotifier(service);
});
