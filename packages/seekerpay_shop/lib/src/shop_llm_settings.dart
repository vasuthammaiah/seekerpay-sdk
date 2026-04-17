import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'local_llm_service.dart';
import 'mrp_ai_reader.dart';

class ShopLlmSettings extends StatefulWidget {
  final bool showHeader;
  const ShopLlmSettings({super.key, this.showHeader = true});
  @override State<ShopLlmSettings> createState() => _ShopLlmSettingsState();
}

enum _Step { download, validate, initialize, ready }
enum _StepStatus { idle, running, ok, failed }

class _ShopLlmSettingsState extends State<ShopLlmSettings> {
  static const _kPrimary = Color(0xFFFFEB3B), _kSurface = Colors.transparent, _kRed = Color(0xFFFF5252), _kGreen = Color(0xFF00E676);
  bool _enabled = false;
  final _status = <_Step, _StepStatus>{ _Step.download: _StepStatus.idle, _Step.validate: _StepStatus.idle, _Step.initialize: _StepStatus.idle, _Step.ready: _StepStatus.idle };
  final _detail = <_Step, String>{};
  double _progress = 0;
  StreamSubscription<double>? _downloadSub;
  final _playgroundCtrl = TextEditingController(); bool _playgroundLoading = false; String? _playgroundResponse; bool _showRules = false;

  bool get _allOk => _status[_Step.download] == _StepStatus.ok && _status[_Step.validate] == _StepStatus.ok && _status[_Step.initialize] == _StepStatus.ok;

  @override void initState() { super.initState(); _resumeFromCurrentState(); }
  @override void dispose() { _downloadSub?.cancel(); _playgroundCtrl.dispose(); super.dispose(); }

  Future<void> _resumeFromCurrentState() async {
    final enabled = await LocalLlmService.isEnabled();
    if (mounted) setState(() => _enabled = enabled);

    // Re-attach to an in-progress background download.
    if (LocalLlmService.isDownloading) {
      if (mounted) setState(() => _progress = LocalLlmService.downloadProgress);
      _mark(_Step.download, _StepStatus.running, 'Downloading…');
      _mark(_Step.validate, _StepStatus.idle);
      _mark(_Step.initialize, _StepStatus.idle);
      _attachDownloadStream();
      return;
    }

    final fileStatus = await LocalLlmService.validateModelFile();
    if (!fileStatus.isValid) return;
    _mark(_Step.download, _StepStatus.ok, 'Downloaded · ${fileStatus.sizeLabel}');
    _mark(_Step.validate, _StepStatus.ok, '${fileStatus.sizeLabel} · ${fileStatus.path.split('/').last}');
    if (LocalLlmService.isModelLoaded) { _mark(_Step.initialize, _StepStatus.ok, 'Engine running on ${LocalLlmService.lastBackend}'); }
    else if (enabled) await _runInitialize();
  }

  /// Subscribes to the in-progress download stream.
  /// Automatically runs validate → init when the download completes.
  void _attachDownloadStream() {
    _downloadSub?.cancel();
    final stream = LocalLlmService.downloadProgressStream;
    if (stream == null) {
      // Download already finished (very fast or re-attach too late).
      _onDownloadComplete();
      return;
    }
    _downloadSub = stream.listen(
      (p) { if (mounted) setState(() => _progress = p); },
      onDone: _onDownloadComplete,
      onError: (Object e) { _mark(_Step.download, _StepStatus.failed, e.toString()); },
      cancelOnError: true,
    );
  }

  Future<void> _onDownloadComplete() async {
    final fs = await LocalLlmService.validateModelFile();
    if (!fs.isValid) {
      _mark(_Step.download, _StepStatus.failed, 'File invalid (${fs.sizeLabel})');
      return;
    }
    _mark(_Step.download, _StepStatus.ok, 'Downloaded · ${fs.sizeLabel}');
    await _runValidate(fs);
  }

