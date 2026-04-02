import 'package:flutter/material.dart';
import 'package:seekerpay_core/seekerpay_core.dart';
import 'app_theme.dart';

/// A bottom-sheet widget that presents payment details to the user and lets
/// them optionally enable offline-ready mode before confirming.
///
/// Calls [onConfirm] with `true` when offline-ready mode is toggled on,
/// or `false` for an immediate online payment.
class PaymentPreviewSheet extends StatefulWidget {
  /// The payment to preview.
  final PaymentRequest request;

  /// Callback invoked when the user confirms the payment.
  /// The boolean argument is `true` if offline-ready mode was enabled.
  final void Function(bool offlineReady) onConfirm;
  const PaymentPreviewSheet({super.key, required this.request, required this.onConfirm});

  @override
  State<PaymentPreviewSheet> createState() => _PaymentPreviewSheetState();
}

class _PaymentPreviewSheetState extends State<PaymentPreviewSheet> {
  bool _offlineReady = false; bool _isConfirming = false;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottomInset),
      decoration: const BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Confirm Payment', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          _row('Recipient', widget.request.recipient.length > 20 ? '${widget.request.recipient.substring(0, 10)}...${widget.request.recipient.substring(widget.request.recipient.length - 10)}' : widget.request.recipient),
          const Divider(height: 32, color: Colors.white12),
          _row('Amount', '${(widget.request.amount.toDouble() / 1000000).toStringAsFixed(2)} SKR'),
          const Divider(height: 32, color: Colors.white12),
          _row('Network Fee', '≈ 0.000005 SOL'),
          const Divider(height: 32, color: Colors.white12),
          _row('They receive', '${(widget.request.amount.toDouble() / 1000000).toStringAsFixed(2)} SKR'),
          const SizedBox(height: 24),
          
          // Offline Mode Toggle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: _offlineReady ? AppColors.orange.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _offlineReady ? AppColors.orange.withValues(alpha: 0.3) : Colors.white12),
            ),
            child: Row(
              children: [
                Icon(_offlineReady ? Icons.wifi_off_rounded : Icons.wifi_rounded, size: 20, color: _offlineReady ? AppColors.orange : AppColors.textSecondary),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Offline-Ready Mode', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      Text('Sign now, auto-submit when connected', style: TextStyle(color: AppColors.textSecondary, fontSize: 10)),
                    ],
                  ),
                ),
                Switch(
                  value: _offlineReady,
                  onChanged: (v) => setState(() => _offlineReady = v),
                  activeThumbColor: AppColors.orange,
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
            child: const Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: AppColors.primary),
                SizedBox(width: 8),
                Text('Signed by Seed Vault · key never leaves device', style: TextStyle(color: AppColors.primary, fontSize: 10, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _isConfirming ? null : () { setState(() => _isConfirming = true); 
              Navigator.pop(context); 
              widget.onConfirm(_offlineReady); 
            }, 
            child: _isConfirming ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(_offlineReady ? 'Sign & Queue (Offline)' : 'Confirm & Sign'),
          ),
        ],
      ),
    );
  }

  Widget _row(String l, String v) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: const TextStyle(color: AppColors.textSecondary)), Text(v, style: const TextStyle(fontWeight: FontWeight.bold))]);
}
