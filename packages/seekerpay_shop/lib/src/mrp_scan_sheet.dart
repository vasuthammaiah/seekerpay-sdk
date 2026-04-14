import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'currency_converter.dart';
import 'local_llm_service.dart';
import 'mrp_data.dart';
import 'mrp_parser.dart';
import 'product_model.dart';

const _kPrimary = Color(0xFFFFEB3B);

enum _Status { camera, processing, llm, result, error }

class MrpScanSheet extends ConsumerStatefulWidget {
  final void Function(Product product, double usdPrice) onConfirm;
  const MrpScanSheet({super.key, required this.onConfirm});
  static Future<void> show(BuildContext context, {required void Function(Product product, double usdPrice) onConfirm}) {
    return showGeneralDialog(context: context, barrierDismissible: false, pageBuilder: (_, __, ___) => MrpScanSheet(onConfirm: onConfirm));
  }
  @override ConsumerState<MrpScanSheet> createState() => _MrpScanSheetState();
}

class _MrpScanSheetState extends ConsumerState<MrpScanSheet> {
  CameraController? _controller; bool _cameraReady = false;
  _Status _status = _Status.camera; MrpData? _mrpData; double? _rateToUsd;
  final _nameCtrl = TextEditingController(); final _barcodeCtrl = TextEditingController(); final _localPriceCtrl = TextEditingController(); double? _confirmedUsd;
  String? _capturedPath; String? _targetField;

  @override void initState() { super.initState(); _initCamera(); }
  @override void dispose() { _controller?.dispose(); _nameCtrl.dispose(); _barcodeCtrl.dispose(); _localPriceCtrl.dispose(); super.dispose(); }

  Future<void> _initCamera() async {
    await Permission.camera.request();
    final cameras = await availableCameras(); if (cameras.isEmpty) return;
    final ctrl = CameraController(cameras.first, ResolutionPreset.high, enableAudio: false);
    await ctrl.initialize();
    if (mounted) setState(() { _controller = ctrl; _cameraReady = true; });
  }

