import 'dart:io';

import 'package:flutter/material.dart';

import 'book_screen.dart';
import 'models.dart';
import 'audio_handler.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Book> _books = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    final books = await BookStorage.loadAllBooks();
    if (mounted) setState(() { _books = books; _loading = false; });
  }

  Future<void> _createBook() async {
    final result = await showModalBottomSheet<({String title, AppLang lang})>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _CreateBookSheet(),
    );
    if (result == null) return;
    final book = Book(
      id: genId(),
      title: result.title,
      lang: result.lang,
      createdAt: DateTime.now(),
    );
    await BookStorage.saveBook(book);
    setState(() => _books.insert(0, book));
  }

  Future<void> _deleteBook(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete book?'),
        content: Text('Delete "${book.title}" and all its pages? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (audioHandler.book?.id == book.id) await audioHandler.stop();
    await BookStorage.deleteBook(book.id);
    setState(() => _books.remove(book));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Wanna Read'),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
              ? _buildEmpty()
              : _buildGrid(),
      floatingActionButton: FloatingActionButton(
        onPressed: _createBook,
        tooltip: 'New book',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.menu_book_rounded, size: 80, color: Colors.white12),
          const SizedBox(height: 20),
          const Text('No books yet', style: TextStyle(color: Colors.white54, fontSize: 20, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          const Text('Tap + to create your first book', style: TextStyle(color: Colors.white30, fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return RefreshIndicator(
      onRefresh: _loadBooks,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.72,
        ),
        itemCount: _books.length,
        itemBuilder: (context, i) => _BookCard(
          book: _books[i],
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => BookScreen(book: _books[i])),
            );
            _loadBooks();
          },
          onLongPress: () => _deleteBook(_books[i]),
        ),
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _BookCard({required this.book, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final firstPage = book.pages.isNotEmpty ? book.pages.first : null;
    final total = book.pages.length;
    final readCount = book.pages.where((pg) => pg.isRead).length;
    final progress = total > 0 ? readCount / total : 0.0;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: firstPage != null
                  ? Image.file(
                      File(firstPage.imagePath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const _EmptyCover(),
                    )
                  : const _EmptyCover(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, height: 1.3),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _LangBadge(label: book.lang.label),
                      const Spacer(),
                      Text(
                        total == 0 ? '0 pages' : '$readCount / $total read',
                        style: const TextStyle(fontSize: 12, color: Colors.white38),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white10,
              color: Colors.greenAccent,
              minHeight: 3,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCover extends StatelessWidget {
  const _EmptyCover();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white12,
      child: const Icon(Icons.menu_book_rounded, size: 52, color: Colors.white12),
    );
  }
}

class _LangBadge extends StatelessWidget {
  final String label;
  const _LangBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w600)),
    );
  }
}

class _CreateBookSheet extends StatefulWidget {
  const _CreateBookSheet();

  @override
  State<_CreateBookSheet> createState() => _CreateBookSheetState();
}

class _CreateBookSheetState extends State<_CreateBookSheet> {
  final _ctrl = TextEditingController();
  AppLang _lang = AppLang.eng;

  bool get _canCreate => _ctrl.text.trim().isNotEmpty;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _ctrl.text.trim();
    if (title.isEmpty) return;
    Navigator.pop(context, (title: title, lang: _lang));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('New Book', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          TextField(
            controller: _ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: _canCreate ? (_) => _submit() : null,
          ),
          const SizedBox(height: 16),
          SegmentedButton<AppLang>(
            segments: AppLang.values
                .map((l) => ButtonSegment(value: l, label: Text(l.label)))
                .toList(),
            selected: {_lang},
            onSelectionChanged: (s) => setState(() => _lang = s.first),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _canCreate ? _submit : null,
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            child: const Text('Create', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }
}
