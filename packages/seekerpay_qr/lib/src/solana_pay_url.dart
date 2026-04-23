import 'package:seekerpay_core/seekerpay_core.dart';

/// Represents a Solana Pay transfer request URL (`solana:<recipient>?...`).
///
/// Provides [encode] to produce a URI string and [decode] to parse one.
class SolanaPayUrl {
  /// Base58 public key of the payment recipient.
  final String recipient;

  /// Transfer amount in token base units (amount × 10^6 for 6-decimal tokens, 10^9 for SOL).
  final BigInt? amount;

  /// SPL token mint address. When omitted, the request is for native SOL.
  final String? splToken;

  /// Optional human-readable label for the payment.
  final String? label;

  /// Optional message to display to the user.
  final String? message;
  SolanaPayUrl({required this.recipient, this.amount, this.splToken, this.label, this.message});

  /// Encodes this object as a `solana:` URI string suitable for embedding in a QR code.
  String encode() {
    final buffer = StringBuffer('solana:');
    buffer.write(recipient);

    final params = <String>[];
    if (amount != null) {
      // Use 9 decimals for SOL (no splToken) and 6 for SKR (assuming all SPL tokens are 6 for SPAY).
      final decimals = splToken == null ? 9 : 6;
      final divisor = BigInt.from(10).pow(decimals);
      
      final whole = amount! ~/ divisor;
      final fraction = amount! % divisor;
      
      String amountStr = whole.toString();
      if (fraction > BigInt.zero) {
        amountStr += '.${fraction.toString().padLeft(decimals, '0').replaceAll(RegExp(r'0+$'), '')}';
      }
      params.add('amount=$amountStr');
    }
    if (splToken != null) params.add('spl-token=${Uri.encodeComponent(splToken!)}');
    if (label != null)    params.add('label=${Uri.encodeComponent(label!)}');
    if (message != null)  params.add('message=${Uri.encodeComponent(message!)}');

    if (params.isNotEmpty) {
      buffer.write('?');
      buffer.write(params.join('&'));
    }
    return buffer.toString();
  }

  /// Parses a `solana:` URI string into a [SolanaPayUrl].
  static SolanaPayUrl decode(String url) {
    if (!url.startsWith('solana:')) throw const FormatException('Not a valid Solana Pay URL');
    
    final uri = Uri.parse(url);
    final amountStr = uri.queryParameters['amount'];
    final splToken = uri.queryParameters['spl-token'];
    
    final queryStart = url.indexOf('?');
    String recipient = queryStart == -1 
        ? url.substring('solana:'.length) 
        : url.substring('solana:'.length, queryStart);
    
    while (recipient.startsWith('/')) {
      recipient = recipient.substring(1);
    }
    while (recipient.endsWith('/')) {
      recipient = recipient.substring(0, recipient.length - 1);
    }

    BigInt? amount;
    if (amountStr != null) {
      final decimals = splToken == null ? 9 : 6;
      final parts = amountStr.split('.');
      final wholePart = BigInt.parse(parts[0]);
      BigInt fractionPart = BigInt.zero;
      if (parts.length > 1) {
        String f = parts[1].padRight(decimals, '0').substring(0, decimals);
        fractionPart = BigInt.parse(f);
      }
      amount = wholePart * BigInt.from(10).pow(decimals) + fractionPart;
    }

    return SolanaPayUrl(
      recipient: recipient,
      amount: amount,
      splToken: splToken,
      label: uri.queryParameters['label'],
      message: uri.queryParameters['message'],
    );
  }
}
