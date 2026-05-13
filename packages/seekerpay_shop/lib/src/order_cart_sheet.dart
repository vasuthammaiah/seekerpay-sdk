import 'mrp_scan_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:seekerpay_core/seekerpay_core.dart';
import 'order_model.dart';
import 'order_notifier.dart';
import 'product_scan_sheet.dart';
import 'product_model.dart';
import 'product_scan_notifier.dart';
import 'product_scan_state.dart';

const _kPrimary = Color(0xFF00FFA3);

enum _LoyaltyStatus { idle, checking, member, notMember }

class OrderCartSheet extends ConsumerStatefulWidget {
  final double tokenPriceUsd;
  final String tokenSymbol;
  final int tokenDecimals;
  final void Function(double totalUsd, BigInt totalToken)? onPay;
  final bool loyaltyEnabled;
  final double loyaltyDiscountPct;
  final String merchantAddress;

  const OrderCartSheet({
    super.key,
    required this.tokenPriceUsd,
    required this.tokenSymbol,
    required this.tokenDecimals,
    this.onPay,
    this.loyaltyEnabled = false,
    this.loyaltyDiscountPct = 0,
    this.merchantAddress = '',
  });

  static Future<void> show({
    required BuildContext context,
    required double tokenPriceUsd,
    required String tokenSymbol,
    required int tokenDecimals,
    void Function(double totalUsd, BigInt totalToken)? onPay,
    bool loyaltyEnabled = false,
    double loyaltyDiscountPct = 0,
    String merchantAddress = '',
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF110022),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => OrderCartSheet(
        tokenPriceUsd: tokenPriceUsd,
        tokenSymbol: tokenSymbol,
        tokenDecimals: tokenDecimals,
        onPay: onPay,
        loyaltyEnabled: loyaltyEnabled,
        loyaltyDiscountPct: loyaltyDiscountPct,
        merchantAddress: merchantAddress,
      ),
    );
  }

  @override
  ConsumerState<OrderCartSheet> createState() => _OrderCartSheetState();
}

class _OrderCartSheetState extends ConsumerState<OrderCartSheet> {
  final _scrollCtrl = ScrollController();
  _LoyaltyStatus _loyaltyStatus = _LoyaltyStatus.idle;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onPay(Order order) {
    Navigator.of(context).pop();
    final totalToken = order.toTokenBaseUnits(tokenPriceUsd: widget.tokenPriceUsd, decimals: widget.tokenDecimals);
    widget.onPay?.call(order.totalUsd, totalToken);
  }

