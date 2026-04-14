import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'mrp_data.dart';

class LocalLlmService {
  LocalLlmService._();
  static const _enabledKey    = 'spay_shop_llm_enabled';
  static const _modelFileName = 'gemma3-1b-it.task';
  static const _minModelBytes = 100 * 1024 * 1024;
  static String _country = 'India';

  static InferenceModel? _model;
  static bool _initialized = false;
  static String _lastBackend = 'device';
  static String get lastBackend => _lastBackend;

  // ── Background download state ──────────────────────────────────────────────
  static const _taskId = 'skr_shop_llm_model';
  static const _downloadUrl = 'https://drive.usercontent.google.com/download?id=1naDsVGLI0OM9McAh6hrHhnpP_4rtnhsD&export=download&confirm=t';

  static bool _isDownloading = false;
  static double _downloadProgress = 0.0;
  static int _expectedBytes = 0;
  static StreamController<double>? _progressSc;

  /// True while a download is in progress (survives widget navigation).
  static bool get isDownloading => _isDownloading;

  /// Current download progress 0.0–1.0.
  static double get downloadProgress => _downloadProgress;

  /// Expected file size in bytes.
  static int get expectedBytes => _expectedBytes;

  /// Broadcast stream of progress values (0.0–1.0).
  /// Null when no download is running.
  /// Closes when download completes or fails.
  static Stream<double>? get downloadProgressStream => _progressSc?.stream;
  // ──────────────────────────────────────────────────────────────────────────

  static void configure({String? country}) {
    if (country != null) _country = country;
  }

  static Future<void> init() async {
    try {
      await FlutterGemma.initialize().timeout(const Duration(seconds: 8));
      _initialized = true;
    } catch (_) {}
  }

