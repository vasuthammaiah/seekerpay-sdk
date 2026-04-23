import 'product_model.dart';
import 'dart:math' as math;
import 'package:seekerpay_core/seekerpay_core.dart';

class OrderItem {
  final Product product;
  final int quantity;
  final double unitPriceUsd;

  const OrderItem({
    required this.product,
    required this.quantity,
    required this.unitPriceUsd,
  });

  double get totalUsd => quantity * unitPriceUsd;

  OrderItem copyWith({int? quantity, double? unitPriceUsd}) => OrderItem(
        product: product,
        quantity: quantity ?? this.quantity,
        unitPriceUsd: unitPriceUsd ?? this.unitPriceUsd,
      );

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'quantity': quantity,
        'unitPriceUsd': unitPriceUsd,
      };

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
        product: Product.fromJson(json['product'] as Map<String, dynamic>),
        quantity: json['quantity'] as int,
        unitPriceUsd: (json['unitPriceUsd'] as num).toDouble(),
      );
}

class Order {
  final String id;
  final DateTime timestamp;
  final List<OrderItem> items;
  final String? signature;
  final double discountUsd;
  final PaymentToken token;

  const Order({
    required this.id,
    required this.timestamp,
    this.items = const [],
    this.signature,
    this.discountUsd = 0.0,
    this.token = PaymentToken.skr,
  });

  double get subtotalUsd =>
      items.fold(0.0, (sum, item) => sum + item.totalUsd);

  double get totalUsd =>
      (subtotalUsd - discountUsd).clamp(0.0, double.infinity);

  int get totalItems =>
      items.fold(0, (sum, item) => sum + item.quantity);

  bool get isEmpty => items.isEmpty;

  bool get hasDiscount => discountUsd > 0;

  /// Convert total to SKR base units (6 decimals).
  /// [skrPerUsd] — current USD price of 1 SKR (e.g. 0.02026).
  BigInt toSkrBaseUnits(double skrPerUsd) {
    return toTokenBaseUnits(tokenPriceUsd: skrPerUsd, decimals: 6);
  }

  /// Convert total to token base units.
  /// [tokenPriceUsd] — current USD price of 1 unit of the token.
  /// [decimals] — number of decimal places for the token.
  BigInt toTokenBaseUnits({required double tokenPriceUsd, required int decimals}) {
    if (tokenPriceUsd <= 0) return BigInt.zero;
    final amount = totalUsd / tokenPriceUsd;
    return BigInt.from((amount * math.pow(10, decimals)).round());
  }

  Order copyWith({String? id, DateTime? timestamp, List<OrderItem>? items, String? signature, double? discountUsd, PaymentToken? token}) =>
      Order(
        id: id ?? this.id,
        timestamp: timestamp ?? this.timestamp,
        items: items ?? this.items,
        signature: signature ?? this.signature,
        discountUsd: discountUsd ?? this.discountUsd,
        token: token ?? this.token,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'items': items.map((i) => i.toJson()).toList(),
        'signature': signature,
        if (discountUsd > 0) 'discountUsd': discountUsd,
        'token': token.index,
      };

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        items: (json['items'] as List)
            .map((i) => OrderItem.fromJson(i as Map<String, dynamic>))
            .toList(),
        signature: json['signature'] as String?,
        discountUsd: (json['discountUsd'] as num?)?.toDouble() ?? 0.0,
        token: json['token'] != null ? PaymentToken.values[json['token'] as int] : PaymentToken.skr,
      );
}