  Future<void> _scanCustomerQr() async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => const _WalletScanDialog(),
    );
    if (address == null || address.isEmpty) return;
    setState(() => _loyaltyStatus = _LoyaltyStatus.checking);
    try {
      final svc = ref.read(loyaltyNftServiceProvider);
      final has = await svc.customerHasLoyaltyPass(address, widget.merchantAddress);
      if (!mounted) return;
      setState(() => _loyaltyStatus = has ? _LoyaltyStatus.member : _LoyaltyStatus.notMember);
      if (has) {
        final discount = (ref.read(orderNotifierProvider).subtotalUsd * widget.loyaltyDiscountPct) / 100.0;
        await ref.read(orderNotifierProvider.notifier).setDiscount(discount);
      }
    } catch (_) {
      if (mounted) setState(() => _loyaltyStatus = _LoyaltyStatus.notMember);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(orderNotifierProvider);
    final scanState = ref.watch(productScanProvider);

    final String? tokenDisplay;
    if (widget.tokenPriceUsd > 0) {
      tokenDisplay = (order.totalUsd / widget.tokenPriceUsd).toStringAsFixed(widget.tokenSymbol == 'SOL' ? 4 : 2);
    } else {
      tokenDisplay = null;
    }

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        children: [
          _buildHeader(context, order, scanState),
          Expanded(
            child: order.isEmpty
                ? _buildEmptyState()
                : _buildItemList(order),
          ),
          if (widget.loyaltyEnabled) _buildLoyaltyBanner(),
          _BottomTotal(
            order: order,
            tokenDisplay: tokenDisplay,
            tokenSymbol: widget.tokenSymbol,
            tokenDecimals: widget.tokenDecimals,
            onPay: () => _onPay(order),
            onDiscount: (d) => ref.read(orderNotifierProvider.notifier).setDiscount(d),
          ),
        ],
      ),
    );
  }

  Widget _buildLoyaltyBanner() {
    const _kGold = Color(0xFFFFD700);
    final isMember = _loyaltyStatus == _LoyaltyStatus.member;
    final isChecking = _loyaltyStatus == _LoyaltyStatus.checking;
    final isNotMember = _loyaltyStatus == _LoyaltyStatus.notMember;

    return GestureDetector(
      onTap: isChecking ? null : _scanCustomerQr,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMember
              ? _kGold.withOpacity(0.12)
              : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isMember
                ? _kGold.withOpacity(0.5)
                : isNotMember
                    ? Colors.white12
                    : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isMember ? Icons.workspace_premium_rounded : Icons.qr_code_rounded,
              size: 16,
              color: isMember ? _kGold : Colors.white38,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: isChecking
                  ? const Text('Checking loyalty pass...', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold))
                  : isMember
                      ? Text(
                          'LOYALTY MEMBER  ·  ${widget.loyaltyDiscountPct.toStringAsFixed(0)}% DISCOUNT APPLIED',
                          style: const TextStyle(color: _kGold, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                        )
                      : Text(
                          isNotMember ? 'NO LOYALTY PASS FOUND  ·  TAP TO RESCAN' : 'SCAN CUSTOMER QR TO CHECK LOYALTY PASS',
                          style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                        ),
            ),
            if (isChecking)
              const SizedBox(
                width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
              )
            else if (!isMember)
              const Icon(Icons.chevron_right_rounded, size: 16, color: Colors.white24),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Order order, ProductScanState scanState) {
    final isBusy = scanState.status == ProductScanStatus.loading;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'SHOPPING CART',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${order.totalItems} ITEMS · ORDER #${order.id.split('-').last}',
                style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const Spacer(),
          if (isBusy)
            const Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: _kPrimary),
                ),
                SizedBox(width: 8),
                Text('SCANNING...', style: TextStyle(color: _kPrimary, fontSize: 10, fontWeight: FontWeight.w900)),
              ],
            )
          else
            Row(
              children: [
                IconButton(
                  onPressed: () => _showScanner(context),
                  icon: const Icon(Icons.qr_code_scanner_rounded, color: _kPrimary, size: 22),
                  tooltip: 'Scan barcode',
                ),
                IconButton(
                  onPressed: () => _showLabelScanner(context),
                  icon: const Icon(Icons.document_scanner_rounded, color: _kPrimary, size: 22),
                  tooltip: 'Scan label',
                ),
                IconButton(
                  onPressed: () => _showAddItemManually(context),
                  icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white38, size: 22),
                  tooltip: 'Add item manually',
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shopping_cart_outlined, size: 48, color: Colors.white.withOpacity(0.05)),
          const SizedBox(height: 16),
          const Text(
            'CART IS EMPTY',
            style: TextStyle(color: Colors.white12, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 2),
          ),
          const SizedBox(height: 8),
          const Text(
            'Scan products to add them to your order',
            style: TextStyle(color: Colors.white10, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildItemList(Order order) {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      itemCount: order.items.length,
      itemBuilder: (context, index) {
        final item = order.items[index];
        return _CartItemTile(
          item: item,
          onIncrement: () => ref.read(orderNotifierProvider.notifier).incrementQty(item.product.barcode),
          onDecrement: () => ref.read(orderNotifierProvider.notifier).decrementQty(item.product.barcode),
          onRemove: () => ref.read(orderNotifierProvider.notifier).removeItem(item.product.barcode),
        );
      },
    );
  }


  void _showScanner(BuildContext context) {
    ProductScanSheet.show(
      context,
      onConfirm: (product, priceUsd) {
        ref.read(orderNotifierProvider.notifier).addItem(product, priceUsd);
        ref.read(productScanProvider.notifier).reset();
      },
    );
  }

  void _showLabelScanner(BuildContext context) {
    MrpScanSheet.show(
      context,
      onConfirm: (product, priceUsd) {
        ref.read(orderNotifierProvider.notifier).addItem(product, priceUsd);
        ref.read(productScanProvider.notifier).reset();
      },
    );
  }

  Future<void> _showAddItemManually(BuildContext context) async {

    final result = await showDialog<_ManualItem>(
      context: context,
      builder: (_) => const _AddItemDialog(),
    );

    if (result != null) {
      final p = Product(
        barcode: 'MANUAL-${DateTime.now().millisecondsSinceEpoch}',
        name: result.name,
        brand: 'Manual Entry',
      );
      ref.read(orderNotifierProvider.notifier).addItem(p, result.priceUsd); ref.read(productScanProvider.notifier).reset();
    }
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

class _CartItemTile extends StatelessWidget {
  final OrderItem item;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final VoidCallback onRemove;

  const _CartItemTile({
    required this.item,
    required this.onIncrement,
    required this.onDecrement,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          // Thumbnail
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: item.product.imageUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(item.product.imageUrl!, fit: BoxFit.cover),
                  )
                : const Icon(Icons.inventory_2_outlined, color: Colors.white24, size: 20),
          ),
          const SizedBox(width: 12),
          // Name & Price
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.product.name.toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '\$${item.unitPriceUsd.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Qty controls
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _QtyBtn(icon: Icons.remove_rounded, onTap: onDecrement),
              Container(
                constraints: const BoxConstraints(minWidth: 32),
                alignment: Alignment.center,
                child: Text(
                  '${item.quantity}',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900),
                ),
              ),
              _QtyBtn(icon: Icons.add_rounded, onTap: onIncrement),
            ],
          ),
          const SizedBox(width: 8),
          // Subtotal
          SizedBox(
            width: 60,
            child: Text(
              '\$${item.totalUsd.toStringAsFixed(2)}',
              textAlign: TextAlign.end,
              style: const TextStyle(color: _kPrimary, fontSize: 12, fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _QtyBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: Colors.white70),
      ),
    );
  }
}