  void _mark(_Step step, _StepStatus s, [String? d]) { if (!mounted) return; setState(() { _status[step] = s; if (d != null) _detail[step] = d; }); }

  void _startDownload() {
    if (LocalLlmService.isDownloading) {
      // Already running (e.g. user tapped twice) — just re-attach.
      if (mounted) setState(() => _progress = LocalLlmService.downloadProgress);
      _mark(_Step.download, _StepStatus.running, 'Downloading…');
      _attachDownloadStream();
      return;
    }
    _mark(_Step.download, _StepStatus.running, 'Downloading…');
    _mark(_Step.validate, _StepStatus.idle);
    _mark(_Step.initialize, _StepStatus.idle);
    if (mounted) setState(() => _progress = 0);

    // Fire-and-forget: download runs in background independent of widget lifecycle.
    LocalLlmService.downloadModel().catchError((_) {
      // Error is also pushed to the stream and handled in _attachDownloadStream.
    });
    _attachDownloadStream();
  }

  Future<void> _runValidate(ModelFileStatus fs) async {
    _mark(_Step.validate, _StepStatus.running, 'Checking file…');
    if (!fs.exists) { _mark(_Step.validate, _StepStatus.failed, 'File not found'); return; }
    if (!fs.isValid) {
      final msg = fs.expectedBytes > 0 ? 'Size mismatch: ${fs.sizeLabel}' : 'File too small (${fs.sizeLabel})';
      _mark(_Step.validate, _StepStatus.failed, msg);
      return;
    }
    _mark(_Step.validate, _StepStatus.ok, '${fs.sizeLabel} · ${fs.path.split('/').last}');
    await _runInitialize();
  }

  Future<void> _runInitialize() async {
    _mark(_Step.initialize, _StepStatus.running, 'Starting AI engine…');
    final (ok, msg) = await LocalLlmService.warmUp();
    if (ok) _mark(_Step.initialize, _StepStatus.ok, msg); else _mark(_Step.initialize, _StepStatus.failed, msg);
  }

  Future<void> _sendPlaygroundPrompt() async {
    final p = _playgroundCtrl.text.trim(); if (p.isEmpty) return;
    setState(() { _playgroundLoading = true; _playgroundResponse = null; });
    final (data, raw) = await LocalLlmService.extractFromTextWithOutput(p);
    if (mounted) setState(() { _playgroundLoading = false; _playgroundResponse = raw; });
  }

  Future<void> _toggleEnabled(bool v) async {
    await LocalLlmService.setEnabled(v); if (mounted) setState(() => _enabled = v);
    if (v && !LocalLlmService.isModelLoaded && (await LocalLlmService.validateModelFile()).isValid) await _runInitialize();
  }

