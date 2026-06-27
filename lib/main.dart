import 'dart:io';
import 'dart:typed_data';

import 'package:dartcv4/dartcv.dart' as cv;
import 'package:flutter/material.dart';
import 'package:flutter_edge_detection/flutter_edge_detection.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wanna Read',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const ScanPage(),
    );
  }
}

enum _State { idle, processing, done }

enum _Lang {
  eng(tessCode: 'eng', ttsLocale: 'en-US', label: 'EN'),
  ukr(tessCode: 'ukr', ttsLocale: 'uk-UA', label: 'UA');

  const _Lang({required this.tessCode, required this.ttsLocale, required this.label});
  final String tessCode;
  final String ttsLocale;
  final String label;
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  _State _state = _State.idle;
  Uint8List? _binarized;
  String _text = '';
  bool _speaking = false;
  _Lang _lang = _Lang.eng;
  final FlutterTts _tts = FlutterTts();

  @override
  void initState() {
    super.initState();
    _tts.setCompletionHandler(() => setState(() => _speaking = false));
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _scan() async {
    if (_state == _State.processing) return;

    try {
      final dir = await getApplicationSupportDirectory();
      final scanPath = p.join(dir.path, 'scan_${DateTime.now().millisecondsSinceEpoch}.jpeg');

      final success = await FlutterEdgeDetection.detectEdge(
        scanPath,
        canUseGallery: true,
        androidScanTitle: 'Scan document',
        androidCropTitle: 'Crop',
        androidCropBlackWhiteTitle: 'B&W',
        androidCropReset: 'Reset',
      );
      if (!success) return;

      setState(() => _state = _State.processing);

      final tmpDir = await getTemporaryDirectory();
      final processedPath = p.join(tmpDir.path, 'processed.png');

      final src = await cv.imreadAsync(scanPath);
      final gray = await cv.cvtColorAsync(src, cv.COLOR_BGR2GRAY);
      final blurred = await cv.gaussianBlurAsync(gray, (3, 3), 0);
      final binary = await cv.adaptiveThresholdAsync(
        blurred, 255.0, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY, 25, 10.0,
      );
      await cv.imwriteAsync(processedPath, binary);
      src.dispose();
      gray.dispose();
      blurred.dispose();
      binary.dispose();

      final binarized = await File(processedPath).readAsBytes();

      final raw = await FlutterTesseractOcr.extractText(
        processedPath,
        language: _lang.tessCode,
        args: {'psm': '6'},
      );

      final text = _normalizeForTts(raw);

      setState(() {
        _binarized = binarized;
        _text = text.isEmpty ? '(no text detected)' : text;
        _state = _State.done;
      });
    } catch (e) {
      setState(() => _state = _State.idle);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  String _normalizeForTts(String raw) {
    if (raw.isEmpty) return "";

    return raw
        .replaceAll(RegExp(r'-\s*\n'), '')

        .replaceAll(RegExp(r'\n{2,}'), '... ')
        
        .replaceAll('\n', ' ')
        
        .replaceAll(RegExp(r'[:;]'), '. ')
        
        .replaceAll(',', ', ,')
        
        .replaceAll(RegExp(r'\.(?!\.\.)'), '... ')
        
        .replaceAll(RegExp(r'[«»""„“\(\)\[\]\-\–\—\*]'), ' ')
        
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
  }

  Future<void> _toggleTts() async {
    if (_speaking) {
      await _tts.stop();
      setState(() => _speaking = false);
    } else {
      setState(() => _speaking = true);
      await _tts.setLanguage(_lang.ttsLocale);
      await _tts.setSpeechRate(0.45); // Hardcoded value
      await _tts.speak(_text);
    }
  }

  void _reset() {
    _tts.stop();
    setState(() {
      _state = _State.idle;
      _binarized = null;
      _text = '';
      _speaking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Wanna Read'),
        actions: [
          _LangToggle(
            current: _lang,
            onChanged: _state == _State.processing
                ? null
                : (l) => setState(() => _lang = l),
          ),
          if (_state == _State.done)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _reset,
              tooltip: 'Scan again',
            ),
        ],
      ),
      body: switch (_state) {
        _State.idle => _buildIdle(),
        _State.processing => _buildProcessing(),
        _State.done => _buildResult(),
      },
    );
  }

  Widget _buildIdle() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.document_scanner, size: 72, color: Colors.white30),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            icon: const Icon(Icons.document_scanner),
            label: const Text('Scan document'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              textStyle: const TextStyle(fontSize: 16),
            ),
            onPressed: _scan,
          ),
        ],
      ),
    );
  }

  Widget _buildProcessing() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Processing...', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _buildResult() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_binarized != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(_binarized!, fit: BoxFit.contain),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              const Text(
                'Recognized text',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(
                  _speaking ? Icons.stop_circle : Icons.play_circle,
                  color: _speaking ? Colors.redAccent : Colors.white,
                ),
                onPressed: _toggleTts,
                tooltip: _speaking ? 'Stop' : 'Read aloud',
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _text,
              style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _LangToggle extends StatelessWidget {
  final _Lang current;
  final ValueChanged<_Lang>? onChanged;
  const _LangToggle({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: SegmentedButton<_Lang>(
        segments: _Lang.values
            .map((l) => ButtonSegment(value: l, label: Text(l.label)))
            .toList(),
        selected: {current},
        onSelectionChanged: onChanged == null
            ? null
            : (s) => onChanged!(s.first),
        style: const ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
