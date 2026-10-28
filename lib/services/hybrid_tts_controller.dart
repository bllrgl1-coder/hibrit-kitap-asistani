import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import '../models/book_models.dart';
import 'auto_cache_cleaner.dart';
import 'edge_tts_client.dart';

/// Aktif kullanılan TTS motoru türü
enum ActiveTtsEngine {
  edgeNeuralOnline, // Birincil: Microsoft Edge Neural TTS (Ahmet / Emel)
  androidLocalOffline, // İkincil/Yedek: Android Yerel TTS (flutter_tts)
}

/// Hibrit TTS Mimarisi ve Metin-Ses Senkronizasyon Yöneticisi:
/// 1. Birincil Motor: Edge Neural TTS (WebSocket + SSML `<prosody rate>`)
/// 2. İkincil Motor: `flutter_tts` (Çevrimdışı otomatik yedek)
/// 3. Look-ahead Buffer: `N.` cümle çalarken `N+1` ve `N+2` cümlelerini temp dizine önbellekler
/// 4. Senkronize Vurgulama: `activeSentenceIndex` (`ValueNotifier<int>`) ile Reader UI'ı tetikler
class HybridTtsController extends ChangeNotifier {
  final EdgeTtsClient _edgeClient = EdgeTtsClient();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterTts _flutterTts = FlutterTts();

  /// Okuyucu Arayüzünün (Reader UI) dinlediği aktif cümle ve paragraf indeksleri
  final ValueNotifier<int> activeSentenceIndex = ValueNotifier<int>(-1);
  final ValueNotifier<int> activeParagraphIndex = ValueNotifier<int>(-1);

  ParsedBook? _currentBook;
  int _currentChapterIndex = 0;

  bool _isPlaying = false;
  bool _isSynthesizing = false;
  TurkishNeuralVoice _selectedVoice = TurkishNeuralVoice.ahmet;

  /// Hız çarpanı: 0.80x (-20%) ile 2.00x (+100%) arası (0.75x dahil desteklenir)
  double _speedMultiplier = 1.0;

  /// Uyku zamanlayıcısı (Faz 5) fade-out için ses seviyesi (0.0 - 1.0)
  double _volume = 1.0;

  ActiveTtsEngine _activeEngine = ActiveTtsEngine.edgeNeuralOnline;
  bool _forceOfflineMode = false;

  /// Sıfır Gecikmeli Önbellekleme (Look-ahead Buffer) kuyruğu:
  /// sentenceIndex -> İndirilmekte olan veya indirilmiş MP3 dosyasının Future'ı
  final Map<int, Future<File?>> _prefetchQueue = {};
  final Map<int, File> _resolvedCacheFiles = {};

  /// Oynatma döngüsü iptal jetonu (kullanıcı başka cümleye/bölüme tıkladığında eski döngüyü durdurur)
  int _playbackSessionToken = 0;
  Completer<void>? _localTtsCompleter;

  /// Bölüm bittiğinde Faz 5'teki Uyku Zamanlayıcısına ("Mevcut Bölüm Bitince Durdur") haber veren geri çağırım
  bool Function()? onChapterFinishedShouldStop;

  /// Durum değiştiğinde Faz 5'teki Arka Plan Servisini (`audio_service`) bilgilendiren geri çağırım
  VoidCallback? onPlaybackStateChangedForService;

  HybridTtsController() {
    _initFlutterTtsFallback();
  }

  // --- GETTERS ---
  ParsedBook? get currentBook => _currentBook;
  int get currentChapterIndex => _currentChapterIndex;
  BookChapter? get currentChapter {
    if (_currentBook == null ||
        _currentChapterIndex < 0 ||
        _currentChapterIndex >= _currentBook!.chapters.length) {
      return null;
    }
    return _currentBook!.chapters[_currentChapterIndex];
  }

  bool get isPlaying => _isPlaying;
  bool get isSynthesizing => _isSynthesizing;
  TurkishNeuralVoice get selectedVoice => _selectedVoice;
  double get speedMultiplier => _speedMultiplier;
  double get volume => _volume;
  ActiveTtsEngine get activeEngine => _activeEngine;
  bool get isOfflineFallbackActive =>
      _activeEngine == ActiveTtsEngine.androidLocalOffline;