  Future<void> _deleteModel() async {
    final conf = await showDialog<bool>(context: context, builder: (_) => AlertDialog(backgroundColor: _kSurface, title: const Text('Delete model?', style: TextStyle(color: Colors.white)), content: const Text('Removes ~500 MB model from storage.', style: TextStyle(color: Colors.white70)), actions: [ TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')), TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('DELETE', style: TextStyle(color: _kRed))) ]));
    if (conf == true) { await LocalLlmService.deleteModel(); if (mounted) setState(() { _enabled = false; _progress = 0; for (final k in _Step.values) { _status[k] = _StepStatus.idle; _detail.remove(k); } }); }
  }

  @override Widget build(BuildContext context) {
    return Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: _kSurface, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.showHeader) ...[ _buildHeader(), const Divider(height: 1, color: Colors.white10) ],
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Scanned label text is processed by a local AI model fully on-device.', style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5)),
          const SizedBox(height: 16),
          _buildStepRow(step: _Step.download, label: 'Download model (~500 MB)', extra: _status[_Step.download] == _StepStatus.running ? _buildProgressBar() : null),
          if (_status[_Step.download] == _StepStatus.idle || _status[_Step.download] == _StepStatus.failed) ...[ const SizedBox(height: 10), _ActionButton(label: _status[_Step.download] == _StepStatus.failed ? 'RETRY DOWNLOAD' : 'DOWNLOAD MODEL', icon: Icons.download_rounded, color: _kPrimary, onTap: _startDownload) ],
          const SizedBox(height: 10),
          _buildStepRow(step: _Step.validate, label: 'Verify file integrity'),
          const SizedBox(height: 10),
          _buildStepRow(step: _Step.initialize, label: 'Start AI engine', extra: (_status[_Step.initialize] == _StepStatus.idle && _status[_Step.validate] == _StepStatus.ok) ? Padding(padding: const EdgeInsets.only(top: 6), child: _ActionButton(label: 'START ENGINE', icon: Icons.play_arrow_rounded, color: _kPrimary, onTap: _runInitialize)) : _status[_Step.initialize] == _StepStatus.failed ? Padding(padding: const EdgeInsets.only(top: 6), child: _ActionButton(label: 'RETRY ENGINE START', icon: Icons.refresh_rounded, color: Colors.white54, onTap: _runInitialize)) : null),
          
          if (_allOk) ...[
            const SizedBox(height: 14), const Divider(height: 1, color: Colors.white10), const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('AI PLAYGROUND', style: TextStyle(color: Colors.white.withValues(alpha:0.3), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 2)),
              GestureDetector(onTap: () => setState(() => _showRules = !_showRules), child: Text(_showRules ? 'HIDE RULES' : 'SHOW RULES', style: TextStyle(color: _kPrimary.withValues(alpha:0.5), fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: 1))),
            ]),
            if (_showRules) ...[
              const SizedBox(height: 8),
              Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.blue.withValues(alpha:0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.blue.withValues(alpha:0.2))),
                child: const Text(
                  '1. Analyze raw text & correct OCR errors.\n'
                  '2. Return structured JSON with productName, price, currency, expDate.\n'
                  '3. Clean/Shorten product names.\n'
                  '4. Detect price based on Merchant Country labels.\n'
                  '5. Return ONLY JSON, no explanations.',
                  style: TextStyle(color: Colors.blueGrey, fontSize: 10, height: 1.5),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(controller: _playgroundCtrl, style: const TextStyle(color: Colors.white, fontSize: 13), maxLines: 3, decoration: InputDecoration(hintText: 'Enter sample label text to test AI...', hintStyle: const TextStyle(color: Colors.white24, fontSize: 12), filled: true, fillColor: Colors.white.withValues(alpha:0.04), border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none))),
            const SizedBox(height: 10),
            _ActionButton(label: _playgroundLoading ? 'AI ANALYZING...' : 'SEND TO AI', icon: Icons.send_rounded, color: _kPrimary, onTap: _playgroundLoading ? () {} : _sendPlaygroundPrompt),
            if (_playgroundResponse != null) ...[ const SizedBox(height: 12), Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white.withOpacity(0.04), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white.withOpacity(0.08))), child: SelectableText(_playgroundResponse!, style: const TextStyle(color: _kGreen, fontSize: 11, fontFamily: 'monospace'))) ],
          ],
          if (_status[_Step.download] == _StepStatus.ok) ...[ const SizedBox(height: 12), GestureDetector(onTap: _deleteModel, child: Container(padding: const EdgeInsets.symmetric(vertical: 10), decoration: BoxDecoration(border: Border.all(color: _kRed.withValues(alpha:0.3)), borderRadius: BorderRadius.circular(8)), child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [ Icon(Icons.delete_outline_rounded, color: _kRed, size: 14), SizedBox(width: 6), Text('DELETE MODEL', style: TextStyle(color: _kRed, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1)) ]))) ]
        ])),
      ]));
  }

  Widget _buildHeader() { return Padding(padding: const EdgeInsets.fromLTRB(16, 14, 12, 14), child: Row(children: [ Container(width: 36, height: 36, decoration: BoxDecoration(color: _allOk && _enabled ? _kPrimary.withValues(alpha:0.15) : Colors.white.withValues(alpha:0.06), borderRadius: BorderRadius.circular(8)), child: Icon(Icons.psychology_rounded, color: _allOk && _enabled ? _kPrimary : Colors.white38, size: 20)), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ const Text('Free On-device LLM', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)), Text(_allOk ? 'Gemma 3 1B · Google · Ready' : 'Gemma 3 1B · Setup required', style: const TextStyle(color: Colors.white38, fontSize: 11)) ])), Switch(value: _enabled && _allOk, onChanged: _allOk ? _toggleEnabled : null, activeThumbColor: _kPrimary, activeTrackColor: _kPrimary.withValues(alpha:0.4), inactiveTrackColor: Colors.white12) ])); }
  Widget _buildStepRow({required _Step step, required String label, Widget? extra}) { final s = _status[step]!; final detail = _detail[step]; Color iconColor; IconData icon; switch (s) { case _StepStatus.idle: iconColor = Colors.white24; icon = Icons.radio_button_unchecked_rounded; case _StepStatus.running: iconColor = _kPrimary; icon = Icons.radio_button_unchecked_rounded; case _StepStatus.ok: iconColor = _kGreen; icon = Icons.check_circle_rounded; case _StepStatus.failed: iconColor = _kRed; icon = Icons.cancel_rounded; } return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Row(crossAxisAlignment: CrossAxisAlignment.center, children: [ s == _StepStatus.running ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: _kPrimary)) : Icon(icon, color: iconColor, size: 16), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Text(label, style: TextStyle(color: s == _StepStatus.idle ? Colors.white38 : Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)), if (detail != null) Text(detail, style: TextStyle(color: s == _StepStatus.failed ? _kRed.withValues(alpha:0.8) : Colors.white38, fontSize: 10, height: 1.4)) ])) ]), if (extra != null) ...[const SizedBox(height: 6), extra] ]); }
  Widget _buildProgressBar() { return Padding(padding: const EdgeInsets.only(left: 26, top: 6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: _progress, backgroundColor: Colors.white12, valueColor: const AlwaysStoppedAnimation(_kPrimary), minHeight: 5)), const SizedBox(height: 3), Text('${(_progress * 100).toStringAsFixed(1)}%  ·  ${(_progress * 500).toStringAsFixed(0)} / 500 MB', style: const TextStyle(color: Colors.white38, fontSize: 10)) ])); }
}

