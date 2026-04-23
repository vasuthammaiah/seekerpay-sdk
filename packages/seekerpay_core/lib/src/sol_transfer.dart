import 'dart:typed_data';
import 'package:solana_web3/solana_web3.dart' as web3;

/// Builds serialised native SOL transfer transactions.
class SolTransfer {
  /// Builds a single-recipient SOL transfer transaction.
  static Future<Uint8List> build({
    required String payer,
    required String recipient,
    required BigInt amount,
    required String blockhash,
  }) async {
    return buildMulti(
      payer: payer,
      transfers: [
        SolMultiTransfer(recipient: recipient, amount: amount)
      ],
      blockhash: blockhash,
    );
  }

  /// Builds a versioned (v0) SOL transfer transaction for one or more
  /// [transfers] from [payer].
  static Future<Uint8List> buildMulti({
    required String payer,
    required List<SolMultiTransfer> transfers,
    required String blockhash,
  }) async {
    final payerPubkey = web3.Pubkey.fromBase58(payer.trim());
    final List<web3.TransactionInstruction> instructions = [];

    for (final t in transfers) {
      final recipientPubkey = web3.Pubkey.fromBase58(t.recipient.trim());

      final data = ByteData(12);
      data.setUint32(0, 2, Endian.little); // index for transfer
      data.setUint64(4, t.amount.toInt(), Endian.little);

      instructions.add(web3.TransactionInstruction(
        keys: [
          web3.AccountMeta(payerPubkey, isWritable: true, isSigner: true),
          web3.AccountMeta(recipientPubkey, isWritable: true, isSigner: false),
        ],
        programId: web3.Pubkey.fromBase58('11111111111111111111111111111111'),
        data: data.buffer.asUint8List(),
      ));
    }

    final transaction = web3.Transaction.v0(
      payer: payerPubkey,
      instructions: instructions,
      recentBlockhash: blockhash,
    );
    
    return transaction.serialize().asUint8List();
  }
}

/// Describes a single SOL transfer leg within a multi-recipient transaction.
class SolMultiTransfer {
  /// Base58 public key of the SOL recipient.
  final String recipient;

  /// Transfer amount in lamports.
  final BigInt amount;

  SolMultiTransfer({
    required this.recipient,
    required this.amount,
  });
}
