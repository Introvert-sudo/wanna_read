import 'dart:io';
import 'dart:math';

import 'package:dartcv4/dartcv.dart' as cv;
import 'package:flutter/material.dart';
import 'package:flutter_edge_detection/flutter_edge_detection.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class BookScreen extends StatefulWidget {
  final Book book;
  const BookScreen({super.key, required this.book});

  @override
  State<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends State<BookScreen> {
  late final Book _book;
  late final PageController _pageController;
  final FlutterTts _tts = FlutterTts();

  int _currentPage = 0;
  bool _speaking = false;
  bool _scanning = false;
  bool _autoContinuingTts = false;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _pageController = PageController();
    _tts.setCompletionHandler(() {
      if (!_autoContinuingTts && mounted) setState(() => _speaking = false);
      _autoContinuingTts = false;
    });
  }

  @override
  void dispose() {
    _tts.stop();
    _pageController.dispose();
    super.dispose();
  }

  // ── TTS ─────────────────────────────────────────────────────────────────────

  Future<void> _speakPage(int idx) async {
    if (idx < 0 || idx >= _book.pages.length) return;
    _autoContinuingTts = true;
    await _tts.stop();
    if (!mounted || !_speaking) return;
    await _tts.setLanguage(_book.lang.ttsLocale);
    await _tts.setSpeechRate(0.45);
    await _tts.speak(_book.pages[idx].text);
  }

  Future<void> _toggleTts() async {
    if (_book.pages.isEmpty) return;
    if (_speaking) {
      await _tts.stop();
      setState(() => _speaking = false);
    } else {
      setState(() => _speaking = true);
      await _speakPage(_currentPage);
    }
  }

  void _onPageChanged(int idx) {
    final wasSpeaking = _speaking;
    setState(() => _currentPage = idx);
    if (wasSpeaking) _speakPage(idx);
  }

  // ── Scan (add new page) ──────────────────────────────────────────────────────

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
    _pageController.animateToPage(
      _book.pages.length - 1,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  // ── Rescan current page ──────────────────────────────────────────────────────

  Future<void> _rescanCurrentPage() async {
    if (_scanning || _book.pages.isEmpty) return;
    final oldPage = _book.pages[_currentPage];
    final result = await _runScanPipeline();
    if (result == null || !mounted) return;
    final (imagePath, text) = result;
    // delete old image
    try { await File(oldPage.imagePath).delete(); } catch (_) {}
    _book.pages[_currentPage] = oldPage.copyWith(imagePath: imagePath, text: text);
    await BookStorage.saveBook(_book);
    if (mounted) setState(() => _scanning = false);
  }

  // ── Shared scan pipeline ─────────────────────────────────────────────────────

  /// Returns (stableImagePath, normalizedText) or null on cancel/error.
  Future<(String, String)?> _runScanPipeline() async {
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
    if (!success || !mounted) return null;

    setState(() => _scanning = true);

    try {
      final tmpDir = await getTemporaryDirectory();
      final tmpProcessed = p.join(tmpDir.path, 'processed_tmp.png');

      final src = await cv.imreadAsync(scanPath);
      final gray = await cv.cvtColorAsync(src, cv.COLOR_BGR2GRAY);
      final blurred = await cv.gaussianBlurAsync(gray, (3, 3), 0);
      final binary = await cv.adaptiveThresholdAsync(
        blurred, 255.0, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY, 25, 10.0,
      );
      await cv.imwriteAsync(tmpProcessed, binary);
      src.dispose();
      gray.dispose();
      blurred.dispose();
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

  // ── Delete current page ───────────────────────────────────────────────────────

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

    if (_speaking) {
      _autoContinuingTts = true;
      await _tts.stop();
    }

    _book.pages.removeAt(_currentPage);
    await BookStorage.saveBook(_book);

    if (!mounted) return;

    if (_book.pages.isEmpty) {
      setState(() { _currentPage = 0; _speaking = false; _autoContinuingTts = false; });
    } else {
      final newIdx = min(_currentPage, _book.pages.length - 1);
      setState(() { _currentPage = newIdx; });
      _pageController.jumpToPage(newIdx);
      if (_speaking) _speakPage(newIdx);
    }
  }

  // ── Mark as read ─────────────────────────────────────────────────────────────

  Future<void> _toggleRead() async {
    if (_book.pages.isEmpty) return;
    final page = _book.pages[_currentPage];
    _book.pages[_currentPage] = page.copyWith(isRead: !page.isRead);
    await BookStorage.saveBook(_book);
    setState(() {});
  }

  // ── Navigation helpers ────────────────────────────────────────────────────────

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

  // ── Text normalization ────────────────────────────────────────────────────────

  String _normalizeForTts(String raw) {
    if (raw.isEmpty) return '';
    return raw
        .replaceAll(RegExp(r'-\s*\n'), '')
        .replaceAll(RegExp(r'\n{2,}'), '... ')
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'[:;]'), '. ')
        .replaceAll(',', ', ,')
        .replaceAll(RegExp(r'\.(?!\.\.)'), '... ')
        .replaceAll(RegExp(r'[«»""„"\(\)\[\]\-\–\—\*]'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

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
          if (hasPages)
            IconButton(icon: const Icon(Icons.search), onPressed: _openSearch, tooltip: 'Search pages'),
          if (hasPages)
            PopupMenuButton<_PageAction>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) {
                if (action == _PageAction.rescan) _rescanCurrentPage();
                if (action == _PageAction.delete) _deleteCurrentPage();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: _PageAction.rescan, child: ListTile(
                  leading: Icon(Icons.document_scanner),
                  title: Text('Rescan this page'),
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.document_scanner, size: 72, color: Colors.white12),
          const SizedBox(height: 20),
          const Text('No pages yet', style: TextStyle(color: Colors.white54, fontSize: 20, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          const Text('Tap the scan button below', style: TextStyle(color: Colors.white30, fontSize: 14)),
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
            errorBuilder: (_, __, ___) => const Center(
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
              style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.65),
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
            // Page indicator – tap to jump
            TextButton(
              onPressed: hasPages ? _showJumpDialog : null,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white60,
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                minimumSize: const Size(80, 48),
              ),
              child: Text(hasPages ? '${_currentPage + 1} / ${_book.pages.length}' : '–'),
            ),
            // Mark as read
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
            // TTS play/stop
            IconButton(
              iconSize: 34,
              icon: Icon(
                _speaking ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                color: _speaking ? Colors.redAccent : (hasPages ? Colors.white : Colors.white24),
              ),
              onPressed: hasPages ? _toggleTts : null,
              tooltip: _speaking ? 'Stop' : 'Read aloud',
            ),
            const SizedBox(width: 4),
            // Scan
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

enum _PageAction { rescan, delete }

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
      separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
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
