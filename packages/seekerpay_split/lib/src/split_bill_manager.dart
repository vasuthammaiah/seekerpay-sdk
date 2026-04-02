import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seekerpay_core/seekerpay_core.dart';

/// Payment status for a single participant in a split bill.
enum SplitStatus { pending, paid, overdue }

/// Represents one participant and their share in a split bill.
class SplitParticipant {
  /// Base58 wallet address of the participant.
  final String address;

  /// Optional resolved domain name (e.g. `.skr`) for display purposes.
  final String? domain;

  /// Amount owed by this participant in SKR base units.
  final BigInt amount;

  /// Current payment status for this participant.
  final SplitStatus status;

  SplitParticipant({
    required this.address, 
    this.domain, 
    required this.amount, 
    this.status = SplitStatus.pending
  });

  /// Returns a copy of this participant with an updated [status].
  SplitParticipant copyWith({SplitStatus? status}) => SplitParticipant(
    address: address, 
    domain: domain, 
    amount: amount, 
    status: status ?? this.status
  );

  /// Serialises this participant to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'address': address,
    'domain': domain,
    'amount': amount.toString(),
    'status': status.index,
  };

  /// Deserialises a [SplitParticipant] from a map produced by [toJson].
  factory SplitParticipant.fromJson(Map<String, dynamic> json) => SplitParticipant(
    address: json['address'],
    domain: json['domain'],
    amount: BigInt.parse(json['amount']),
    status: SplitStatus.values[json['status']],
  );
}

/// A bill-splitting session with a set of participants and their payment statuses.
class SplitBill {
  /// Unique identifier (milliseconds since epoch as a string).
  final String id;

  /// Human-readable description of the bill.
  final String label;

  /// Total bill amount in SKR base units.
  final BigInt totalAmount;

  /// All participants and their individual share amounts.
  final List<SplitParticipant> participants;

  /// Time at which the split was created.
  final DateTime createdAt;

  SplitBill({
    required this.id, 
    required this.label, 
    required this.totalAmount, 
    required this.participants, 
    required this.createdAt
  });

  /// Number of participants whose status is [SplitStatus.paid].
  int get paidCount => participants.where((p) => p.status == SplitStatus.paid).length;

  /// Serialises this bill to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'totalAmount': totalAmount.toString(),
    'participants': participants.map((p) => p.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
  };

  /// Deserialises a [SplitBill] from a map produced by [toJson].
  factory SplitBill.fromJson(Map<String, dynamic> json) => SplitBill(
    id: json['id'],
    label: json['label'],
    totalAmount: BigInt.parse(json['totalAmount']),
    participants: (json['participants'] as List).map((p) => SplitParticipant.fromJson(p)).toList(),
    createdAt: DateTime.parse(json['createdAt']),
  );
}

/// Riverpod [StateNotifier] that manages a list of [SplitBill] sessions,
/// persisting them to [SharedPreferences] and verifying payment status via RPC.
class SplitBillManager extends StateNotifier<List<SplitBill>> {
  final RpcClient _rpcClient;
  static const _storageKey = 'seekerpay_splits';

  SplitBillManager(this._rpcClient) : super([]) {
    _loadFromCache();
  }

