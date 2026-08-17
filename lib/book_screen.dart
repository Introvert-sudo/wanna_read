import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartcv4/dartcv.dart' as cv;
import 'package:flutter/material.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'audio_handler.dart';
import 'models.dart';
import 'scanner_screen.dart';

class BookScreen extends StatefulWidget {
  final Book book;
  const BookScreen({super.key, required this.book});

  @override
  State<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends State<BookScreen> {
  late final Book _book;
  late final PageController _pageController;
  late final StreamSubscription _playSub;
  late final StreamSubscription _eventSub;

  int _currentPage = 0;
  bool _speaking = false;
  bool _scanning = false;
  AppSettings _settings = AppSettings();

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    final sameBook = audioHandler.book?.id == _book.id;
    _currentPage = sameBook
        ? audioHandler.pageIndex.clamp(0, max(0, _book.pages.length - 1))
        : 0;
    _pageController = PageController(initialPage: _currentPage);
    _speaking = audioHandler.playbackState.value.playing && sameBook;

    _playSub = audioHandler.playbackState.listen((s) {
      if (mounted) setState(() => _speaking = s.playing);
    });
    _eventSub = audioHandler.customEvent.listen((e) {
      if (e is Map && e['pageIndex'] is int && mounted) {
        final idx = e['pageIndex'] as int;
        if (idx != _currentPage && idx >= 0 && idx < _book.pages.length) {
          _pageController.animateToPage(
            idx,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOut,
          );
        }
      }
    });

    _initPlayback();
  }

  Future<void> _initPlayback() async {
    final settings = await AppSettings.load();
    if (!mounted) return;
    setState(() => _settings = settings);
    await audioHandler.loadBook(_book, _currentPage, speechRate: settings.speechRate);
  }

