import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'product_scan_state.dart';
import 'product_providers.dart';

class ProductScanNotifier extends Notifier<ProductScanState> {
  @override
  ProductScanState build() => const ProductScanState.idle();

  Future<void> onBarcodeDetected(String barcode) async {
    if (state.status != ProductScanStatus.idle && state.status != ProductScanStatus.scanning) return;

    state = ProductScanState.loading(barcode);

    final catalog = ref.read(productCatalogServiceProvider);
    final local = await catalog.get(barcode);
    if (local != null) {
      state = ProductScanState.found(local);
      return;
    }

    final lookup = ref.read(productLookupServiceProvider);
    final product = await lookup.lookup(barcode);

    if (product != null) {
      state = ProductScanState.found(product);
    } else {
      state = ProductScanState.notFound(barcode);
    }
  }

  void startScanning() => state = const ProductScanState.scanning();
  void reset() => state = const ProductScanState.idle();
}

final productScanProvider =
    NotifierProvider<ProductScanNotifier, ProductScanState>(
  ProductScanNotifier.new,
);
