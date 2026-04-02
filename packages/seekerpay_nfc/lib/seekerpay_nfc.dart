library seekerpay_nfc;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'src/nfc_handler.dart';

export 'src/nfc_handler.dart';

final nfcHandlerProvider = Provider<NfcHandler>((ref) {
  return NfcHandler();
});