class _BottomTotal extends StatelessWidget {
  final Order order;
  final String? tokenDisplay;
  final String tokenSymbol;
  final int tokenDecimals;
  final VoidCallback onPay;
  final ValueChanged<double> onDiscount;

  const _BottomTotal({
    required this.order,
    required this.tokenDisplay,
    required this.tokenSymbol,
    required this.tokenDecimals,
    required this.onPay,
    required this.onDiscount,
  });

  Future<void> _showDiscountDialog(BuildContext context) async {
    final result = await showDialog<double>(
      context: context,
      builder: (_) => _DiscountDialog(subtotalUsd: order.subtotalUsd, currentDiscountUsd: order.discountUsd),
    );
    if (result != null) onDiscount(result);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF1A0033),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Discount row
          GestureDetector(
            onTap: () => _showDiscountDialog(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: order.hasDiscount ? Colors.green.withOpacity(0.12) : Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: order.hasDiscount ? Colors.green.withOpacity(0.4) : Colors.white12,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    order.hasDiscount ? Icons.local_offer_rounded : Icons.local_offer_outlined,
                    size: 14,
                    color: order.hasDiscount ? Colors.greenAccent : Colors.white38,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      order.hasDiscount ? 'DISCOUNT APPLIED' : 'ADD DISCOUNT',
                      style: TextStyle(
                        color: order.hasDiscount ? Colors.greenAccent : Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  if (order.hasDiscount) ...[
                    Text(
                      '-\$${order.discountUsd.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: order.hasDiscount ? Colors.greenAccent : Colors.white24,
                  ),
                ],
              ),
            ),
          ),

