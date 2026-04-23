import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'order_model.dart';
import 'product_model.dart';
import 'package:seekerpay_core/seekerpay_core.dart';

class OrderNotifier extends Notifier<Order> {
  static const _storageKey = 'spay_current_order';

  @override
  Order build() {
    _loadFromDisk();
    return Order(
      id: 'ORD-${DateTime.now().millisecondsSinceEpoch}',
      timestamp: DateTime.now(),
    );
  }

  Future<void> _loadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
        state = Order.fromJson(jsonMap);
      }
    } catch (_) {}
  }

  Future<void> _saveToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(state.toJson()));
    } catch (_) {}
  }

  void addItem(Product product, double usdPrice) {
    final items = List<OrderItem>.from(state.items);
    final existing = items.indexWhere((i) => i.product.barcode == product.barcode);

    if (existing >= 0) {
      items[existing] = items[existing].copyWith(
        quantity: items[existing].quantity + 1,
      );
    } else {
      items.add(OrderItem(
        product: product,
        quantity: 1,
        unitPriceUsd: usdPrice,
      ));
    }
    state = state.copyWith(items: items);
    _saveToDisk();
  }

  void incrementQty(String barcode) {
    final items = List<OrderItem>.from(state.items);
    final i = items.indexWhere((item) => item.product.barcode == barcode);
    if (i < 0) return;
    items[i] = items[i].copyWith(quantity: items[i].quantity + 1);
    state = state.copyWith(items: items);
    _saveToDisk();
  }

  void decrementQty(String barcode) {
    final items = List<OrderItem>.from(state.items);
    final i = items.indexWhere((item) => item.product.barcode == barcode);
    if (i < 0) return;
    if (items[i].quantity <= 1) {
      items.removeAt(i);
    } else {
      items[i] = items[i].copyWith(quantity: items[i].quantity - 1);
    }
    state = state.copyWith(items: items);
    _saveToDisk();
  }

  void removeItem(String barcode) {
    state = state.copyWith(
      items: state.items.where((i) => i.product.barcode != barcode).toList(),
    );
    _saveToDisk();
  }

  void setDiscount(double usd) {
    state = state.copyWith(discountUsd: usd.clamp(0.0, state.subtotalUsd));
    _saveToDisk();
  }

  void setToken(PaymentToken token) {
    state = state.copyWith(token: token);
    _saveToDisk();
  }

  void addSignature(String signature) {
    state = state.copyWith(signature: signature);
    _saveToDisk();
  }

  void clear() {
    state = Order(
      id: 'ORD-${DateTime.now().millisecondsSinceEpoch}',
      timestamp: DateTime.now(),
    );
    _saveToDisk();
  }
}

final orderNotifierProvider =
    NotifierProvider<OrderNotifier, Order>(OrderNotifier.new);