class _ActionButton extends StatelessWidget {
  final String label; final IconData icon; final Color color; final VoidCallback onTap;
  const _ActionButton({required this.label, required this.icon, required this.color, required this.onTap});
  @override Widget build(BuildContext context) { return GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(border: Border.all(color: color.withValues(alpha:0.5)), borderRadius: BorderRadius.circular(8)), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [ Icon(icon, color: color, size: 16), const SizedBox(width: 8), Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1)) ]))); }
}

class ClaudeVisionSettings extends StatefulWidget {
  final bool showHeader;
  const ClaudeVisionSettings({super.key, this.showHeader = true});
  @override State<ClaudeVisionSettings> createState() => _ClaudeVisionSettingsState();
}
class _ClaudeVisionSettingsState extends State<ClaudeVisionSettings> {
  static const _kPrimary = Color(0xFFFFEB3B), _kSurface = Color(0xFF1A1A1A);
  bool _enabled = true, _editing = false, _saving = false, _obscure = true;
  final _ctrl = TextEditingController();
  @override void initState() { super.initState(); _enabled = MrpAiReader.isEnabledSync; final key = MrpAiReader.activeKey ?? ''; _ctrl.text = key.isNotEmpty ? key : ''; }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  bool get _configured => MrpAiReader.isConfigured;
  Future<void> _save() async { setState(() => _saving = true); await MrpAiReader.saveKey(_ctrl.text.trim()); if (mounted) setState(() { _saving = false; _editing = false; _obscure = true; }); }
  Future<void> _toggleEnabled(bool v) async { await MrpAiReader.setEnabled(v); if (mounted) setState(() => _enabled = v); }
  Future<void> _clear() async { await MrpAiReader.saveKey(''); _ctrl.clear(); if (mounted) setState(() { _editing = false; _obscure = true; }); }
  @override Widget build(BuildContext context) {
    return Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: _kSurface, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.showHeader) ...[ Padding(padding: const EdgeInsets.fromLTRB(16, 14, 12, 14), child: Row(children: [ Container(width: 36, height: 36, decoration: BoxDecoration(color: _configured ? _kPrimary.withValues(alpha:0.15) : Colors.white.withValues(alpha:0.06), borderRadius: BorderRadius.circular(8)), child: Icon(Icons.auto_awesome_rounded, color: _configured ? _kPrimary : Colors.white38, size: 20)), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ const Text('Paid API (Anthropic)', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)), Text(_configured ? 'Active — Claude Vision reads labels' : 'Claude Vision · API key required', style: const TextStyle(color: Colors.white38, fontSize: 11)) ])), Switch(value: _enabled && _configured, onChanged: _configured ? _toggleEnabled : null, activeThumbColor: _kPrimary, activeTrackColor: _kPrimary.withValues(alpha:0.4), inactiveTrackColor: Colors.white12) ])), const Divider(height: 1, color: Colors.white10) ],
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('When set, Claude Vision reads label images directly — far more accurate than on-device OCR.', style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5)),
          const SizedBox(height: 10),
          InkWell(
            onTap: () => launchUrl(Uri.parse('https://console.anthropic.com/')),
            child: const Text(
              'Get Anthropic API key at console.anthropic.com',
              style: TextStyle(color: _kPrimary, fontSize: 11, fontWeight: FontWeight.bold, decoration: TextDecoration.underline),
            ),
          ),
          const SizedBox(height: 14),
          if (_editing) ...[
            TextField(controller: _ctrl, obscureText: _obscure, autofocus: true, style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'), decoration: InputDecoration(hintText: 'sk-ant-api03-...', hintStyle: const TextStyle(color: Colors.white24, fontSize: 12), filled: true, fillColor: Colors.white.withValues(alpha:0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white12)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white12)), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: _kPrimary.withValues(alpha:0.6))), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded, color: Colors.white38, size: 18), onPressed: () => setState(() => _obscure = !_obscure)))),
            const SizedBox(height: 10),
            Row(children: [ Expanded(child: OutlinedButton(onPressed: () => setState(() { _editing = false; _obscure = true; }), style: OutlinedButton.styleFrom(foregroundColor: Colors.white38, side: const BorderSide(color: Colors.white12), padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))), child: const Text('CANCEL', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900)))), const SizedBox(width: 10), Expanded(flex: 2, child: ElevatedButton(onPressed: _saving ? null : _save, style: ElevatedButton.styleFrom(backgroundColor: _kPrimary, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))), child: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black)) : const Text('SAVE KEY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900)))) ])
          ] else ...[
            _ActionButton(label: _configured ? 'CHANGE API KEY' : 'SET API KEY', icon: Icons.key_rounded, color: _configured ? Colors.white54 : _kPrimary, onTap: () => setState(() { _editing = true; _obscure = true; })),
            if (_configured) ...[ const SizedBox(height: 8), GestureDetector(onTap: _clear, child: Container(padding: const EdgeInsets.symmetric(vertical: 10), decoration: BoxDecoration(border: Border.all(color: Colors.red.withValues(alpha:0.3)), borderRadius: BorderRadius.circular(8)), child: const Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [ Icon(Icons.delete_outline_rounded, color: Colors.red, size: 14), SizedBox(width: 6), Text('REMOVE KEY', style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1)) ]))) ]
          ]
        ])),
      ]));
  }
}