  /// İkincil / Yedek Motor (`flutter_tts`) ilk kurulumu
  Future<void> _initFlutterTtsFallback() async {
    try {
      await _flutterTts.setLanguage('tr-TR');
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setVolume(_volume);
      await _flutterTts.setSpeechRate(_mapSpeedToFlutterTts(_speedMultiplier));

      _flutterTts.setCompletionHandler(() {
        if (_localTtsCompleter != null && !_localTtsCompleter!.isCompleted) {
          _localTtsCompleter!.complete();
        }
      });

      _flutterTts.setCancelHandler(() {
        if (_localTtsCompleter != null && !_localTtsCompleter!.isCompleted) {
          _localTtsCompleter!.complete();
        }
      });

      _flutterTts.setErrorHandler((dynamic msg) {
        if (_localTtsCompleter != null && !_localTtsCompleter!.isCompleted) {
          _localTtsCompleter!.complete();
        }
      });
    } catch (_) {
      // Test veya masaüstü ortamında TTS yoksa sessizce geç
    }
  }

  /// Kitabı ve başlangıç bölümünü yükler
  Future<void> loadBook(
    ParsedBook book, {
    int initialChapterIndex = 0,
    int initialSentenceIndex = 0,
  }) async {
    await stop();
    _currentBook = book;

    // Eğer başlangıç bölümü filtre dışıysa ("Önsözü/İçindekileri atla"), ilk dahil edilen bölüme geç
    int targetChapter = initialChapterIndex.clamp(
      0,
      book.chapters.isEmpty ? 0 : book.chapters.length - 1,
    );
    if (book.chapters.isNotEmpty && !book.chapters[targetChapter].isIncluded) {
      final int firstIncluded =
          book.chapters.indexWhere((c) => c.isIncluded);
      if (firstIncluded != -1) {
        targetChapter = firstIncluded;
      }
    }

    _currentChapterIndex = targetChapter;
    _setActiveSentenceAndParagraph(initialSentenceIndex);
    notifyListeners();
  }

  /// Aktif bölümü değiştirir
  Future<void> selectChapter(
    int chapterIndex, {
    int startSentenceIndex = 0,
    bool autoPlay = false,
  }) async {
    if (_currentBook == null ||
        chapterIndex < 0 ||
        chapterIndex >= _currentBook!.chapters.length) {
      return;
    }

    final bool wasPlaying = _isPlaying;
    await pause();
    await _clearPrefetchCache();

    _currentChapterIndex = chapterIndex;
    _setActiveSentenceAndParagraph(startSentenceIndex);
    notifyListeners();

    if (autoPlay || wasPlaying) {
      await play();
    }
  }

  /// Kullanıcı ekrandaki herhangi bir cümleye dokunduğunda seslendirmeyi doğrudan o cümleden başlatır
  Future<void> jumpToSentence(int sentenceIndex, {bool autoPlay = true}) async {
    final BookChapter? chapter = currentChapter;
    if (chapter == null ||
        sentenceIndex < 0 ||
        sentenceIndex >= chapter.ttsSentences.length) {
      return;
    }

    _playbackSessionToken++;
    await _audioPlayer.stop();
    await _flutterTts.stop();

    _setActiveSentenceAndParagraph(sentenceIndex);
    notifyListeners();

    if (autoPlay) {
      await play();
    }
  }

  /// Seslendirmeyi başlatır veya kaldığı cümleden devam ettirir
  Future<void> play() async {
    final BookChapter? chapter = currentChapter;
    if (chapter == null || chapter.ttsSentences.isEmpty) return;

    if (_isPlaying) return;
    _isPlaying = true;

    if (activeSentenceIndex.value < 0 ||
        activeSentenceIndex.value >= chapter.ttsSentences.length) {
      _setActiveSentenceAndParagraph(0);
    }

    final int currentSession = ++_playbackSessionToken;
    notifyListeners();
    onPlaybackStateChangedForService?.call();

    unawaited(_runPlaybackLoop(currentSession));
  }

  /// Seslendirmeyi duraklatır
  Future<void> pause() async {
    if (!_isPlaying) return;
    _isPlaying = false;
    _isSynthesizing = false;
    _playbackSessionToken++;

    await _audioPlayer.pause();
    await _flutterTts.stop();

    notifyListeners();
    onPlaybackStateChangedForService?.call();
  }