  Future<void> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getStringList(_storageKey);
      if (data != null) {
        state = data.map((s) => SplitBill.fromJson(jsonDecode(s))).toList();
      }
    } catch (_) {}
  }

  Future<void> _saveToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = state.map((s) => jsonEncode(s.toJson())).toList();
      await prefs.setStringList(_storageKey, data);
    } catch (_) {}
  }

  /// Creates a new split bill, dividing [totalAmount] equally among
  /// [participantInfo] entries and persisting the result.
  Future<void> createSplit({
    required String label,
    required BigInt totalAmount,
    required List<Map<String, String>> participantInfo,
  }) async {
    if (participantInfo.isEmpty) return;
    
    final perPersonAmount = BigInt.from((totalAmount.toDouble() / participantInfo.length).ceil());
    final participants = participantInfo.map((info) => SplitParticipant(
      address: info['address']!, 
      domain: info['domain'], 
      amount: perPersonAmount
    )).toList();
    
    state = [
      ...state, 
      SplitBill(
        id: DateTime.now().millisecondsSinceEpoch.toString(), 
        label: label, 
        totalAmount: totalAmount, 
        participants: participants, 
        createdAt: DateTime.now()
      )
    ];
    await _saveToCache();
  }

  /// Creates a new split bill from a pre-built list of [participants] where
  /// each participant already has a specific amount assigned.
  Future<void> createSplitFromRecipients({
    required String label,
    required List<SplitParticipant> participants,
  }) async {
    final total = participants.fold(BigInt.zero, (sum, p) => sum + p.amount);
    state = [
      ...state,
      SplitBill(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        label: label,
        totalAmount: total,
        participants: participants,
        createdAt: DateTime.now(),
      )
    ];
    await _saveToCache();
  }

  /// Manually marks a specific participant as [SplitStatus.paid] and persists the change.
  Future<void> markAsPaid(String splitId, String participantAddress) async {
    state = [
      for (final s in state)
        if (s.id == splitId)
          SplitBill(
            id: s.id,
            label: s.label,
            totalAmount: s.totalAmount,
            participants: [
              for (final p in s.participants)
                if (p.address == participantAddress)
                  p.copyWith(status: SplitStatus.paid)
                else
                  p
            ],
            createdAt: s.createdAt,
          )
        else
          s
    ];
    await _saveToCache();
  }

  /// Checks the blockchain for incoming payments to [organizerAddress] and
  /// outgoing payments from each participant to auto-update [SplitStatus].
  ///
  /// Scans both the organizer's recent transactions and each unpaid
  /// participant's recent transactions. Matches on amount within a 0.001 SKR
  /// tolerance. Persists any status changes.
  Future<void> refreshSplitStatus(String splitId, String organizerAddress) async {
    if (organizerAddress.isEmpty) return;
    final splitIndex = state.indexWhere((s) => s.id == splitId);
    if (splitIndex == -1) return;
    
    final split = state[splitIndex];
    final updatedParticipants = List<SplitParticipant>.from(split.participants);
    bool changed = false;

    // --- STRATEGY: SCAN BOTH SIDES ---
    // 1. Scan ORGANIZER'S history for incoming payments
    List<TxSignature> organizerSigs = [];
    try {
      organizerSigs = await _rpcClient.getSignaturesForAddress(organizerAddress, limit: 40);
    } catch (_) {
      return;
    }
    
    // Use a 5-minute buffer before creation time to account for minor clock drift
    final windowSecs = (split.createdAt.millisecondsSinceEpoch / 1000) - 300;

    final recentOrganizerSigs = organizerSigs.where((s) => s.blockTime != null && s.blockTime! >= windowSecs).toList();
    
    final Map<String, dynamic> allTxData = {};
    if (recentOrganizerSigs.isNotEmpty) {
      final txs = await _rpcClient.getTransactions(recentOrganizerSigs.map((s) => s.signature).toList());
      for (int i = 0; i < txs.length; i++) {
        if (txs[i] != null) allTxData[recentOrganizerSigs[i].signature] = txs[i];
      }
    }

    for (int i = 0; i < updatedParticipants.length; i++) {
      final p = updatedParticipants[i];
      if (p.status == SplitStatus.paid) continue;

      bool found = false;

      // Check all fetched organizer transactions for a match
      for (int j = 0; j < recentOrganizerSigs.length; j++) {
        final sig = recentOrganizerSigs[j].signature;
        final txData = allTxData[sig];
        if (txData == null) continue;
        
        // Reliability check: Was the participant a signer?
        final accountKeys = txData['transaction']?['message']?['accountKeys'] as List?;
        bool isSigner = false;
        if (accountKeys != null) {
          for (final key in accountKeys) {
            final addr = key is String ? key : key['pubkey'];
            if (addr == p.address && (key is! String && key['signer'] == true)) {
              isSigner = true;
              break;
            }
          }
        }

        final records = TransactionParser.parseMany(
          txData: txData,
          userAddress: organizerAddress,
          signature: recentOrganizerSigs[j].signature,
          fallbackTimestamp: recentOrganizerSigs[j].blockTime != null
              ? DateTime.fromMillisecondsSinceEpoch(recentOrganizerSigs[j].blockTime! * 1000)
              : null,
        );
        for (final record in records) {
          if (record.type == TransactionType.receive) {
            // MATCH CRITERIA:
            // 1. Exact amount match
            // 2. Either the participant is the counterparty OR the participant is a signer of the tx
            if (record.amount == p.amount) {
              if (isSigner || record.counterparty == p.address) {
                found = true;
                break;
              }
            }
            
            // Fallback: If amount is within 0.001% (rounding differences)
            final diff = (record.amount - p.amount).abs();
            if (diff < BigInt.from(1000)) { // ~0.001 SKR tolerance
               if (isSigner || record.counterparty == p.address) {
                found = true;
                break;
              }
            }
          }
        }
        if (found) break;
      }

      // 2. SCAN PARTICIPANT'S SIDE (If not found on organizer side)
      if (!found && p.address.isNotEmpty) {
        try {
          final pSigs = await _rpcClient.getSignaturesForAddress(p.address, limit: 10);
          final recentPSigs = pSigs.where((s) => s.blockTime != null && s.blockTime! >= windowSecs).toList();
          
          if (recentPSigs.isNotEmpty) {
            final pTxs = await _rpcClient.getTransactions(recentPSigs.map((s) => s.signature).toList());
            for (int j = 0; j < pTxs.length; j++) {
              final txData = pTxs[j];
              if (txData == null) continue;

              final records = TransactionParser.parseMany(
                txData: txData,
                userAddress: p.address, // View from participant's side
                signature: recentPSigs[j].signature,
                fallbackTimestamp: recentPSigs[j].blockTime != null
                    ? DateTime.fromMillisecondsSinceEpoch(recentPSigs[j].blockTime! * 1000)
                    : null,
              );

              for (final record in records) {
                // On participant side, it should be a SEND to the organizer
                if (record.type == TransactionType.send && record.counterparty == organizerAddress) {
                  if ((record.amount - p.amount).abs() < BigInt.from(5000)) {
                    found = true;
                    break;
                  }
                }
              }
              if (found) break;
            }
          }
        } catch (_) {}
      }

      if (found) {
        updatedParticipants[i] = p.copyWith(status: SplitStatus.paid);
        changed = true;
      }
    }

    if (changed) {
      state = [
        for (final s in state)
          if (s.id == splitId) 
            SplitBill(
              id: split.id,
              label: split.label,
              totalAmount: split.totalAmount,
              participants: updatedParticipants,
              createdAt: split.createdAt,
            ) 
          else s
      ];
      await _saveToCache();
    }
  }

  /// Removes the split identified by [splitId] from state and persisted storage.
  Future<void> deleteSplit(String splitId) async {
    state = state.where((s) => s.id != splitId).toList();
    await _saveToCache();
  }
}

/// Provider for [SplitBillManager] using the current [rpcClientProvider].
final splitBillProvider = StateNotifierProvider<SplitBillManager, List<SplitBill>>((ref) {
  return SplitBillManager(ref.watch(rpcClientProvider));
});
