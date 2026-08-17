import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'models.dart';

late TtsAudioHandler audioHandler;

class TtsAudioHandler extends BaseAudioHandler {
  final FlutterTts _tts = FlutterTts();
  Book? _book;
  int _pageIdx = 0;
  double _speechRate = 0.45;
  bool _ignoreComplete = false;

  TtsAudioHandler() {
    _tts.setCompletionHandler(_onComplete);
    _broadcast(playing: false, idle: true);
  }

  Book? get book => _book;
  int get pageIndex => _pageIdx;

  Future<void> loadBook(Book book, int pageIdx, {double? speechRate}) async {
    final same = _book?.id == book.id;
    if (!same) {
      _ignoreComplete = true;
      await _tts.stop();
      _ignoreComplete = false;
    }
    _book = book;
    _pageIdx = pageIdx.clamp(0, math.max(0, book.pages.length - 1));
    if (speechRate != null) _speechRate = speechRate;
    _updateMediaItem();
    if (!same) _broadcast(playing: false);
  }

  Future<void> setPage(int idx) async {
    if (_book == null || idx < 0 || idx >= _book!.pages.length) return;
    if (idx == _pageIdx) return;
    _pageIdx = idx;
    _updateMediaItem();
    if (playbackState.value.playing) await _speakCurrent();
  }

  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate;
    await _tts.setSpeechRate(rate);
  }

  @override
  Future<void> play() async {
    if (_book == null || _book!.pages.isEmpty) return;
    _broadcast(playing: true);
    await _speakCurrent();
  }

  @override
  Future<void> pause() async {
    _ignoreComplete = true;
    await _tts.stop();
    _ignoreComplete = false;
    _broadcast(playing: false);
  }

  @override
  Future<void> stop() async {
    _ignoreComplete = true;
    await _tts.stop();
    _ignoreComplete = false;
    _broadcast(playing: false, idle: true);
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    if (_book == null || _pageIdx >= _book!.pages.length - 1) return;
    _pageIdx++;
    _updateMediaItem();
    customEvent.add({'pageIndex': _pageIdx});
    if (playbackState.value.playing) await _speakCurrent();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_book == null || _pageIdx <= 0) return;
    _pageIdx--;
    _updateMediaItem();
    customEvent.add({'pageIndex': _pageIdx});
    if (playbackState.value.playing) await _speakCurrent();
  }

  @override
  Future<void> onTaskRemoved() async {}

  @override
  Future<void> onNotificationDeleted() => stop();

  Future<void> _speakCurrent() async {
    final book = _book;
    if (book == null || _pageIdx < 0 || _pageIdx >= book.pages.length) return;
    _ignoreComplete = true;
    await _tts.stop();
    _ignoreComplete = false;
    await _tts.setLanguage(book.lang.ttsLocale);
    await _tts.setSpeechRate(_speechRate);
    await _tts.speak(book.pages[_pageIdx].text);
  }

  void _onComplete() {
    if (_ignoreComplete || !playbackState.value.playing) return;
    if (_book != null && _pageIdx < _book!.pages.length - 1) {
      skipToNext();
    } else {
      _broadcast(playing: false);
    }
  }

  void _updateMediaItem() {
    final book = _book;
    if (book == null) {
      mediaItem.add(null);
      return;
    }
    final page = book.pages.isEmpty ? 0 : _pageIdx + 1;
    mediaItem.add(MediaItem(
      id: '${book.id}_$page',
      title: book.title,
      album: 'Wanna Read',
      artist: book.pages.isEmpty ? 'No pages' : 'Page $page / ${book.pages.length}',
    ));
  }

  void _broadcast({required bool playing, bool idle = false}) {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const [0, 1, 2],
      processingState: idle ? AudioProcessingState.idle : AudioProcessingState.ready,
      playing: playing,
    ));
  }
}