  /// Seslendirmeyi tamamen durdurur ve önbelleği temizler
  Future<void> stop() async {
    _isPlaying = false;
    _isSynthesizing = false;
    _playbackSessionToken++;

    await _audioPlayer.stop();
    await _flutterTts.stop();
    await _clearPrefetchCache();

    notifyListeners();
    onPlaybackStateChangedForService?.call();
  }

  /// Bir sonraki cümleye (veya15 sn ileri tuşu tetiklendiğinde sonraki cümleye) atlar
  Future<void> nextSentence() async {
    final BookChapter? chapter = currentChapter;
    if (chapter == null) return;

    final int nextIdx = activeSentenceIndex.value + 1;
    if (nextIdx < chapter.ttsSentences.length) {
      await jumpToSentence(nextIdx, autoPlay: _isPlaying);
    } else {
      await nextChapter(autoPlay: _isPlaying);
    }
  }

  /// Bir önceki cümleye (veya 15 sn geri tuşu tetiklendiğinde önceki cümleye) atlar
  Future<void> previousSentence() async {
    final BookChapter? chapter = currentChapter;
    if (chapter == null) return;

    final int prevIdx = (activeSentenceIndex.value - 1).clamp(
      0,
      chapter.ttsSentences.isEmpty ? 0 : chapter.ttsSentences.length - 1,
    );
    await jumpToSentence(prevIdx, autoPlay: _isPlaying);
  }

  /// Sonraki dahil edilmiş (filtrelenmemiş) bölüme geçer
  Future<void> nextChapter({bool autoPlay = true}) async {
    if (_currentBook == null) return;
    for (int i = _currentChapterIndex + 1;
        i < _currentBook!.chapters.length;
        i++) {
      if (_currentBook!.chapters[i].isIncluded) {
        await selectChapter(i, startSentenceIndex: 0, autoPlay: autoPlay);
        return;
      }
    }
    await pause();
  }

  /// Önceki dahil edilmiş bölüme geçer
  Future<void> previousChapter({bool autoPlay = true}) async {
    if (_currentBook == null) return;
    for (int i = _currentChapterIndex - 1; i >= 0; i--) {
      if (_currentBook!.chapters[i].isIncluded) {
        await selectChapter(i, startSentenceIndex: 0, autoPlay: autoPlay);
        return;
      }
    }
  }

  /// Seslendirmen seçimini değiştirir (`tr-TR-AhmetNeural` veya `tr-TR-EmelNeural`)
  Future<void> setNeuralVoice(TurkishNeuralVoice voice) async {
    if (_selectedVoice == voice) return;
    _selectedVoice = voice;
    final bool wasPlaying = _isPlaying;
    await pause();
    await _clearPrefetchCache();
    notifyListeners();
    if (wasPlaying) {
      await play();
    }
  }

  /// Okuma hızını değiştirir (0.75x - 2.0x arası; SSML `<prosody rate="-20%..+100%">`)
  Future<void> setSpeedMultiplier(double newSpeed) async {
    final double clamped = newSpeed.clamp(0.75, 2.0);
    if ((_speedMultiplier - clamped).abs() < 0.01) return;

    _speedMultiplier = clamped;
    await _flutterTts.setSpeechRate(_mapSpeedToFlutterTts(_speedMultiplier));

    final bool wasPlaying = _isPlaying;
    await pause();
    await _clearPrefetchCache();
    notifyListeners();
    if (wasPlaying) {
      await play();
    }
  }

  /// Faz 5 Uyku Zamanlayıcısı (fade-out) için ana ses seviyesini ayarlar (0.0 - 1.0)
  Future<void> setMasterVolume(double newVolume) async {
    _volume = newVolume.clamp(0.0, 1.0);
    await _audioPlayer.setVolume(_volume);
    await _flutterTts.setVolume(_volume);
    notifyListeners();
  }

  /// Kullanıcı isterse çevrimdışı modu manuel de zorlayabilir
  void setForceOfflineMode(bool forceOffline) {
    _forceOfflineMode = forceOffline;
    _activeEngine = forceOffline
        ? ActiveTtsEngine.androidLocalOffline
        : ActiveTtsEngine.edgeNeuralOnline;
    notifyListeners();
  }

