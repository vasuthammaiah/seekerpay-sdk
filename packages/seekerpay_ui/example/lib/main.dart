/// seekerpay_ui — example app.
///
/// Demonstrates AppTheme, AppColors, NfcPulseAnimation, and PaymentPreviewSheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:seekerpay_core/seekerpay_core.dart';
import 'package:seekerpay_ui/seekerpay_ui.dart';

void main() {
  // Configure the app identity shown in the wallet signing dialog.
  // Replace with your own app name and domain.
  MwaClient.instance.configure(
    identityName: 'seekerpay',
    identityUri: Uri.parse('https://seekerpay.live'),
  );
  runApp(const ProviderScope(child: _App()));
}

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'seekerpay_ui example',
        // Apply the SeekerPay dark theme
        theme: AppTheme.darkTheme,
        debugShowCheckedModeBanner: false,
        home: const _HomeScreen(),
      );
}

class _HomeScreen extends ConsumerWidget {
  const _HomeScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('seekerpay_ui')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Colour swatches ──────────────────────────────────────────
            const Text('APP COLORS',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 2, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _Swatch('primary', AppColors.primary),
              _Swatch('surface', AppColors.surface),
              _Swatch('purple', AppColors.purple),
              _Swatch('green', AppColors.green),
              _Swatch('blue', AppColors.blue),
              _Swatch('orange', AppColors.orange),
              _Swatch('pink', AppColors.pink),
            ]),

            const SizedBox(height: 32),

            // ── NFC pulse animation ──────────────────────────────────────
            const Text('NFC PULSE ANIMATION',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 2, color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            const Center(child: NfcPulseAnimation(size: 180)),

            const SizedBox(height: 32),

            // ── PaymentPreviewSheet ──────────────────────────────────────
            const Text('PAYMENT PREVIEW SHEET',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 2, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _showSheet(context),
              child: const Text('Open PaymentPreviewSheet'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PaymentPreviewSheet(
        request: PaymentRequest(
          recipient: 'CvH5vBxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
          amount: BigInt.from(2500000), // 2.5 SKR
          label: 'UI Example',
        ),
        onConfirm: (offlineReady) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Confirmed (offline: $offlineReady)')),
          );
        },
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final String name;
  final Color color;
  const _Swatch(this.name, this.color);

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
          ),
          const SizedBox(height: 4),
          Text(name, style: const TextStyle(fontSize: 9, color: AppColors.textSecondary)),
        ],
      );
}
