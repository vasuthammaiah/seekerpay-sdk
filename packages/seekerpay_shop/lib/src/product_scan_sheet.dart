import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'product_model.dart';
import 'product_lookup_service.dart';
import 'history_service.dart';
import 'currency_converter.dart';


const _kPrimary = Color(0xFFFFEB3B);

class ProductScanSheet extends ConsumerStatefulWidget {
  final void Function(Product product, double usdPrice) onConfirm;
  const ProductScanSheet({super.key, required this.onConfirm});

  static Future<void> show(BuildContext context, {required void Function(Product product, double usdPrice) onConfirm}) {
    return showGeneralDialog(context: context, barrierDismissible: false, pageBuilder: (_, __, ___) => ProductScanSheet(onConfirm: onConfirm));
  }

  @override ConsumerState<ProductScanSheet> createState() => _ProductScanSheetState();
}

class _ProductScanSheetState extends ConsumerState<ProductScanSheet> {
  CameraController? _controller;
  bool _cameraReady = false;
  bool _processing = false;
  Product? _foundProduct;
  double? _confirmedUsd;
  double? _rateToUsd;
  String _currencyCode = 'USD';
  String _currencySymbol = '\$';
  
  final _localPriceCtrl = TextEditingController();

  @override void initState() { super.initState(); _initCamera(); _loadCountryConfig(); }
  @override void dispose() { _controller?.dispose(); _localPriceCtrl.dispose(); super.dispose(); }

  Future<void> _loadCountryConfig() async {
    final p = await SharedPreferences.getInstance();
    final country = p.getString('spay_merchant_country') ?? 'India';
    if (country == 'India') { _currencyCode = 'INR'; _currencySymbol = '₹'; }
    else if (country == 'China') { _currencyCode = 'CNY'; _currencySymbol = '¥'; }
    else if (country == 'United Kingdom') { _currencyCode = 'GBP'; _currencySymbol = '£'; }
    else if (country == 'European Union') { _currencyCode = 'EUR'; _currencySymbol = '€'; }
    else if (country == 'Japan') { _currencyCode = 'JPY'; _currencySymbol = '¥'; }
    else { _currencyCode = 'USD'; _currencySymbol = '\$'; }
    _fetchRate();
  }

  Future<void> _fetchRate() async {
    if (_currencyCode == 'USD') { _rateToUsd = 1.0; return; }
    try {
      final rate = await CurrencyConverter.rateToUsd(_currencyCode);
      if (mounted) setState(() => _rateToUsd = rate);
    } catch (_) {}
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final ctrl = CameraController(cameras.first, ResolutionPreset.high, enableAudio: false);
    await ctrl.initialize();
    if (mounted) setState(() { _controller = ctrl; _cameraReady = true; });
  }

  Future<void> _capture() async {
    if (_controller == null || _processing) return;
    setState(() => _processing = true);
    try {
      final photo = await _controller!.takePicture();
      final path = photo.path;
      print(' [Scanner] >>> PHOTO CAPTURED for BARCODE: $path');

      String? barcode;
      final scanner = BarcodeScanner();
      try {
        final codes = await scanner.processImage(InputImage.fromFilePath(path));
        if (codes.isNotEmpty) barcode = codes.first.rawValue;
      } finally { scanner.close(); }

      if (barcode == null) {
        if (mounted) {
          setState(() => _processing = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No barcode detected.')));
        }
        return;
      }

      final local = ref.read(historyProvider).scannedProducts;
      final match = local.cast<Product?>().firstWhere((p) => p?.barcode == barcode, orElse: () => null);
      if (match != null) {
        _foundProduct = match;
        _confirmedUsd = match.lastPriceUsd;
        if (_confirmedUsd != null && _rateToUsd != null) {
          _localPriceCtrl.text = (_confirmedUsd! * _rateToUsd!).toStringAsFixed(2);
        }
        setState(() => _processing = false);
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString('spay_barcode_lookup_key');
      final enabled = prefs.getBool('spay_barcode_lookup_enabled') ?? false;
      
      final apiP = await ProductLookupService(barcodeLookupApiKey: key, enabled: enabled).lookup(barcode);

      if (apiP != null) {
        _foundProduct = apiP;
        _confirmedUsd = apiP.lastPriceUsd;
        if (_confirmedUsd != null && _rateToUsd != null) {
          _localPriceCtrl.text = (_confirmedUsd! * _rateToUsd!).toStringAsFixed(2);
        }
        setState(() => _processing = false);
      } else {
        if (mounted) {
          setState(() => _processing = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Product details not found.')));
        }
      }
    } catch (e) { if (mounted) setState(() => _processing = false); }
  }

  void _onLocalPriceChanged(String v) {
    final val = double.tryParse(v);
    if (val == null || _rateToUsd == null || _rateToUsd! <= 0) { setState(() => _confirmedUsd = null); return; }
    setState(() => _confirmedUsd = val / _rateToUsd!);
  }

  void _onConfirm() {
    if (_foundProduct == null || _confirmedUsd == null) return;
    widget.onConfirm(_foundProduct!, _confirmedUsd!);
    Navigator.of(context).pop();
  }

  @override Widget build(BuildContext context) {
    if (_foundProduct != null) return _resultView();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, leading: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.of(context).pop())),
      body: Stack(children: [
        if (_cameraReady) Positioned.fill(child: CameraPreview(_controller!)),
        if (_processing) Positioned.fill(child: Container(color: Colors.black54, child: const Center(child: CircularProgressIndicator(color: _kPrimary)))),
        Align(alignment: Alignment.bottomCenter, child: Padding(padding: const EdgeInsets.all(40), child: GestureDetector(onTap: _capture, child: Container(width: 80, height: 80, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)), child: Center(child: Container(width: 64, height: 64, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white)))))))
      ]),
    );
  }

  Widget _resultView() {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('PRODUCT FOUND'), 
        backgroundColor: Colors.black,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _foundProduct = null)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_foundProduct!.imageUrl != null)
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 24),
                height: 160, width: 160,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(_foundProduct!.imageUrl!, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.inventory_2_rounded, size: 48, color: Colors.black12)),
                ),
              ),
            ),
          Text(_foundProduct!.name, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(_foundProduct!.barcode, style: const TextStyle(color: Colors.white38, fontFamily: 'monospace'), textAlign: TextAlign.center),
          const SizedBox(height: 32),
          Text('SET PRICE ($_currencyCode)', style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
          TextField(
            controller: _localPriceCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: _kPrimary, fontSize: 32, fontWeight: FontWeight.bold),
            onChanged: _onLocalPriceChanged,
            autofocus: true,
            decoration: InputDecoration(prefixText: '$_currencySymbol ', enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white10))),
          ),
          if (_confirmedUsd != null && _currencyCode != 'USD') Padding(padding: const EdgeInsets.only(top: 8), child: Text('≈ \$${_confirmedUsd!.toStringAsFixed(2)} USD', style: const TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.bold))),
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: _confirmedUsd != null ? _onConfirm : null,
            style: ElevatedButton.styleFrom(backgroundColor: _kPrimary, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 16)),
            child: const Text('ADD TO CART', style: TextStyle(fontWeight: FontWeight.bold)),
          )
        ]),
      ),
    );
  }
}