  // --- ÇEKİRDEK OYNATMA VE LOOK-AHEAD BUFFER (N+1, N+2) DÖNGÜSÜ ---

  Future<void> _runPlaybackLoop(int sessionToken) async {
    while (_isPlaying && sessionToken == _playbackSessionToken) {
      final BookChapter? chapter = currentChapter;
      if (chapter == null || chapter.ttsSentences.isEmpty) {
        await pause();
        return;
      }

      final int currentIndex = activeSentenceIndex.value;
      if (currentIndex < 0 || currentIndex >= chapter.ttsSentences.length) {
        break;
      }

      final TtsSentence currentSentence = chapter.ttsSentences[currentIndex];
      _setActiveSentenceAndParagraph(currentIndex);
      onPlaybackStateChangedForService?.call();

      // 3. KURAL: Sıfır Gecikmeli Önbellekleme (Look-ahead Buffer / Pre-fetching)
      // N. cümle çalarken N+1 ve N+2 numaralı cümleleri arka planda indirip temp dizinde hazır tut!
      if (!_forceOfflineMode) {
        _prefetchSentenceIfNeeded(chapter, currentIndex);
        _prefetchSentenceIfNeeded(chapter, currentIndex + 1);
        _prefetchSentenceIfNeeded(chapter, currentIndex + 2);
        _cleanupOldCachedFiles(beforeIndex: currentIndex - 2);
      }

      bool playedWithEdgeNeural = false;

      // 1. BİRİNCİL MOTOR: Microsoft Edge Neural TTS
      if (!_forceOfflineMode) {
        try {
          _isSynthesizing = !_resolvedCacheFiles.containsKey(currentIndex);
          notifyListeners();

          final File? mp3File =
              await _prefetchSentenceIfNeeded(chapter, currentIndex);

          if (!_isPlaying || sessionToken != _playbackSessionToken) return;

          if (mp3File != null && await mp3File.exists()) {
            _activeEngine = ActiveTtsEngine.edgeNeuralOnline;
            _isSynthesizing = false;
            notifyListeners();

            await _audioPlayer.setVolume(_volume);
            await _audioPlayer.setFilePath(mp3File.path);
            await _audioPlayer.play();

            // Parça bitene kadar veya duraklatılana kadar bekle
            await _audioPlayer.processingStateStream.firstWhere(
              (state) =>
                  state == ProcessingState.completed ||
                  state == ProcessingState.idle,
            );
            playedWithEdgeNeural = true;
          }
        } catch (_) {
          // WebSocket veya internet hatası: Kullanıcıya hissettirmeden yedek motora düş
          playedWithEdgeNeural = false;
        }
      }

      if (!_isPlaying || sessionToken != _playbackSessionToken) return;

      // 2. İKİNCİL / YEDEK MOTOR: Android Yerel TTS (`flutter_tts`)
      if (!playedWithEdgeNeural) {
        _activeEngine = ActiveTtsEngine.androidLocalOffline;
        _isSynthesizing = false;
        notifyListeners();

        await _speakWithOfflineFlutterTts(
          currentSentence.text,
          sessionToken: sessionToken,
        );
      }

      if (!_isPlaying || sessionToken != _playbackSessionToken) return;

      // Sonraki cümleye geç veya bölüm sonunu yönet
      final int nextIdx = currentIndex + 1;
      if (nextIdx < chapter.ttsSentences.length) {
        _setActiveSentenceAndParagraph(nextIdx);
      } else {
        // Bölüm bitti! Faz 5 "Mevcut Bölüm Bitince Durdur" uyku sayacı kontrolü
        final bool shouldStop =
            onChapterFinishedShouldStop?.call() ?? false;
        if (shouldStop) {
          await pause();
          return;
        }

        // Sonraki dahil edilmiş bölüme otomatik geç
        final int nextChapIdx = _findNextIncludedChapterIndex();
        if (nextChapIdx != -1) {
          await _clearPrefetchCache();
          _currentChapterIndex = nextChapIdx;
          _setActiveSentenceAndParagraph(0);
          notifyListeners();
        } else {
          // Kitap tamamlandı
          await pause();
          return;
        }
      }
    }
  }

