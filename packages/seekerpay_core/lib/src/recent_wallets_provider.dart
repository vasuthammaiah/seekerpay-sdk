import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecentWallet {
  final String address;
  final String? domain;
  final DateTime lastPaid;
  RecentWallet({required this.address, this.domain, required this.lastPaid});
  Map<String, dynamic> toJson() => {'address': address, 'domain': domain, 'lastPaid': lastPaid.toIso8601String()};
  factory RecentWallet.fromJson(Map<String, dynamic> json) => RecentWallet(address: json['address'], domain: json['domain'], lastPaid: DateTime.parse(json['lastPaid']));
}

class RecentWalletsNotifier extends StateNotifier<List<RecentWallet>> {
  static const _key = 'recent_wallets';
  RecentWalletsNotifier() : super([]) { _load(); }
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(_key) ?? [];
    state = data.map((item) => RecentWallet.fromJson(jsonDecode(item))).toList()..sort((a, b) => b.lastPaid.compareTo(a.lastPaid));
  }
  Future<void> addWallet(String address, String? domain) async {
    final wallet = RecentWallet(address: address, domain: domain, lastPaid: DateTime.now());
    final filtered = state.where((w) => w.address != address).toList();
    state = [wallet, ...filtered].take(10).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, state.map((w) => jsonEncode(w.toJson())).toList());
  }
}

final recentWalletsProvider = StateNotifierProvider<RecentWalletsNotifier, List<RecentWallet>>((ref) => RecentWalletsNotifier());