  @override
  void dispose() {
    _playSub.cancel();
    _eventSub.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _toggleTts() async {
    if (_book.pages.isEmpty) return;
    if (_speaking) {
      await audioHandler.pause();
    } else {
      await audioHandler.setPage(_currentPage);
      await audioHandler.play();
    }
  }

  void _onPageChanged(int idx) {
    setState(() => _currentPage = idx);
    audioHandler.setPage(idx);
  }

  Future<void> _scan() async {
    if (_scanning) return;
    final result = await _runScanPipeline();
    if (result == null || !mounted) return;
    final (imagePath, text) = result;
    final page = BookPage(id: genId(), imagePath: imagePath, text: text);
    _book.pages.add(page);
    await BookStorage.saveBook(_book);
    if (!mounted) return;
    setState(() => _scanning = false);
    await audioHandler.loadBook(_book, _book.pages.length - 1, speechRate: _settings.speechRate);
    _pageController.animateToPage(
      _book.pages.length - 1,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _rescanCurrentPage() async {
    if (_scanning || _book.pages.isEmpty) return;
    final oldPage = _book.pages[_currentPage];
    final result = await _runScanPipeline();
    if (result == null || !mounted) return;
    final (imagePath, text) = result;
    try { await File(oldPage.imagePath).delete(); } catch (_) {}
    _book.pages[_currentPage] = oldPage.copyWith(imagePath: imagePath, text: text);
    await BookStorage.saveBook(_book);
    await audioHandler.loadBook(_book, _currentPage, speechRate: _settings.speechRate);
    if (mounted) setState(() => _scanning = false);
  }

  Future<(String, String)?> _runScanPipeline() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return null;

    final picked = await ImagePicker().pickImage(source: source, imageQuality: 95);
    if (picked == null || !mounted) return null;

    final warped = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => ScannerScreen(photoPath: picked.path)),
    );
    if (warped == null || !mounted) return null;

    setState(() => _scanning = true);

    try {
      final tmpDir = await getTemporaryDirectory();
      final tmpProcessed = p.join(tmpDir.path, 'processed_tmp.png');

      final src = await cv.imreadAsync(warped);
      final gray = await cv.cvtColorAsync(src, cv.COLOR_BGR2GRAY);
      final blurred = await cv.gaussianBlurAsync(gray, (3, 3), 0);
      var binary = await cv.adaptiveThresholdAsync(
        blurred, 255.0, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY, 25, 10.0,
      );
      src.dispose();
      gray.dispose();
      blurred.dispose();

      final deskewed = await _deskew(binary);
      if (!identical(deskewed, binary)) binary.dispose();
      binary = deskewed;

      await cv.imwriteAsync(tmpProcessed, binary);
      binary.dispose();

      final raw = await FlutterTesseractOcr.extractText(
        tmpProcessed,
        language: _book.lang.tessCode,
        args: {'psm': '6'},
      );
      final text = _normalizeForTts(raw);

      final bookDirectory = await BookStorage.bookDir(_book.id);
      final pageId = genId();
      final stablePath = p.join(bookDirectory.path, 'page_$pageId.png');
      await File(tmpProcessed).copy(stablePath);

      return (stablePath, text.isEmpty ? '(no text detected)' : text);
    } catch (e) {
      if (mounted) {
        setState(() => _scanning = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
      return null;
    }
  }

  Future<cv.Mat> _deskew(cv.Mat binary) async {
    cv.Mat? edges;
    cv.Mat? lines;
    cv.Mat? rot;
    try {
      edges = await cv.cannyAsync(binary, 50, 150);
      final minLen = min(binary.cols, binary.rows) * 0.2;
      lines = await cv.HoughLinesPAsync(
        edges, 1, pi / 180, 80,
        minLineLength: minLen, maxLineGap: 20,
      );
      if (lines.rows == 0) return binary;

      final angles = <double>[];
      for (var i = 0; i < lines.rows; i++) {
        final l = lines.at<cv.Vec4i>(i, 0);
        final dx = (l.val3 - l.val1).toDouble();
        final dy = (l.val4 - l.val2).toDouble();
        var angle = atan2(dy, dx) * 180 / pi;
        if (angle > 45) angle -= 90;
        if (angle < -45) angle += 90;
        if (angle.abs() < 15) angles.add(angle);
      }
      if (angles.isEmpty) return binary;
      angles.sort();
      final median = angles[angles.length ~/ 2];
      if (median.abs() < 1) return binary;

      rot = await cv.getRotationMatrix2DAsync(
        cv.Point2f(binary.cols / 2, binary.rows / 2),
        median,
        1.0,
      );
      return await cv.warpAffineAsync(
        binary,
        rot,
        (binary.cols, binary.rows),
        borderValue: cv.Scalar(255, 255, 255, 255),
      );
    } catch (_) {
      return binary;
    } finally {
      edges?.dispose();
      lines?.dispose();
      rot?.dispose();
    }
  }

  Future<void> _deleteCurrentPage() async {
    if (_book.pages.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete page?'),
        content: Text('Delete page ${_currentPage + 1}? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final page = _book.pages[_currentPage];
    try { await File(page.imagePath).delete(); } catch (_) {}

    final wasSpeaking = _speaking;
    if (wasSpeaking) await audioHandler.pause();

    _book.pages.removeAt(_currentPage);
    await BookStorage.saveBook(_book);

    if (!mounted) return;

    if (_book.pages.isEmpty) {
      setState(() => _currentPage = 0);
      await audioHandler.loadBook(_book, 0, speechRate: _settings.speechRate);
    } else {
      final newIdx = min(_currentPage, _book.pages.length - 1);
      setState(() => _currentPage = newIdx);
      _pageController.jumpToPage(newIdx);
      await audioHandler.loadBook(_book, newIdx, speechRate: _settings.speechRate);
      if (wasSpeaking) await audioHandler.play();
    }
  }

  Future<void> _toggleRead() async {
    if (_book.pages.isEmpty) return;
    final page = _book.pages[_currentPage];
    _book.pages[_currentPage] = page.copyWith(isRead: !page.isRead);
    await BookStorage.saveBook(_book);
    setState(() {});
  }

  Future<void> _exportText() async {
    if (_book.pages.isEmpty) return;
    final buf = StringBuffer();
    for (var i = 0; i < _book.pages.length; i++) {
      buf.writeln('--- Page ${i + 1} ---');
      buf.writeln(_book.pages[i].text);
      buf.writeln();
    }
    final dir = await getTemporaryDirectory();
    final safeTitle = _book.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
    final file = File(p.join(dir.path, '${safeTitle.isEmpty ? 'book' : safeTitle}.txt'));
    await file.writeAsString(buf.toString());
    await Share.shareXFiles([XFile(file.path)], subject: _book.title);
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                Text('Speech rate  ${_settings.speechRate.toStringAsFixed(2)}'),
                Slider(
                  min: 0.2,
                  max: 0.8,
                  value: _settings.speechRate,
                  onChanged: (v) {
                    setSheet(() => _settings.speechRate = v);
                    audioHandler.setSpeechRate(v);
                  },
                  onChangeEnd: (_) => _settings.save(),
                ),
                Text('Font size  ${_settings.fontSize.round()}'),
                Slider(
                  min: 12,
                  max: 28,
                  value: _settings.fontSize,
                  onChanged: (v) {
                    setSheet(() => _settings.fontSize = v);
                    setState(() {});
                  },
                  onChangeEnd: (_) => _settings.save(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showJumpDialog() {
    if (_book.pages.isEmpty) return;
    final ctrl = TextEditingController(text: '${_currentPage + 1}');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '1 – ${_book.pages.length}',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _jumpFromCtrl(ctrl),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => _jumpFromCtrl(ctrl), child: const Text('Go')),
        ],
      ),
    );
  }

  void _jumpFromCtrl(TextEditingController ctrl) {
    final n = int.tryParse(ctrl.text.trim());
    if (n != null && n >= 1 && n <= _book.pages.length) {
      Navigator.pop(context);
      _pageController.animateToPage(n - 1, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    }
  }

  Future<void> _openSearch() async {
    final idx = await showSearch<int?>(
      context: context,
      delegate: _PageSearchDelegate(_book.pages),
    );
    if (idx != null && idx >= 0 && mounted) {
      _pageController.animateToPage(idx, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    }
  }

  String _normalizeForTts(String raw) {
    if (raw.isEmpty) return '';
    return raw
        .replaceAll(RegExp(r'-\s*\n'), '')
        .replaceAll(RegExp(r'\n{2,}'), '... ')
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'[:;]'), '. ')
        .replaceAll(RegExp(r'(?<!\d)\.(?!\.)'), '... ')
        .replaceAll(RegExp(r'[«»""„"\(\)\[\]\-\–\—\*]'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final hasPages = _book.pages.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(_book.title, overflow: TextOverflow.ellipsis),
        actions: [
          _LangBadge(label: _book.lang.label),
          IconButton(icon: const Icon(Icons.tune), onPressed: _showSettings, tooltip: 'Settings'),
          if (hasPages)
            IconButton(icon: const Icon(Icons.search), onPressed: _openSearch, tooltip: 'Search pages'),
          if (hasPages)
            PopupMenuButton<_PageAction>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) {
                if (action == _PageAction.rescan) _rescanCurrentPage();
                if (action == _PageAction.export) _exportText();
                if (action == _PageAction.delete) _deleteCurrentPage();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: _PageAction.rescan, child: ListTile(
                  leading: Icon(Icons.document_scanner),
                  title: Text('Rescan this page'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
                PopupMenuItem(value: _PageAction.export, child: ListTile(
                  leading: Icon(Icons.ios_share),
                  title: Text('Export text'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
                PopupMenuItem(value: _PageAction.delete, child: ListTile(
                  leading: Icon(Icons.delete_outline, color: Colors.redAccent),
                  title: Text('Delete this page', style: TextStyle(color: Colors.redAccent)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                )),
              ],
            ),
        ],
      ),
      body: Stack(
        children: [
          hasPages ? _buildPageView() : _buildEmpty(),
          if (_scanning) _buildScanOverlay(),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(hasPages),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.document_scanner, size: 72, color: Colors.white12),
          SizedBox(height: 20),
          Text('No pages yet', style: TextStyle(color: Colors.white54, fontSize: 20, fontWeight: FontWeight.w500)),
          SizedBox(height: 8),
          Text('Tap the scan button below', style: TextStyle(color: Colors.white30, fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildPageView() {
    return PageView.builder(
      controller: _pageController,
      onPageChanged: _onPageChanged,
      itemCount: _book.pages.length,
      itemBuilder: (_, i) => _buildPage(_book.pages[i]),
    );
  }

  Widget _buildPage(BookPage page) {
    return Column(
      children: [
        Expanded(
          flex: 6,
          child: Image.file(
            File(page.imagePath),
            fit: BoxFit.contain,
            errorBuilder: (_, error, stack) => const Center(
              child: Icon(Icons.broken_image_outlined, size: 64, color: Colors.white24),
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SelectableText(
              page.text,
              style: TextStyle(color: Colors.white, fontSize: _settings.fontSize, height: 1.65),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildScanOverlay() {
    return Container(
      color: Colors.black54,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Processing...', style: TextStyle(color: Colors.white70, fontSize: 15)),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(bool hasPages) {
    final page = hasPages ? _book.pages[_currentPage] : null;
    return SafeArea(
      child: Container(
        height: 64,
        color: Colors.grey[900],
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            TextButton(
              onPressed: hasPages ? _showJumpDialog : null,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white60,
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                minimumSize: const Size(80, 48),
              ),
              child: Text(hasPages ? '${_currentPage + 1} / ${_book.pages.length}' : '–'),
            ),
            IconButton(
              iconSize: 26,
              icon: Icon(
                page?.isRead == true ? Icons.check_circle : Icons.check_circle_outline,
                color: page?.isRead == true ? Colors.greenAccent : Colors.white38,
              ),
              onPressed: hasPages ? _toggleRead : null,
              tooltip: page?.isRead == true ? 'Mark as unread' : 'Mark as read',
            ),
            const Spacer(),
            IconButton(
              iconSize: 34,
              icon: Icon(
                _speaking ? Icons.pause_circle_outline : Icons.play_circle_outline,
                color: _speaking ? Colors.redAccent : (hasPages ? Colors.white : Colors.white24),
              ),
              onPressed: hasPages ? _toggleTts : null,
              tooltip: _speaking ? 'Pause' : 'Read aloud',
            ),
            const SizedBox(width: 4),
            IconButton(
              iconSize: 28,
              icon: _scanning
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Icon(Icons.document_scanner),
              color: Colors.white,
              onPressed: _scanning ? null : _scan,
              tooltip: 'Scan new page',
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

enum _PageAction { rescan, export, delete }

class _LangBadge extends StatelessWidget {
  final String label;
  const _LangBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

class _PageSearchDelegate extends SearchDelegate<int?> {
  final List<BookPage> pages;
  _PageSearchDelegate(this.pages);

  @override
  String get searchFieldLabel => 'Search pages...';

  @override
  ThemeData appBarTheme(BuildContext context) {
    return Theme.of(context).copyWith(
      inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none),
    );
  }

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _buildList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildList(context);

  Widget _buildList(BuildContext context) {
    final q = query.toLowerCase().trim();
    final filtered = pages.asMap().entries
        .where((e) => q.isEmpty || e.value.text.toLowerCase().contains(q))
        .toList();

    if (filtered.isEmpty) {
      return const Center(
        child: Text('No pages match', style: TextStyle(color: Colors.white54, fontSize: 16)),
      );
    }

    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (_, i) => const Divider(height: 1, color: Colors.white10),
      itemBuilder: (context, i) {
        final idx = filtered[i].key;
        final page = filtered[i].value;
        final preview = page.text.length > 120 ? '${page.text.substring(0, 120)}...' : page.text;
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.white12,
            child: Text('${idx + 1}', style: const TextStyle(fontSize: 13, color: Colors.white70)),
          ),
          title: Text(
            preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, color: Colors.white70, height: 1.4),
          ),
          trailing: page.isRead ? const Icon(Icons.check_circle, size: 16, color: Colors.greenAccent) : null,
          onTap: () => close(context, idx),
        );
      },
    );
  }
}
