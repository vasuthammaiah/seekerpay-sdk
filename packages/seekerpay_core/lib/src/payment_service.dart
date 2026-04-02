import 'dart:async';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:solana_web3/solana_web3.dart' as web3;
import 'dart:convert';
import 'rpc_client.dart';
import 'skr_token.dart';
import 'mwa_client.dart';
import 'confirmation_poller.dart';
import 'pending_transaction_manager.dart';
import 'payment_providers.dart';

/// Progression stages of a payment operation, from building through confirmation.
enum PaymentStatus { idle, building, simulating, signing, sending, confirming, success, failed }

/// Immutable snapshot of the current payment operation state.
class PaymentState {
  /// Current stage of the payment flow.
  final PaymentStatus status;

  /// On-chain transaction signature once the transaction has been signed.
  final String? signature;

  /// Error message from the last failed payment attempt, if any.
  final String? error;

  /// The single [PaymentRequest] for a standard payment, if applicable.
  final PaymentRequest? request;

  /// All requests when performing a multi-recipient payment.
  final List<PaymentRequest>? multiRequests;

  /// `true` when the signed transaction was queued locally for later submission.
  final bool isOfflineReady;

  PaymentState({
    this.status = PaymentStatus.idle, 
    this.signature, 
    this.error, 
    this.request, 
    this.multiRequests,
    this.isOfflineReady = false,
  });

  /// Returns a copy of this state with the provided fields replaced.
  PaymentState copyWith({
    PaymentStatus? status,
    String? signature,
    String? error,
    PaymentRequest? request,
    List<PaymentRequest>? multiRequests,
    bool? isOfflineReady,
  }) {
    return PaymentState(
      status: status ?? this.status,
      signature: signature ?? this.signature,
      error: error,
      request: request ?? this.request,
      multiRequests: multiRequests ?? this.multiRequests,
      isOfflineReady: isOfflineReady ?? this.isOfflineReady,
    );
  }
}

/// Parameters for a single SKR token payment.
class PaymentRequest {
  /// Base58 public key of the payment recipient.
  final String recipient;

  /// Amount to send in SKR base units (1 SKR = 1,000,000 base units).
  final BigInt amount;

  /// Optional human-readable label for this payment.
  final String? label;
  PaymentRequest({required this.recipient, required this.amount, this.label});
}

/// Confirmation record returned after a successful payment.
class PaymentReceipt {
  /// On-chain transaction signature.
  final String signature;

  /// Amount transferred in SKR base units.
  final BigInt amount;

  /// Base58 public key of the recipient.
  final String recipient;

  /// Local time at which the receipt was created.
  final DateTime timestamp;

  /// `true` when the transaction was queued offline and not yet confirmed.
  final bool isPending;
  PaymentReceipt({required this.signature, required this.amount, required this.recipient, required this.timestamp, this.isPending = false});
}

/// Riverpod [StateNotifier] that orchestrates the full SKR payment lifecycle:
/// balance check, transaction building, simulation, MWA signing, submission,
/// and on-chain confirmation polling.
///
/// Supports an offline-ready mode where the signed transaction is stored via
/// [PendingTransactionManager] for deferred submission.
class PaymentService extends StateNotifier<PaymentState> {
  final RpcClient _rpcClient;
  final MwaClient _mwaClient;
  final String _payerAddress;
  final Ref _ref;
  final _pendingManager = PendingTransactionManager();

  PaymentService(this._rpcClient, this._mwaClient, this._payerAddress, this._ref) : super(PaymentState());

  /// Executes a single-recipient payment and returns a [PaymentReceipt] on success.
  ///
  /// Delegates to [payMulti] with a single [request].
  Future<PaymentReceipt?> pay(PaymentRequest request, {bool offlineReady = false, VoidCallback? onSuccess}) async {
    final signature = await payMulti([request], offlineReady: offlineReady, onSuccess: onSuccess);
    if (signature != null) {
      return PaymentReceipt(
        signature: signature,
        amount: request.amount,
        recipient: request.recipient,
        timestamp: DateTime.now(),
        isPending: state.isOfflineReady,
      );
    }
    return null;
  }

