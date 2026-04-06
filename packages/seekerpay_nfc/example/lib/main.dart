/// seekerpay_nfc — example app.
///
/// Demonstrates checking NFC availability, reading NFC tags (continuous),
/// and writing a Solana Pay URL to an NFC tag.
///
/// Requires a physical Android/iOS device with NFC hardware.
library;

import 'package:flutter/material.dart';
import 'package:seekerpay_nfc/seekerpay_nfc.dart';

void main() {
  runApp(const MaterialApp(
    title: 'seekerpay_nfc example',
    home: _HomeScreen(),
  ));
}

class _HomeScreen extends StatefulWidget {
  const _HomeScreen();
  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  final _nfc = NfcHandler();

  bool? _isAvailable;
  bool _scanning = false;
  String? _scannedUrl;
  String? _status;

  @override
  void initState() {
    super.initState();
    _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    final available = await _nfc.isAvailable();
    if (mounted) setState(() => _isAvailable = available);
  }

  Future<void> _startRead() async {
    setState(() {
      _scanning = true;
      _scannedUrl = null;
      _status = 'Hold phone near NFC tag or device…';
    });
    try {
      final url = await _nfc.readTag();
      if (!mounted) return;
      setState(() {
        _scannedUrl = url;
        _scanning = false;
        _status = 'Tag read successfully';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _status = 'Read error: $e';
      });
    }
  }

  Future<void> _stopRead() async {
    await _nfc.stopReading();
    if (mounted) setState(() { _scanning = false; _status = 'Scan stopped'; });
  }

  Future<void> _writeTag() async {
    // A Solana Pay URL pointing to MY_WALLET_ADDRESS requesting 1.00 SKR.
    // Replace MY_WALLET_ADDRESS with a real base58 address for live testing.
    const url =
        'solana:MY_WALLET_ADDRESS?amount=1.0'
        '&spl-token=SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3'
        '&label=Tap+to+pay+1+SKR';

    setState(() => _status = 'Hold phone near writable NFC tag…');
    await _nfc.writeNdefTag(
      solanaPayUrl: url,
      onTagWritten: () {
        if (mounted) setState(() => _status = 'Tag written successfully');
      },
      onTagWriteError: (e) {
        if (mounted) setState(() => _status = 'Write error: $e');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('seekerpay_nfc')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(
                _isAvailable == true ? Icons.nfc_rounded : Icons.nfc_outlined,
                color: _isAvailable == true ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              Text(_isAvailable == null
                  ? 'Checking NFC…'
                  : _isAvailable!
                      ? 'NFC available'
                      : 'NFC not available on this device'),
            ]),
            if (_isAvailable == false)
              TextButton(onPressed: _nfc.openSettings, child: const Text('Open NFC Settings')),

            const SizedBox(height: 24),
            const Text('READ', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1, fontSize: 11, color: Colors.white54)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: (_isAvailable != true || _scanning) ? null : _startRead,
                  child: const Text('Start Reading'),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _scanning ? _stopRead : null, child: const Text('Stop')),
            ]),

            const SizedBox(height: 24),
            const Text('WRITE', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1, fontSize: 11, color: Colors.white54)),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _isAvailable != true ? null : _writeTag,
              child: const Text('Write Payment Tag (1.00 SKR)'),
            ),

            const SizedBox(height: 32),
            if (_status != null)
              Text(_status!, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            if (_scannedUrl != null) ...[
              const SizedBox(height: 12),
              const Text('Scanned URL:', style: TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 4),
              SelectableText(_scannedUrl!, style: const TextStyle(fontFamily: 'Courier', fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }
}
