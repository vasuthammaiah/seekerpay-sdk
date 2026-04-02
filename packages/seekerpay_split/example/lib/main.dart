/// seekerpay_split — example app.
///
/// Demonstrates creating an equal split, viewing participant status,
/// and triggering on-chain payment verification.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:seekerpay_split/seekerpay_split.dart';

void main() {
  runApp(const ProviderScope(child: _App()));
}

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'seekerpay_split example',
        theme: ThemeData.dark(),
        home: const _HomeScreen(),
      );
}

class _HomeScreen extends ConsumerStatefulWidget {
  const _HomeScreen();
  @override
  ConsumerState<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<_HomeScreen> {
  bool _creating = false;
  bool _refreshing = false;

  // Replace these with real Solana wallet addresses for testing.
  static const _organizerAddress = 'ORGANIZER_WALLET_ADDRESS';
  static const _participants = [
    {'address': 'PARTICIPANT_1_ADDRESS', 'domain': 'alice.skr'},
    {'address': 'PARTICIPANT_2_ADDRESS', 'domain': 'bob.skr'},
    {'address': 'PARTICIPANT_3_ADDRESS', 'domain': 'carol.skr'},
  ];

  Future<void> _createSplit() async {
    setState(() => _creating = true);
    await ref.read(splitBillProvider.notifier).createSplit(
      label: 'Dinner — SDK Demo',
      totalAmount: BigInt.from(6000000), // 6.00 SKR split equally (2 SKR each)
      participantInfo: _participants,
    );
    setState(() => _creating = false);
  }

  Future<void> _refresh(String splitId) async {
    setState(() => _refreshing = true);
    await ref.read(splitBillProvider.notifier).refreshSplitStatus(splitId, _organizerAddress);
    setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final bills = ref.watch(splitBillProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('seekerpay_split')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: _creating ? null : _createSplit,
              child: _creating
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Create Demo Split (6 SKR ÷ 3)'),
            ),

            const SizedBox(height: 24),

            Expanded(
              child: bills.isEmpty
                  ? const Center(child: Text('No splits yet. Tap the button above.', style: TextStyle(color: Colors.white38)))
                  : ListView.builder(
                      itemCount: bills.length,
                      itemBuilder: (context, i) => _BillCard(
                        bill: bills[i],
                        onRefresh: () => _refresh(bills[i].id),
                        onDelete: () => ref.read(splitBillProvider.notifier).deleteSplit(bills[i].id),
                        refreshing: _refreshing,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BillCard extends StatelessWidget {
  final SplitBill bill;
  final VoidCallback onRefresh;
  final VoidCallback onDelete;
  final bool refreshing;

  const _BillCard({
    required this.bill,
    required this.onRefresh,
    required this.onDelete,
    required this.refreshing,
  });

  @override
  Widget build(BuildContext context) {
    final skr = bill.totalAmount.toDouble() / 1e6;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(bill.label, style: const TextStyle(fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.delete_outline, size: 18), onPressed: onDelete, padding: EdgeInsets.zero),
            ]),
            Text('${skr.toStringAsFixed(2)} SKR total  •  ${bill.paidCount}/${bill.participants.length} paid',
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
            const Divider(height: 16),
            ...bill.participants.map((p) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(
                  p.status == SplitStatus.paid ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                  size: 16,
                  color: p.status == SplitStatus.paid ? Colors.green : Colors.white38,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  p.domain ?? '${p.address.substring(0, 8)}…',
                  style: const TextStyle(fontSize: 12),
                )),
                Text(
                  '${(p.amount.toDouble() / 1e6).toStringAsFixed(2)} SKR',
                  style: TextStyle(
                    fontSize: 12,
                    color: p.status == SplitStatus.paid ? Colors.green : Colors.white54,
                  ),
                ),
              ]),
            )),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: refreshing ? null : onRefresh,
                child: refreshing
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Verify On-Chain'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