  Future<void> _capture() async {
    if (_controller == null) return;
    setState(() => _status = _Status.processing);
    try {
      final photo = await _controller!.takePicture();
      final path = photo.path;

      final bytes = await File(path).readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image != null && image.width > image.height) image = img.copyRotate(image, angle: 90);
      
      final w = image!.width; final h = image.height;
      final cropW = (w * 0.8).toInt(); final cropH = (h * 0.2).toInt();
      final cropped = img.copyCrop(image, x: (w - cropW) ~/ 2, y: (h - cropH) ~/ 2, width: cropW, height: cropH);
      
      final grayscale = img.grayscale(img.Image.from(cropped));
      final threshold = img.luminanceThreshold(img.Image.from(grayscale), threshold: 0.5);
      final inverted = img.invert(img.Image.from(grayscale));

      final p1 = path.replaceFirst('.jpg', '_orig.jpg');
      final p2 = path.replaceFirst('.jpg', '_gray.jpg');
      final p3 = path.replaceFirst('.jpg', '_thresh.jpg');
      final p4 = path.replaceFirst('.jpg', '_inv.jpg');

      await File(p1).writeAsBytes(img.encodeJpg(cropped));
      await File(p2).writeAsBytes(img.encodeJpg(grayscale));
      await File(p3).writeAsBytes(img.encodeJpg(threshold));
      await File(p4).writeAsBytes(img.encodeJpg(inverted));
      _capturedPath = p1;

      final results = await Future.wait([_runOcr(p1), _runOcr(p2), _runOcr(p3), _runOcr(p4)]);
      final combined = "[Pass 1: Original]\n${results[0]}\n\n[Pass 2: Gray]\n${results[1]}\n\n[Pass 3: Thresh]\n${results[2]}\n\n[Pass 4: Inverted]\n${results[3]}";
      print(' [Scanner] >>> Multi-Pass OCR Result:\n$combined');

      String? barcode;
      if (_targetField == null || _targetField == 'barcode') {
        final bScanner = BarcodeScanner();
        final codes = await bScanner.processImage(InputImage.fromFilePath(path));
        if (codes.isNotEmpty) barcode = codes.first.rawValue;
        bScanner.close();
      }

      setState(() => _status = _Status.llm);
      final (aiData, _) = await LocalLlmService.extractFromTextWithOutput(combined);
      var finalData = aiData ?? MrpParser.parse(results[0]);
      if (barcode != null) finalData = finalData.copyWith(barcode: barcode);

      if (mounted) {
        if (_targetField != null) {
          if (_targetField == 'name' && finalData.productName != null) _nameCtrl.text = finalData.productName!;
          if (_targetField == 'barcode' && finalData.barcode != null) _barcodeCtrl.text = finalData.barcode!;
          if (_targetField == 'price' && finalData.hasPrice) { _localPriceCtrl.text = finalData.mrpAmount!.toStringAsFixed(2); _onLocalPriceChanged(_localPriceCtrl.text); }
          setState(() { _status = _Status.result; _targetField = null; });
        } else {
          _populateFields(finalData);
        }
      }
    } catch (e) {
      print(' [Scanner] Error: $e');
      if (mounted) setState(() => _status = _Status.error);
    }
  }

  Future<String> _runOcr(String p) async {
    final recognizer = TextRecognizer();
    final res = await recognizer.processImage(InputImage.fromFilePath(p));
    recognizer.close();
    return res.text;
  }

  void _populateFields(MrpData data) {
    if (data.productName != null) _nameCtrl.text = data.productName!;
    if (data.barcode != null) _barcodeCtrl.text = data.barcode!;
    setState(() { _mrpData = data; _status = _Status.result; });
    _fetchRate(data.currencyCode ?? 'USD');
  }

  Future<void> _fetchRate(String code) async {
    try {
      final rate = await CurrencyConverter.rateToUsd(code);
      if (mounted) {
        setState(() { _rateToUsd = rate; });
        if (_mrpData?.mrpAmount != null) {
          _localPriceCtrl.text = _mrpData!.mrpAmount!.toStringAsFixed(2);
          _onLocalPriceChanged(_localPriceCtrl.text);
        }
      }
    } catch (_) {}
  }

  void _onLocalPriceChanged(String v) {
    final val = double.tryParse(v);
    if (val == null || _rateToUsd == null || _rateToUsd! <= 0) { setState(() => _confirmedUsd = null); return; }
    setState(() => _confirmedUsd = val / _rateToUsd!);
  }

  void _selectCandidate(double price) {
    _localPriceCtrl.text = price.toStringAsFixed(2);
    _onLocalPriceChanged(_localPriceCtrl.text);
  }

  void _confirm() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _confirmedUsd == null) return;
    final product = Product(barcode: _barcodeCtrl.text.trim(), name: name, lastPriceUsd: _confirmedUsd, brand: 'Scanned Label');
    widget.onConfirm(product, _confirmedUsd!);
    Navigator.of(context).pop();
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _status == _Status.result ? _resultView() : _cameraView(),
      ),
    );
  }

  Widget _cameraView() {
    String label = _targetField == null ? 'ALIGN LABEL IN FRAME' : 'SCAN ${_targetField!.toUpperCase()}';
    return Stack(children: [
      if (_cameraReady) Positioned.fill(child: CameraPreview(_controller!)),
      if (_status == _Status.processing || _status == _Status.llm) Positioned.fill(child: Container(color: Colors.black87, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [ const CircularProgressIndicator(color: _kPrimary), const SizedBox(height: 20), Text(_status == _Status.llm ? 'AI ANALYZING...' : 'READING LABEL...', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)) ])))),
      Center(child: Container(width: 300, height: 200, decoration: BoxDecoration(border: Border.all(color: _targetField != null ? Colors.blue : _kPrimary, width: 2), borderRadius: BorderRadius.circular(12)))),
      Positioned(top: 100, left: 0, right: 0, child: Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)), child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1))))),
      Positioned(top: 16, left: 16, child: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.of(context).pop())),
      Align(alignment: Alignment.bottomCenter, child: Padding(padding: const EdgeInsets.all(40), child: GestureDetector(onTap: _capture, child: Container(width: 80, height: 80, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)), child: Center(child: Container(width: 64, height: 64, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white)))))))
    ]);
  }

  Widget _resultView() {
    final mrp = _mrpData;
    final symbol = mrp?.currencySymbol ?? '\$';
    final code = mrp?.currencyCode ?? 'USD';

    return Column(children: [
      if (_capturedPath != null)
        Stack(children: [
          SizedBox(height: 160, width: double.infinity, child: Image.file(File(_capturedPath!), fit: BoxFit.cover)),
          Positioned.fill(child: Container(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black])))),
          Positioned(top: 12, left: 16, child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => setState(() => _status = _Status.camera))),
          Positioned(bottom: 12, left: 20, child: const Text('SCAN RESULT', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 2))),
        ]),
      
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (mrp != null && mrp.hasPrice) ...[
          const Text('DETECTED ON LABEL', style: TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.blue.withValues(alpha: 0.2))),
            child: Row(children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$symbol${mrp.mrpAmount!.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
                Text(mrp.currencyCode!, style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w900)),
              ]),
              const Spacer(),
              if (_rateToUsd != null) Text('\$${(mrp.mrpAmount! / _rateToUsd!).toStringAsFixed(2)} USD', style: const TextStyle(color: _kPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
              IconButton(onPressed: () { _localPriceCtrl.text = mrp.mrpAmount!.toStringAsFixed(2); _onLocalPriceChanged(_localPriceCtrl.text); }, icon: const Icon(Icons.sync_rounded, color: _kPrimary))
            ]),
          ),
          const SizedBox(height: 24),
        ],

        _fieldWithRescan('PRODUCT NAME', _nameCtrl, 'name'),
        const SizedBox(height: 16),
        _fieldWithRescan('BARCODE', _barcodeCtrl, 'barcode'),
        const SizedBox(height: 24),

        if (mrp != null && mrp.candidatePrices.isNotEmpty) ...[
          const Text('SUGGESTED PRICES', style: TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: mrp.candidatePrices.toSet().map((p) => ActionChip(
            label: Text('$symbol${p.toStringAsFixed(2)}'),
            backgroundColor: _localPriceCtrl.text == p.toStringAsFixed(2) ? _kPrimary : Colors.white10,
            onPressed: () => _selectCandidate(p),
          )).toList()),
          const SizedBox(height: 24),
        ],

        Text('SET PRICE ($code)', style: const TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
        TextField(
          controller: _localPriceCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: _kPrimary, fontSize: 32, fontWeight: FontWeight.bold),
          onChanged: _onLocalPriceChanged,
          decoration: InputDecoration(prefixText: '$symbol ', enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white10))),
        ),
        if (_confirmedUsd != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('≈ \$${_confirmedUsd!.toStringAsFixed(2)} USD', style: const TextStyle(color: Colors.white38))),
        
        const SizedBox(height: 40),
        ElevatedButton(
          onPressed: _confirm,
          style: ElevatedButton.styleFrom(backgroundColor: _kPrimary, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 16)),
          child: const Text('ADD TO CART', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        TextButton(onPressed: () => setState(() => _status = _Status.camera), child: const Text('RESCAN ALL', style: TextStyle(color: Colors.white54)))
      ])))
    ]);
  }

  Widget _fieldWithRescan(String label, TextEditingController ctrl, String fieldKey) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold)),
        const Spacer(),
        GestureDetector(onTap: () => setState(() { _targetField = fieldKey; _status = _Status.camera; }), child: Icon(Icons.document_scanner_rounded, color: _kPrimary, size: 14)),
      ]),
      TextField(controller: ctrl, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700), decoration: const InputDecoration(enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white10)))),
    ]);
  }
}
