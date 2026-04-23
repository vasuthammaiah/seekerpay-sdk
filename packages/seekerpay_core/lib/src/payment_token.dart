enum PaymentToken { skr, sol }

extension PaymentTokenExtension on PaymentToken {
  String get symbol => this == PaymentToken.skr ? 'SKR' : 'SOL';
  int get decimals => this == PaymentToken.skr ? 6 : 9;
}