  /// Executes a multi-recipient SKR payment in a single transaction.
  ///
  /// When [offlineReady] is `true` the signed transaction is stored locally
  /// for later submission and the method returns immediately after signing.
  /// Returns the transaction signature on success, or `null` on failure.
  Future<String?> payMulti(List<PaymentRequest> requests, {bool offlineReady = false, VoidCallback? onSuccess}) async {
    if (requests.isEmpty) return null;
    
    state = state.copyWith(status: PaymentStatus.building, multiRequests: requests, isOfflineReady: false);
    try {
      final totalAmount = requests.fold(BigInt.zero, (sum, r) => sum + r.amount);
      
      // If we are definitely online, we do a pre-flight balance check.
      // If offlineReady is true, we might be offline, so we skip or wrap in try-catch.
      try {
        final currentBalance = await _rpcClient.getTokenAccountsByOwner(_payerAddress, SKRToken.mintAddress);
        if (currentBalance < totalAmount) {
          throw Exception('insufficient balance: You have ${(currentBalance.toDouble() / 1000000).toStringAsFixed(2)} SKR but need ${(totalAmount.toDouble() / 1000000).toStringAsFixed(2)} SKR');
        }
      } catch (e, st) { print('PaymentService Error: $e'); print(st);
        if (!offlineReady) rethrow;
        // If offlineReady, we continue anyway and let simulation or signing proceed
      }

      final blockhash = await _rpcClient.getLatestBlockhash().catchError((e) {
        if (offlineReady) return '11111111111111111111111111111111'; // Dummy if offline, but real apps should cache last known blockhash
        throw e;
      });

      final mintPubkey = web3.Pubkey.fromBase58(SKRToken.mintAddress.trim());
      final List<MultiTransfer> transfers = [];
      
      for (final req in requests) {
        final String recipient = req.recipient.trim();
        web3.Pubkey recipientPubkey = web3.Pubkey.fromBase58(recipient);

        final List<List<int>> seeds = [
          recipientPubkey.toBytes(),
          web3.Pubkey.fromBase58('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA').toBytes(),
          mintPubkey.toBytes(),
        ];
        final recipientATA = web3.Pubkey.findProgramAddress(
          seeds, 
          web3.Pubkey.fromBase58('ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL')
        ).pubkey;
        
        bool needsATA = true;
        try {
          final ataInfo = await _rpcClient.getAccountInfo(recipientATA.toBase58());
          needsATA = ataInfo == null;
        } catch (_) {
          // If offline, assume we might need to create it or skip if we're not sure
          if (!offlineReady) rethrow;
        }

        transfers.add(MultiTransfer(
          recipient: recipient,
          amount: req.amount,
          needsATA: needsATA,
        ));
      }

      final txBytes = await SplTokenTransfer.buildMulti(
        payer: _payerAddress.trim(), 
        transfers: transfers,
        mint: SKRToken.mintAddress.trim(), 
        blockhash: blockhash,
      );

      if (!offlineReady) {
        state = state.copyWith(status: PaymentStatus.simulating);
        final sim = await _rpcClient.simulateTransaction(txBytes).catchError((e) => SimulationResult(hasError: true, error: e));
        if (sim.hasError && !offlineReady) throw Exception('Simulation failed: ${sim.error}');
      }

      state = state.copyWith(status: PaymentStatus.signing);
      final signed = await _mwaClient.signTransaction(transactionBytes: txBytes);
      if (signed == null) { print('PaymentService: MWA returned null signed transaction'); throw Exception('User rejected the request'); }

      // Use web3.base58Encode to convert the first signature (Uint8List) to string
      final signature = web3.base58Encode(web3.Transaction.deserialize(signed).signatures.first);

      if (offlineReady) {
        // Store for later
        await _pendingManager.add(PendingTransaction(
          signature: signature,
          signedTxBase64: base64Encode(signed),
          createdAt: DateTime.now(),
          label: requests.length > 1 ? 'Multi-Pay' : requests.first.label,
          recipient: requests.length == 1 ? requests.first.recipient : null,
          amount: requests.length == 1 ? requests.first.amount : null,
        ));
        _ref.read(pendingTransactionsProvider.notifier).load(); // NOTIFY
        state = state.copyWith(status: PaymentStatus.success, signature: signature, isOfflineReady: true);
        onSuccess?.call();
        return signature;
      }

      state = state.copyWith(status: PaymentStatus.sending);
      await _rpcClient.sendTransaction(signed);
      state = state.copyWith(signature: signature, status: PaymentStatus.confirming);

      final poller = ConfirmationPoller(_rpcClient);
      await poller.waitForConfirmation(signature);

      state = state.copyWith(status: PaymentStatus.success);
      onSuccess?.call();
      return signature;
    } catch (e, st) { print('PaymentService Error: $e'); print(st);
      state = state.copyWith(status: PaymentStatus.failed, error: e.toString());
      return null;
    }
  }

  /// Attempts to submit all locally queued pending transactions to the network.
  ///
  /// Removes successfully submitted transactions and those already present
  /// on-chain. Updates the error field for transactions that fail for other reasons.
  Future<void> submitPendingTransactions() async {
    final pending = await _pendingManager.getAll();
    if (pending.isEmpty) return;

    bool anyChange = false;
    for (final tx in pending) {
      if (tx.error != null && tx.error!.contains('Blockhash not found')) {
        continue; // Don't spam RPC if we know it's dead, let user retry manually
      }

      try {
        print('SeekerPay: Attempting to submit pending tx ${tx.signature}');
        final bytes = base64Decode(tx.signedTxBase64);
        await _rpcClient.sendTransaction(bytes);
        
        print('SeekerPay: Successfully submitted pending tx ${tx.signature}');
        await _pendingManager.remove(tx.signature);
        anyChange = true;
      } catch (e, st) { print('PaymentService Error: $e'); print(st);
        final errorStr = e.toString();
        print('SeekerPay: Failed to submit pending tx ${tx.signature}: $errorStr');
        
        if (errorStr.contains('already processed') || 
            errorStr.contains('AlreadyProcessed') ||
            errorStr.contains('already exists')) {
          print('SeekerPay: Tx ${tx.signature} already exists on-chain/mempool, removing from queue.');
          await _pendingManager.remove(tx.signature);
          anyChange = true;
        } else {
          // Update transaction with error so user can see it in Offline screen
          await _pendingManager.update(PendingTransaction(
            signature: tx.signature,
            signedTxBase64: tx.signedTxBase64,
            createdAt: tx.createdAt,
            label: tx.label,
            recipient: tx.recipient,
            amount: tx.amount,
            error: errorStr,
          ));
          anyChange = true;
        }
      }
    }
    if (anyChange) {
      _ref.read(pendingTransactionsProvider.notifier).load(); // NOTIFY
    }
  }

  /// Resets payment state back to [PaymentStatus.idle].
  void reset() { state = PaymentState(); }
}