          // Tax row
          if (order.hasTax)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("${order.taxLabel} (${order.taxRate}%)", style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1)),
                  Text("\$${order.taxUsd.toStringAsFixed(2)}", style: const TextStyle(color: Colors.white38, fontSize: 13, fontWeight: FontWeight.w700)),
                ],
              ),
            ),

          // Subtotal row (only shown when discount is active)
          if (order.hasDiscount)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('SUBTOTAL', style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1)),
                  Text('\$${order.subtotalUsd.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white38, fontSize: 13, fontWeight: FontWeight.w700)),
                ],
              ),
            ),

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
              if (tokenDisplay != null)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'IN $tokenSymbol',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$tokenDisplay $tokenSymbol',
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

// ─── Manual item data carrier ─────────────────────────────────────────────────

class _ManualItem {
  final String name;
  final double priceUsd;
  const _ManualItem(this.name, this.priceUsd);
}

// ─── Add item manually dialog ─────────────────────────────────────────────────

class _AddItemDialog extends StatefulWidget {
  const _AddItemDialog();

  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final price = double.tryParse(_priceCtrl.text.trim()) ?? 0;
    if (name.isEmpty || price <= 0) return;
    Navigator.of(context).pop(_ManualItem(name, price));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF110022),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('ADD ITEM MANUALLY', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 2)),
            const SizedBox(height: 24),
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Item Name',
                labelStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white12)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Price (USD)',
                labelStyle: TextStyle(color: Colors.white38),
                prefixText: '\$ ',
                prefixStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white12)),
              ),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL', style: TextStyle(color: Colors.white38)))),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(backgroundColor: _kPrimary, foregroundColor: Colors.black),
                    child: const Text('ADD TO CART', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Wallet QR scan dialog (for loyalty check) ───────────────────────────────

class _WalletScanDialog extends StatefulWidget {
  const _WalletScanDialog();

  @override
  State<_WalletScanDialog> createState() => _WalletScanDialogState();
}

class _WalletScanDialogState extends State<_WalletScanDialog> {
  final _ctrl = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      // Accept raw base58 address or solana: URI
      final address = raw.startsWith('solana:') ? raw.split(':').last.split('?').first : raw;
      if (address.length >= 32 && address.length <= 44) {
        _done = true;
        _ctrl.stop();
        Navigator.of(context).pop(address);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.qr_code_scanner_rounded, color: _kPrimary, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'SCAN CUSTOMER WALLET',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 20),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 280,
              height: 280,
              child: MobileScanner(controller: _ctrl, onDetect: _onDetect),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Ask the customer to show their wallet QR code.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Discount dialog ─────────────────────────────────────────────────────────

class _DiscountDialog extends StatefulWidget {
  final double subtotalUsd;
  final double currentDiscountUsd;
  const _DiscountDialog({required this.subtotalUsd, required this.currentDiscountUsd});

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.currentDiscountUsd > 0) {
      _ctrl.text = widget.currentDiscountUsd.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF110022),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('ORDER DISCOUNT', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 2)),
            const SizedBox(height: 16),
            const Text('Enter discount amount to apply to subtotal.', style: TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 24),
            TextField(
              controller: _ctrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900),
              textAlign: TextAlign.center,
              autofocus: true,
              decoration: const InputDecoration(
                prefixText: '\$ ',
                prefixStyle: TextStyle(color: Colors.white38),
                hintText: '0.00',
                hintStyle: TextStyle(color: Colors.white10),
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(child: TextButton(onPressed: () => Navigator.pop(context, 0.0), child: const Text('REMOVE', style: TextStyle(color: Color(0xFFFF5555))))),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, double.tryParse(_ctrl.text.trim()) ?? 0.0),
                    style: ElevatedButton.styleFrom(backgroundColor: _kPrimary, foregroundColor: Colors.black),
                    child: const Text('APPLY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