  /// `sentenceIndex` için MP3 indirme görevi başlatır veya zaten kuyruktaysa mevcut Future'ı döner.
  Future<File?> _prefetchSentenceIfNeeded(
    BookChapter chapter,
    int sentenceIndex,
  ) {
    if (sentenceIndex < 0 || sentenceIndex >= chapter.ttsSentences.length) {
      return Future.value(null);
    }

    if (_resolvedCacheFiles.containsKey(sentenceIndex)) {
      return Future.value(_resolvedCacheFiles[sentenceIndex]);
    }

    if (_prefetchQueue.containsKey(sentenceIndex)) {
      return _prefetchQueue[sentenceIndex]!;
    }

    final String text = chapter.ttsSentences[sentenceIndex].text;
    final String cacheKey =
        'b_${_currentBook?.id ?? "book"}_c_${chapter.index}_s_${sentenceIndex}_${_selectedVoice.name}_${(_speedMultiplier * 100).round()}';

    final Future<File?> task = _edgeClient
        .synthesizeToTempMp3(
          sentenceText: text,
          voice: _selectedVoice,
          speedMultiplier: _speedMultiplier,
          cacheKey: cacheKey,
        )
        .then<File?>((File file) {
          _resolvedCacheFiles[sentenceIndex] = file;
          return file;
        })
        .catchError((Object _) {
          _prefetchQueue.remove(sentenceIndex);
          return null;
        });

    _prefetchQueue[sentenceIndex] = task;
    return task;
  }

  /// Çevrimdışı yedek motor (`flutter_tts`) ile cümleyi okur ve bitmesini bekler.
  Future<void> _speakWithOfflineFlutterTts(
    String text, {
    required int sessionToken,
  }) async {
    _localTtsCompleter = Completer<void>();
    await _flutterTts.setVolume(_volume);
    await _flutterTts.setSpeechRate(_mapSpeedToFlutterTts(_speedMultiplier));
    await _flutterTts.speak(text);

    // Maksimum bekleme süresi ile kilitlenmeyi önle
    await _localTtsCompleter!.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {},
    );
  }

  void _setActiveSentenceAndParagraph(int sentenceIdx) {
    final BookChapter? chapter = currentChapter;
    if (chapter == null || chapter.ttsSentences.isEmpty) {
      activeSentenceIndex.value = -1;
      activeParagraphIndex.value = -1;
      return;
    }

    final int clamped =
        sentenceIdx.clamp(0, chapter.ttsSentences.length - 1);
    activeSentenceIndex.value = clamped;
    activeParagraphIndex.value = chapter.ttsSentences[clamped].paragraphIndex;
  }

  int _findNextIncludedChapterIndex() {
    if (_currentBook == null) return -1;
    for (int i = _currentChapterIndex + 1;
        i < _currentBook!.chapters.length;
        i++) {
      if (_currentBook!.chapters[i].isIncluded) {
        return i;
      }
    }
    return -1;
  }

  void _cleanupOldCachedFiles({required int beforeIndex}) {
    final List<int> keysToRemove = _resolvedCacheFiles.keys
        .where((k) => k < beforeIndex)
        .toList();
    for (final key in keysToRemove) {
      final File? file = _resolvedCacheFiles.remove(key);
      _prefetchQueue.remove(key);
      if (file != null) {
        unawaited(file.delete().catchError((_) => file));
      }
    }
    final BookChapter? chapter = currentChapter;
    if (_currentBook != null && chapter != null && beforeIndex > 0) {
      unawaited(
        AutoCacheCleaner.cleanPassedSentenceFiles(
          bookId: _currentBook!.id,
          chapterIndex: chapter.index,
          keepFromSentenceIndex: beforeIndex,
        ),
      );
    }
  }

  Future<void> _clearPrefetchCache() async {
    _prefetchQueue.clear();
    final List<File> files = _resolvedCacheFiles.values.toList();
    _resolvedCacheFiles.clear();
    for (final file in files) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  double _mapSpeedToFlutterTts(double multiplier) {
    // flutter_tts'de 0.5 normal hızdır; 0.75x - 2.0x aralığını 0.38 - 0.95 aralığına eşleriz
    return (multiplier * 0.5).clamp(0.35, 1.0);
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _flutterTts.stop();
    activeSentenceIndex.dispose();
    activeParagraphIndex.dispose();
    super.dispose();
  }
}
