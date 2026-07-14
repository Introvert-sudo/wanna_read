import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum AppLang {
  eng(tessCode: 'eng', ttsLocale: 'en-US', label: 'EN'),
  ukr(tessCode: 'ukr', ttsLocale: 'uk-UA', label: 'UA');

  const AppLang({required this.tessCode, required this.ttsLocale, required this.label});
  final String tessCode;
  final String ttsLocale;
  final String label;

  static AppLang fromCode(String code) =>
      AppLang.values.firstWhere((l) => l.tessCode == code, orElse: () => AppLang.eng);
}

String genId() {
  final rand = Random.secure();
  final suffix = List.generate(8, (_) => rand.nextInt(36).toRadixString(36)).join();
  return '${DateTime.now().millisecondsSinceEpoch}$suffix';
}

class BookPage {
  final String id;
  final String imagePath;
  final String text;

  const BookPage({required this.id, required this.imagePath, required this.text});

  Map<String, dynamic> toJson() => {'id': id, 'imagePath': imagePath, 'text': text};

  factory BookPage.fromJson(Map<String, dynamic> j) => BookPage(
        id: j['id'] as String,
        imagePath: j['imagePath'] as String,
        text: j['text'] as String,
      );
}

class Book {
  final String id;
  String title;
  final AppLang lang;
  final DateTime createdAt;
  final List<BookPage> pages;

  Book({
    required this.id,
    required this.title,
    required this.lang,
    required this.createdAt,
    List<BookPage>? pages,
  }) : pages = pages ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'langCode': lang.tessCode,
        'createdAt': createdAt.toIso8601String(),
        'pages': pages.map((pg) => pg.toJson()).toList(),
      };

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        id: j['id'] as String,
        title: j['title'] as String,
        lang: AppLang.fromCode(j['langCode'] as String),
        createdAt: DateTime.parse(j['createdAt'] as String),
        pages: (j['pages'] as List<dynamic>)
            .map((pg) => BookPage.fromJson(pg as Map<String, dynamic>))
            .toList(),
      );
}

class BookStorage {
  static Future<Directory> _booksDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'books'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> bookDir(String bookId) async {
    final base = await _booksDir();
    final dir = Directory(p.join(base.path, bookId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _metaFile(String bookId) async {
    final dir = await bookDir(bookId);
    return File(p.join(dir.path, 'meta.json'));
  }

  static Future<void> saveBook(Book book) async {
    final file = await _metaFile(book.id);
    await file.writeAsString(jsonEncode(book.toJson()));
  }

  static Future<Book?> loadBook(String bookId) async {
    try {
      final file = await _metaFile(bookId);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return Book.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static Future<List<Book>> loadAllBooks() async {
    final dir = await _booksDir();
    final books = <Book>[];
    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final book = await loadBook(p.basename(entity.path));
        if (book != null) books.add(book);
      }
    }
    books.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return books;
  }

  static Future<void> deleteBook(String bookId) async {
    final dir = await bookDir(bookId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
