import 'package:flutter/services.dart';

/// Bridge to the native NFC implementation via the `seekerpay/nfc` [MethodChannel].
///
/// Supports reading NDEF tags that contain a Solana Pay URL, writing a Solana
/// Pay URL to an NDEF-capable tag, and querying NFC hardware availability.
class NfcHandler {
  static const _ch = MethodChannel('seekerpay/nfc');
  bool _handlerSet = false;
  void Function(String url)? _onTagRead;
  void Function()? _onTagWritten;
  void Function(String error)? _onTagWriteError;
  void Function()? _onHceTap;

  void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onTagRead':
          final handler = _onTagRead;
          if (handler != null) handler(call.arguments as String);
          break;
        case 'onTagWritten':
          final handler = _onTagWritten;
          if (handler != null) handler();
          break;
        case 'onTagWriteError':
          final handler = _onTagWriteError;
          if (handler != null) handler(call.arguments as String);
          break;
        case 'onHceTap':
          _onHceTap?.call();
          break;
      }
    });
  }

  /// Returns `true` if the device has NFC hardware and it is enabled.
  Future<bool> isAvailable() async {
    try { return await _ch.invokeMethod<bool>('isAvailable') ?? false; }
    on PlatformException { return false; }
  }
  /// Writes [solanaPayUrl] to an NFC tag using the native `writeTag` method.
  /// When [onHceTap] is provided it is called each time a remote device
  /// completes an HCE exchange (i.e. a sender tapped and retrieved the URL).
  Future<void> writePaymentTag(String solanaPayUrl, {void Function()? onHceTap}) async {
    _ensureHandler();
    _onHceTap = onHceTap;
    return _ch.invokeMethod('writeTag', {'url': solanaPayUrl});
  }
  /// Writes [solanaPayUrl] as an NDEF record, with optional callbacks for
  /// success ([onTagWritten]) and failure ([onTagWriteError]).
  Future<void> writeNdefTag({
    required String solanaPayUrl,
    void Function()? onTagWritten,
    void Function(String error)? onTagWriteError,
  }) async {
    _ensureHandler();
    _onTagWritten = onTagWritten;
    _onTagWriteError = onTagWriteError;
    await _ch.invokeMethod('writeNdefTag', {'url': solanaPayUrl});
  }
  /// Begins listening for NDEF tags. When a tag carrying a Solana Pay URL
  /// is scanned, [onTagRead] is invoked with the URL string.
  Future<void> startReading({required void Function(String url) onTagRead}) async {
    _ensureHandler();
    _onTagRead = onTagRead;
    return _ch.invokeMethod('startRead');
  }
  /// Stops the active NFC tag reading session.
  Future<void> stopReading() => _ch.invokeMethod('stopRead');

  /// Opens the device NFC settings page.
  Future<void> openSettings() => _ch.invokeMethod('openSettings');
}
