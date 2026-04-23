import 'transaction_record.dart';
import 'skr_token.dart';

class TransactionParser {
  static BigInt? _parseUiAmount(Map<String, dynamic> ui) {
    final amountStr = ui['amount']?.toString();
    if (amountStr != null) {
      return BigInt.tryParse(amountStr);
    }
    final uiStr = ui['uiAmountString']?.toString();
    final decimals = ui['decimals'];
    if (uiStr == null || decimals is! int) return null;
    final parts = uiStr.replaceAll(',', '').split('.');
    final whole = parts[0];
    final frac = parts.length > 1 ? parts[1] : '';
    final padded = (frac + List.filled(decimals, '0').join()).substring(0, decimals);
    return BigInt.tryParse('$whole$padded');
  }

  static List<TransactionRecord> parseMany({
    required Map<String, dynamic> txData,
    required String userAddress,
    required String signature,
    DateTime? fallbackTimestamp,
  }) {
    try {
      final List<TransactionRecord> records = [];
      final meta = txData['meta'];
      final transaction = txData['transaction'];
      if (meta == null || transaction == null) return [];

      // Skip failed transactions for the main activity list to avoid confusion,
      // though they still cost fees.
      if (meta['err'] != null) return [];

      final blockTime = txData['blockTime'] as int?;
      final timestamp = blockTime != null
          ? DateTime.fromMillisecondsSinceEpoch(blockTime * 1000)
          : (fallbackTimestamp ?? DateTime.now());

      final message = transaction['message'];
      if (message == null) return [];

      final accountKeys = message['accountKeys'] as List?;
      if (accountKeys == null) return [];

      // Start with static account keys
      final List<String> addresses = accountKeys.map((k) {
        if (k is String) return k;
        if (k is Map) return (k['pubkey'] as String? ?? '');
        return '';
      }).toList();

      // Merge lookup-table resolved addresses (v0 transactions).
      final loadedAddresses = meta['loadedAddresses'] as Map?;
      if (loadedAddresses != null) {
        final writable = loadedAddresses['writable'] as List? ?? [];
        final readonly = loadedAddresses['readonly'] as List? ?? [];
        for (final a in [...writable, ...readonly]) {
          addresses.add(a.toString());
        }
      }

      final targetAddr = userAddress.trim();

      // --- 1. Identify User Indices ---
      final userIndices = <int>{};
      for (int i = 0; i < addresses.length; i++) {
        if (addresses[i] == targetAddr) {
          userIndices.add(i);
        }
      }

      final preToken = meta['preTokenBalances'] as List? ?? [];
      final postToken = meta['postTokenBalances'] as List? ?? [];

      // Identify token accounts owned by the user or which the user is interacting with
      for (final b in [...preToken, ...postToken]) {
        final owner = b['owner']?.toString();
        final accountIndex = b['accountIndex'] as int?;
        if (accountIndex != null) {
          if (owner == targetAddr) {
            userIndices.add(accountIndex);
          }
        }
      }

      // --- 2. Check SKR Changes ---
      BigInt skrPre = BigInt.zero;
      BigInt skrPost = BigInt.zero;
      bool skrActivity = false;
      String? skrCounterparty;

      for (final b in preToken) {
        if (b['mint'] == SKRToken.mintAddress) {
          final accountIdx = b['accountIndex'] as int?;
          if (accountIdx != null && userIndices.contains(accountIdx)) {
            final ui = b['uiTokenAmount'] as Map<String, dynamic>?;
            final amount = ui != null ? _parseUiAmount(ui) : null;
            if (amount != null) {
              skrPre += amount;
            }
            skrActivity = true;
          }
        }
      }
      for (final b in postToken) {
        if (b['mint'] == SKRToken.mintAddress) {
          final accountIdx = b['accountIndex'] as int?;
          if (accountIdx != null) {
            final isUserAccount = userIndices.contains(accountIdx);
            final ui = b['uiTokenAmount'] as Map<String, dynamic>?;
            final amount = ui != null ? _parseUiAmount(ui) : null;

            if (isUserAccount) {
              if (amount != null) {
                skrPost += amount;
              }
              skrActivity = true;
            } else {
              final owner = b['owner']?.toString();
              skrCounterparty = owner ??
                  (accountIdx < addresses.length ? addresses[accountIdx] : null);
            }
          }
        }
      }

      final skrDiff = skrPost - skrPre;
      
      if (skrActivity && skrDiff != BigInt.zero) {
        records.add(TransactionRecord(
          signature: signature,
          timestamp: timestamp,
          amount: skrDiff.abs(),
          type: skrDiff > BigInt.zero ? TransactionType.receive : TransactionType.send,
          counterparty: skrCounterparty ?? 'SKR Transaction',
          symbol: 'SKR',
          decimals: SKRToken.decimals,
          mint: SKRToken.mintAddress,
        ));
        return records;
      }

      // --- 3. Check Native SOL Changes ---
      final preBalances = meta['preBalances'] as List? ?? [];
      final postBalances = meta['postBalances'] as List? ?? [];
      
      BigInt solPre = BigInt.zero;
      BigInt solPost = BigInt.zero;
      bool solActivity = false;
      String? solCounterparty;

      for (final idx in userIndices) {
        if (idx < preBalances.length) {
          solPre += BigInt.from(preBalances[idx]);
          solActivity = true;
        }
        if (idx < postBalances.length) {
          solPost += BigInt.from(postBalances[idx]);
          solActivity = true;
        }
      }

      final solDiff = solPost - solPre;
      final fee = BigInt.from(meta['fee'] ?? 0);

      // If sending SOL, the diff will be (amount + fee).
      // We want to show the amount, so we add back the fee if it was the sender.
      BigInt displaySolAmount = solDiff.abs();
      if (solDiff < BigInt.zero) {
        displaySolAmount = (solDiff + fee).abs();
      }

      // Identify SOL counterparty
      if (solDiff != BigInt.zero) {
        for (int i = 0; i < postBalances.length; i++) {
          if (userIndices.contains(i)) continue;
          final diff = BigInt.from(postBalances[i]) - BigInt.from(preBalances[i]);
          if (diff.abs() == displaySolAmount) {
            solCounterparty = i < addresses.length ? addresses[i] : null;
            break;
          }
        }
      }

      // Only show SOL activity if it's significant (more than just a fee)
      if (solActivity && displaySolAmount > BigInt.from(5000)) {
        records.add(TransactionRecord(
          signature: signature,
          timestamp: timestamp,
          amount: displaySolAmount,
          type: solDiff > BigInt.zero ? TransactionType.receive : TransactionType.send,
          counterparty: solCounterparty ?? 'Solana Transaction',
          symbol: 'SOL',
          decimals: 9,
          mint: null,
        ));
      }

      return records;
    } catch (e) {
      return [];
    }
  }
}
