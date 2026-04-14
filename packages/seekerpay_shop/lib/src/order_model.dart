import 'product_model.dart';

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

  const Order({
    required this.id,
    required this.timestamp,
    this.items = const [],
    this.signature,
  });

  double get totalUsd =>
      items.fold(0.0, (sum, item) => sum + item.totalUsd);

  int get totalItems =>
      items.fold(0, (sum, item) => sum + item.quantity);

  bool get isEmpty => items.isEmpty;

  /// Convert total to SKR base units (6 decimals).
  /// [skrPerUsd] — current USD price of 1 SKR (e.g. 0.02026).
  BigInt toSkrBaseUnits(double skrPerUsd) {
    if (skrPerUsd <= 0) return BigInt.zero;
    final skrAmount = totalUsd / skrPerUsd;
    return BigInt.from((skrAmount * 1000000).round());
  }

  Order copyWith({String? id, DateTime? timestamp, List<OrderItem>? items, String? signature}) =>
      Order(
        id: id ?? this.id,
        timestamp: timestamp ?? this.timestamp,
        items: items ?? this.items,
        signature: signature ?? this.signature,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'items': items.map((i) => i.toJson()).toList(),
        'signature': signature,
      };

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        items: (json['items'] as List)
            .map((i) => OrderItem.fromJson(i as Map<String, dynamic>))
            .toList(),
        signature: json['signature'] as String?,
      );
}
