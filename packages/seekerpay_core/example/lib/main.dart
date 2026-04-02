/// SeekerPay Core — example app.
///
/// Demonstrates wallet connection, balance reading, and sending a SKR payment.
/// Run on an Android device with a Solana MWA-compatible wallet installed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:seekerpay_core/seekerpay_core.dart';

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
        title: 'seekerpay_core example',
        theme: ThemeData.dark(),
        home: const _HomeScreen(),
      );
}

class _HomeScreen extends ConsumerWidget {
  const _HomeScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallet = ref.watch(walletStateProvider);
    final skr = ref.watch(skrBalanceProvider);
    final sol = ref.watch(solBalanceProvider);
    final payment = ref.watch(paymentServiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('seekerpay_core')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Wallet connection
            wallet.address != null
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Connected wallet:', style: TextStyle(color: Colors.white54, fontSize: 11)),
                    const SizedBox(height: 4),
                    SelectableText(wallet.address!, style: const TextStyle(fontFamily: 'Courier', fontSize: 11)),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => ref.read(walletStateProvider.notifier).disconnect(),
                      child: const Text('Disconnect'),
                    ),
                  ])
                : ElevatedButton(
                    onPressed: wallet.isConnecting
                        ? null
                        : () => ref.read(walletStateProvider.notifier).connect(),
                    child: wallet.isConnecting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Connect Wallet (MWA)'),
                  ),

            const SizedBox(height: 24),

            // Balances
            Row(children: [
              Expanded(child: _BalanceTile(label: 'SKR', value: skr.when(
                data: (b) => '${(b.toDouble() / 1e6).toStringAsFixed(2)} SKR',
                loading: () => '…', error: (_, __) => 'Error',
              ))),
              const SizedBox(width: 12),
              Expanded(child: _BalanceTile(label: 'SOL', value: sol.when(
                data: (b) => '${(b.toDouble() / 1e9).toStringAsFixed(4)} SOL',
                loading: () => '…', error: (_, __) => 'Error',
              ))),
            ]),

            const SizedBox(height: 24),

            // Payment status
            Text('Payment status: ${payment.status.name}'),
            if (payment.signature != null)
              SelectableText('Tx: ${payment.signature}',
                  style: const TextStyle(fontFamily: 'Courier', fontSize: 10, color: Colors.green)),
            if (payment.error != null)
              Text(payment.error!, style: const TextStyle(color: Colors.red, fontSize: 11)),

            const SizedBox(height: 12),

            // Send button — replace DEMO_RECIPIENT with a real address
            ElevatedButton(
              onPressed: wallet.address == null ? null : () {
                ref.read(paymentServiceProvider.notifier).pay(
                  PaymentRequest(
                    recipient: 'DEMO_RECIPIENT_ADDRESS', // replace with real address
                    amount: BigInt.from(100000),         // 0.1 SKR
                    label: 'SDK Demo',
                  ),
                );
              },
              child: const Text('Send 0.1 SKR (demo)'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BalanceTile extends StatelessWidget {
  final String label;
  final String value;
  const _BalanceTile({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.white54)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ]),
      );
}
