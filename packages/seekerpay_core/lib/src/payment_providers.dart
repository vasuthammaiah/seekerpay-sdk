import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'payment_service.dart';
import 'balance_providers.dart';
import 'wallet_state.dart';
import 'mwa_client.dart';
import 'pending_transaction_manager.dart';

final paymentServiceProvider = StateNotifierProvider<PaymentService, PaymentState>((ref) {
  final rpcClient = ref.watch(rpcClientProvider);
  final walletState = ref.watch(walletStateProvider);
  return PaymentService(rpcClient, MwaClient.instance, walletState.address ?? '', ref);
});

class PendingTransactionsNotifier extends StateNotifier<List<PendingTransaction>> {
  final _manager = PendingTransactionManager();

  PendingTransactionsNotifier() : super([]) {
    load();
  }

  Future<void> load() async {
    state = await _manager.getAll();
  }
}

final pendingTransactionsProvider = StateNotifierProvider<PendingTransactionsNotifier, List<PendingTransaction>>((ref) {
  return PendingTransactionsNotifier();
});
