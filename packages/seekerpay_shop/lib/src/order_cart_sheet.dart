import 'local_llm_service.dart';
import 'mrp_ai_reader.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'order_model.dart';
import 'order_notifier.dart';
import 'product_scan_notifier.dart';
import 'product_scan_sheet.dart';
import 'mrp_scan_sheet.dart';

const _kPrimary = Color(0xFFFFEB3B);
const _kCard = Color(0xFF1A1A1A);

class OrderCartSheet extends ConsumerWidget {
  /// USD price of 1 SKR token — used to show SKR equivalent total.
  final double skrPerUsd;

  /// Fired when owner taps "SET AMOUNT & PAY".
  /// [totalUsd] — order total in USD.
  /// [totalSkr] — order total in SKR base units (6 decimals).
  final void Function(double totalUsd, BigInt totalSkr) onPay;

  const OrderCartSheet({
    super.key,
    required this.skrPerUsd,
    required this.onPay,
  });

  static Future<void> show(
    BuildContext context, {
    required double skrPerUsd,
    required void Function(double totalUsd, BigInt totalSkr) onPay,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ProviderScope(
        overrides: [
          productScanProvider.overrideWith(ProductScanNotifier.new),
        ],
        child: OrderCartSheet(skrPerUsd: skrPerUsd, onPay: onPay),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(orderNotifierProvider);
    final notifier = ref.read(orderNotifierProvider.notifier);
    final screenH = MediaQuery.of(context).size.height;

    final skrBaseUnits = order.toSkrBaseUnits(skrPerUsd);
    final skrDisplay = skrPerUsd > 0
        ? (skrBaseUnits.toDouble() / 1000000).toStringAsFixed(2)
        : null;

    return Container(
      height: screenH * 0.92,
      decoration: const BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // Handle
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Text(
                  'ORDER',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                if (order.totalItems > 0) ...[
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _kPrimary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${order.totalItems}',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (!order.isEmpty)
                  GestureDetector(
                    onTap: notifier.clear,
                    child: const Text(
                      'CLEAR',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                const SizedBox(width: 16),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Icon(Icons.close_rounded, color: Colors.white54, size: 22),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Scan buttons row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                // Barcode scan
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openScanner(context, ref),
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                    label: const Text(
                      'SCAN BARCODE',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kPrimary,
                      side: const BorderSide(color: _kPrimary, width: 1.2),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // MRP label scan
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openMrpScanner(context, ref),
                    icon: const Icon(Icons.document_scanner_rounded, size: 16),
                    label: const Text(
                      'SCAN LABEL',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF64B5F6),
                      side: const BorderSide(color: Color(0xFF64B5F6), width: 1.2),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Items list
          Expanded(
            child: order.isEmpty
                ? _emptyState()
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: order.items.length,
                    itemBuilder: (ctx, i) => _OrderItemTile(
                      item: order.items[i],
                      onIncrement: () => notifier.incrementQty(order.items[i].product.barcode),
                      onDecrement: () => notifier.decrementQty(order.items[i].product.barcode),
                      onRemove: () => notifier.removeItem(order.items[i].product.barcode),
                    ),
                  ),
          ),

          // Total + pay button
          if (!order.isEmpty)
            _BottomTotal(
              order: order,
              skrDisplay: skrDisplay,
              skrPerUsd: skrPerUsd,
              onPay: () {
                Navigator.of(context).pop();
                onPay(order.totalUsd, skrBaseUnits);
              },
            ),

          SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
        ],
      ),
    );
  }

  Future<bool> _showConfigAlert(BuildContext context, String title, String msg, {IconData icon = Icons.warning_amber_rounded}) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF111111),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Colors.white10)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: _kPrimary.withValues(alpha: 0.1), shape: BoxShape.circle),
                child: Icon(icon, color: _kPrimary, size: 32),
              ),
              const SizedBox(height: 20),
              Text(
                title.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 2),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                msg,
                style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, 'cancel'),
                      child: const Text('CANCEL', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, 'configure'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white, elevation: 0),
                      child: const Text('CONFIGURE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, 'proceed'),
                  style: ElevatedButton.styleFrom(backgroundColor: _kPrimary, foregroundColor: Colors.black, elevation: 0),
                  child: const Text('PROCEED ANYWAY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1)),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (result == 'configure') {
      if (context.mounted) {
        context.push('/shop-config');
      }
      return false;
    }
    return result == 'proceed';
  }

  Future<void> _openScanner(BuildContext context, WidgetRef ref) async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('spay_barcode_lookup_key') ?? '';
    final enabled = prefs.getBool('spay_barcode_lookup_enabled') ?? false;
    
    if (key.isEmpty || !enabled) {
      final proceed = await _showConfigAlert(
        context, 
        'Barcode Lookup', 
        'BarcodeLookup API key is not configured. The app will use the free Open Food Facts fallback, but results may be limited.',
        icon: Icons.qr_code_scanner_rounded,
      );
      if (!proceed) return;
    }

    ProductScanSheet.show(
      context,
      onConfirm: (product, usdPrice) {
        ref.read(orderNotifierProvider.notifier).addItem(product, usdPrice);
      },
    );
  }

  Future<void> _openMrpScanner(BuildContext context, WidgetRef ref) async {
    final isLlmInstalled = await LocalLlmService.isModelDownloaded();
    final isClaudeConfigured = await MrpAiReader.isConfigured;
    
    if (!isLlmInstalled && !isClaudeConfigured) {
      final proceed = await _showConfigAlert(
        context, 
        'AI Not Configured', 
        'Please configure either the Local LLM or Anthropic API key in settings to scan labels for accurate results.',
        icon: Icons.auto_awesome_rounded,
      );
      if (!proceed) return;
    }

    MrpScanSheet.show(
      context,
      onConfirm: (product, usdPrice) {
        ref.read(orderNotifierProvider.notifier).addItem(product, usdPrice);
      },
    );
  }

  Widget _emptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.receipt_long_rounded, color: Colors.white12, size: 48),
          SizedBox(height: 16),
          Text(
            'NO ITEMS YET',
            style: TextStyle(
              color: Colors.white24,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Tap SCAN PRODUCT to add items',
            style: TextStyle(color: Colors.white24, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ─── Order item tile ──────────────────────────────────────────────────────────

class _OrderItemTile extends StatelessWidget {
  final OrderItem item;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final VoidCallback onRemove;

  const _OrderItemTile({
    required this.item,
    required this.onIncrement,
    required this.onDecrement,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (item.product.imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                item.product.imageUrl!,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _productIcon(),
              ),
            )
          else
            _productIcon(),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.product.name.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (item.product.brand.isNotEmpty)
                  Text(
                    item.product.brand.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _QtyButton(icon: Icons.remove_rounded, onTap: onDecrement),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        '${item.quantity}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    _QtyButton(icon: Icons.add_rounded, onTap: onIncrement),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              GestureDetector(
                onTap: onRemove,
                child: const Icon(Icons.close_rounded, color: Colors.white24, size: 16),
              ),
              const SizedBox(height: 8),
              Text(
                '\$${item.totalUsd.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: _kPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (item.quantity > 1)
                Text(
                  '\$${item.unitPriceUsd.toStringAsFixed(2)} ea',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _productIcon() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(Icons.inventory_2_rounded, color: Colors.white24, size: 22),
    );
  }
}

class _QtyButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _QtyButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon, size: 14, color: Colors.white70),
      ),
    );
  }
}

class _BottomTotal extends StatelessWidget {
  final Order order;
  final String? skrDisplay;
  final double skrPerUsd;
  final VoidCallback onPay;

  const _BottomTotal({
    required this.order,
    required this.skrDisplay,
    required this.skrPerUsd,
    required this.onPay,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ORDER TOTAL',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '\$${order.totalUsd.toStringAsFixed(2)} USD',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              if (skrDisplay != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text(
                      'IN SKR',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$skrDisplay SKR',
                      style: const TextStyle(
                        color: _kPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onPay,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kPrimary,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              ),
              child: Text(
                'SET AMOUNT & PAY  ›  \$${order.totalUsd.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