  static Future<bool> isEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_enabledKey) ?? true;
  }

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_enabledKey, v);
  }

  static Future<File?> _findOrAdoptModelFile() async {
    final dir = await getApplicationSupportDirectory();
    final dest = File('${dir.path}/$_modelFileName');
    if (await dest.exists() && (await dest.length()) > _minModelBytes) return dest;
    return null;
  }

  static Future<bool> isModelDownloaded() async => await _findOrAdoptModelFile() != null;

  static Future<ModelFileStatus> validateModelFile() async {
    final dir = await getApplicationSupportDirectory();
    final dest = File('${dir.path}/$_modelFileName');
    if (!await dest.exists()) {
      return ModelFileStatus(exists: false, sizeBytes: 0, expectedBytes: _expectedBytes, path: dest.path);
    }
    final size = await dest.length();
    return ModelFileStatus(exists: true, sizeBytes: size, expectedBytes: _expectedBytes, path: dest.path);
  }

  static bool get isModelLoaded => _model != null;

  static Future<(bool, String)> warmUp() async {
    try { await _ensureModelLoaded(); return (true, 'Engine ready on $_lastBackend'); }
    catch (e) { return (false, e.toString()); }
  }

  static Future<void> autoStartIfEnabled() async {
    if (!await isEnabled()) return;
    if (await isModelDownloaded()) await _ensureModelLoaded().catchError((_) {});
  }

  static Future<void> deleteModel() async {
    _model = null;
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$_modelFileName');
    if (await file.exists()) await file.delete();
    _expectedBytes = 0;
  }

  /// Initializes the native background downloader. Call once at app start
  /// (e.g. in main.dart or alongside [init]).
  static Future<void> initDownloader() async {
    await FileDownloader().configure(
      globalConfig: [
        (Config.requestTimeout, const Duration(seconds: 60)),
      ],
      androidConfig: [
        (Config.useCacheDir, false),
      ],
    );
    // Re-attach to a download that was running before the app was killed.
    final tasks = await FileDownloader().allTaskIds();
    if (tasks.contains(_taskId)) {
      _isDownloading = true;
      _progressSc = StreamController<double>.broadcast();
      _listenToTask();
    }
  }

  /// Starts downloading the model using the native platform downloader.
  ///
  /// - **Android**: uses `DownloadManager` / `WorkManager` — continues if app is killed.
  /// - **iOS**: uses `NSURLSession` background session — continues if app is suspended.
  ///
  /// Safe to call multiple times — ignores the call if already downloading.
  /// Progress is emitted on [downloadProgressStream].
  /// Stream closes (done) on success, closes with error on failure.
  static Future<void> downloadModel() async {
    if (_isDownloading) return;
    _isDownloading = true;
    _downloadProgress = 0.0;
    _progressSc = StreamController<double>.broadcast();

    final dir = await getApplicationSupportDirectory();
    final destDir = dir.path;

    final task = DownloadTask(
      taskId: _taskId,
      url: _downloadUrl,
      filename: _modelFileName,
      directory: destDir,
      baseDirectory: BaseDirectory.root,
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 2,
    );

    final result = await FileDownloader().enqueue(task);
    if (!result) {
      _isDownloading = false;
      _progressSc?.addError(Exception('Failed to enqueue download'));
      await _progressSc?.close();
      _progressSc = null;
      return;
    }

    _listenToTask();
  }

  static void _listenToTask() {
    FileDownloader().updates.listen(
      (update) async {
        if (update is TaskProgressUpdate && update.task.taskId == _taskId) {
          if (update.progress >= 0) {
            _downloadProgress = update.progress;
            // Derive expectedBytes from task metadata if available.
            if (update.expectedFileSize > 0) {
              _expectedBytes = update.expectedFileSize;
            }
            _progressSc?.add(_downloadProgress);
          }
        } else if (update is TaskStatusUpdate && update.task.taskId == _taskId) {
          switch (update.status) {
            case TaskStatus.complete:
              await _onNativeDownloadComplete(update.task);
            case TaskStatus.failed:
            case TaskStatus.notFound:
              _isDownloading = false;
              _progressSc?.addError(Exception('Download failed: ${update.status}'));
              await _progressSc?.close();
              _progressSc = null;
            default:
              break;
          }
        }
      },
    );
  }

  static Future<void> _onNativeDownloadComplete(Task task) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final dest = File('${dir.path}/$_modelFileName');

      // Verify file size if we know the expected bytes.
      if (_expectedBytes > 0 && await dest.exists()) {
        final actualSize = await dest.length();
        if (actualSize != _expectedBytes) {
          throw Exception(
            'File size mismatch: got ${actualSize ~/ (1024 * 1024)} MB, '
            'expected ${_expectedBytes ~/ (1024 * 1024)} MB',
          );
        }
      }

      await FlutterGemma.installModel(modelType: ModelType.gemmaIt, fileType: ModelFileType.task)
          .fromFile(dest.path)
          .install();

      _downloadProgress = 1.0;
      _progressSc?.add(1.0);
    } catch (e) {
      _progressSc?.addError(e);
    } finally {
      _isDownloading = false;
      await _progressSc?.close();
      _progressSc = null;
    }
  }

  static String _getSystemPrompt() {
    return '''Task: Extract product info.
Rules:
1. productName: Literal name. No labels.
2. price: Numeric total as STRING (e.g. "349.00"). PRESERVE DOT.
3. expDate: MM/YY.
4. candidatePrices: Array of STRINGS of all prices found.
Output: {"productName":str,"price":str,"currency":"INR","expDate":str,"candidatePrices":[str]}''';
  }

  static Future<(MrpData?, String)> extractFromTextWithOutput(String ocrText) async {
    InferenceModelSession? session;
    try {
      await _ensureModelLoaded();
      print(' [LocalLlm] >>> RAW OCR SENT TO AI:\n$ocrText');
      session = await _model!.createSession(temperature: 0.2, topK: 20, systemInstruction: _getSystemPrompt());
      await session.addQueryChunk(Message(text: ocrText, isUser: true));
      final String raw = await session.getResponse();
      print(' [LocalLlm] >>> AI RAW OUTPUT:\n$raw');
      return (_parseResponse(raw), raw);
    } catch (e) { return (null, e.toString()); }
    finally { if (session != null) await session.close(); }
  }

  static Future<void> _ensureModelLoaded() async {
    if (_model != null) return;
    if (!_initialized) { await FlutterGemma.initialize(); _initialized = true; }
    final file = await _findOrAdoptModelFile();
    if (file == null) throw StateError('Model not found');
    await FlutterGemma.installModel(modelType: ModelType.gemmaIt, fileType: ModelFileType.task).fromFile(file.path).install();
    try {
      _model = await FlutterGemma.getActiveModel(maxTokens: 512, preferredBackend: PreferredBackend.gpu);
      _lastBackend = 'GPU';
    } catch (_) {
      _model = await FlutterGemma.getActiveModel(maxTokens: 512, preferredBackend: PreferredBackend.cpu);
      _lastBackend = 'CPU';
    }
  }

  static MrpData? _parseResponse(String raw) {
    try {
      final s = raw.indexOf('{'), e = raw.lastIndexOf('}');
      if (s == -1 || e <= s) return null;
      final j = jsonDecode(raw.substring(s, e + 1)) as Map<String, dynamic>;

      final rawPrice = j['price']?.toString() ?? '';
      final price = _cleanPrice(rawPrice);

      final cp = j['candidatePrices'];
      List<double> candidates = [];
      if (cp is List) {
        for (var item in cp) {
          final p = _cleanPrice(item.toString());
          if (p != null) candidates.add(p);
        }
      }

      return MrpData(
        productName: _s(j['productName']),
        mrpAmount: price,
        currencyCode: _s(j['currency']) ?? (_country == 'India' ? 'INR' : 'USD'),
        expDate: _s(j['expDate']),
        candidatePrices: candidates,
      );
    } catch (_) { return null; }
  }

  static double? _cleanPrice(String input) {
    final clean = input.replaceAll(RegExp(r'[^0-9.]'), '');
    double? val = double.tryParse(clean);
    if (val == null) return null;

    if (val > 1000 && !input.contains('.')) {
      final s = val.toInt().toString();
      if (s.endsWith('00') || s.endsWith('50') || s.endsWith('90')) {
        val = val / 100.0;
      }
    }
    return val;
  }

  static String? _s(dynamic v) { if (v == null || v == 'null') return null; final s = v.toString().trim(); return s.isEmpty ? null : s; }
}

class ModelFileStatus {
  final bool   exists;
  final int    sizeBytes;
  final int    expectedBytes;
  final String path;

  const ModelFileStatus({
    required this.exists,
    required this.sizeBytes,
    this.expectedBytes = 0,
    required this.path,
  });

  bool get isValid {
    if (!exists || sizeBytes < 100 * 1024 * 1024) return false;
    if (expectedBytes > 0) return sizeBytes == expectedBytes;
    return true;
  }

  String get sizeLabel {
    if (!exists) return 'Not found';
    final mb = sizeBytes / (1024 * 1024);
    if (expectedBytes > 0) {
      final expMb = expectedBytes / (1024 * 1024);
      return '${mb.toStringAsFixed(0)} / ${expMb.toStringAsFixed(0)} MB';
    }
    return '${mb.toStringAsFixed(0)} MB';
  }
}
