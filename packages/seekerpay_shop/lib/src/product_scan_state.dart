import 'product_model.dart';

enum ProductScanStatus { idle, scanning, loading, found, notFound }

class ProductScanState {
  final ProductScanStatus status;
  final String? barcode;
  final Product? product;

  const ProductScanState({
    required this.status,
    this.barcode,
    this.product,
  });

  const ProductScanState.idle()
      : status = ProductScanStatus.idle,
        barcode = null,
        product = null;

  const ProductScanState.scanning()
      : status = ProductScanStatus.scanning,
        barcode = null,
        product = null;

  const ProductScanState.loading(String b)
      : status = ProductScanStatus.loading,
        barcode = b,
        product = null;

  ProductScanState.found(Product p)
      : status = ProductScanStatus.found,
        barcode = p.barcode,
        product = p;

  const ProductScanState.notFound(String b)
      : status = ProductScanStatus.notFound,
        barcode = b,
        product = null;
}
