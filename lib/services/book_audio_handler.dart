import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import '../models/book_models.dart';
import 'hybrid_tts_controller.dart';
import 'reading_progress_storage.dart';

/// Android kilit ekranı, bildirim çubuğu ve kulaklık tuşları (MediaButton) ile
/// arka planda kesintisiz sesli kitap oynatımını yöneten `BaseAudioHandler` sınıfı.
class BookAudioHandler extends BaseAudioHandler with SeekHandler {
  final HybridTtsController ttsController;

  BookAudioHandler({required this.ttsController}) {
    _initAudioSession();
    // TTS kontrolcüsündeki her cümle/bölüm/oynatma değişiminde bildirim çubuğunu güncelle
    ttsController.onPlaybackStateChangedForService = _broadcastState;
    ttsController.activeSentenceIndex.addListener(_onSentenceChanged);
    _broadcastState();
  }

  /// `audio_session` ile telefon çalması, bildirim veya kulaklık çekilmesi durumlarını yönetir
  Future<void> _initAudioSession() async {
    try {
      final AudioSession session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());

      // Kulaklık çıkarıldığında sesi otomatik duraklat
      session.becomingNoisyEventStream.listen((_) {
        pause();
      });

      // Telefon araması veya başka bir medya araya girdiğinde yönet
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          pause();
        }
      });
    } catch (_) {}
  }

  void _onSentenceChanged() {
    _broadcastState();
    _persistCurrentProgress();
  }

  /// Her cümle değişiminde ve duraklatmada kalınan yeri `shared_preferences`'a kaydeder
  Future<void> _persistCurrentProgress() async {
    final ParsedBook? book = ttsController.currentBook;
    final BookChapter? chapter = ttsController.currentChapter;
    if (book == null || chapter == null) return;

    final int sentenceIdx =
        ttsController.activeSentenceIndex.value.clamp(0, 999999);
    final int paragraphIdx =
        ttsController.activeParagraphIndex.value.clamp(0, 999999);

    await ReadingProgressStorage.savePosition(
      bookId: book.id,
      bookTitle: book.title,
      chapterIndex: ttsController.currentChapterIndex,
      sentenceIndex: sentenceIdx,
      paragraphIndex: paragraphIdx,
      pageNumber: chapter.startPage,
    );
  }

  /// Kilit ekranı ve bildirim çubuğuna Kitap Adı, Bölüm Başlığı ve Medya Tuşlarını yayınlar
  void _broadcastState() {
    final ParsedBook? book = ttsController.currentBook;
    final BookChapter? chapter = ttsController.currentChapter;
    final bool playing = ttsController.isPlaying;

    final int totalSentences = chapter?.ttsSentences.length ?? 1;
    final int currentSentence =
        (ttsController.activeSentenceIndex.value + 1).clamp(0, totalSentences);

    // 1. Kilit Ekranında Kitap Adı ve Mevcut Bölüm Başlığı
    mediaItem.add(
      MediaItem(
        id: '${book?.id ?? "book"}_${chapter?.index ?? 0}',
        album: book?.title ?? 'Hibrit Sesli Kitap',
        title: chapter?.title ?? 'Bölüm Seçilmedi',
        artist: book?.author ?? 'Kişisel Hibrit Kitap Asistanı',
        // Cümle ilerlemesini kilit ekranı çubuğunda saniye cinsinden simüle et
        duration: Duration(seconds: totalSentences * 5),
        extras: {
          'chapterIndex': ttsController.currentChapterIndex,
          'sentenceIndex': ttsController.activeSentenceIndex.value,
        },
      ),
    );

    // 2. Kilit Ekranı ve Bildirim Çubuğu Medya Kontrolleri:
    // [0]: Önceki Cümle / 15 sn Geri
    // [1]: Oynat / Duraklat
    // [2]: Sonraki Cümle / 15 sn İleri
    // [3]: Sonraki Bölüm
    playbackState.add(
      PlaybackState(
        controls: [
          const MediaControl(
            androidIcon: 'drawable/ic_action_rewind',
            label: 'Önceki Cümle / 15 sn Geri',
            action: MediaAction.rewind,
          ),
          if (playing)
            MediaControl.pause
          else
            MediaControl.play,
          const MediaControl(
            androidIcon: 'drawable/ic_action_fast_forward',
            label: 'Sonraki Cümle / 15 sn İleri',
            action: MediaAction.fastForward,
          ),
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.rewind,
          MediaAction.fastForward,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.playPause,
        },
        // Bildirim çubuğu daraltıldığında görünecek ilk 3 buton: Geri, Oynat/Duraklat, İleri
        androidCompactActionIndices: const [0, 1, 2],
        processingState: ttsController.isSynthesizing
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: playing,
        updatePosition: Duration(seconds: currentSentence * 5),
        speed: ttsController.speedMultiplier,
      ),
    );
  }

  // --- MEDYA TUŞU AKSİYONLARI ---

  @override
  Future<void> play() async {
    await ttsController.play();
    _broadcastState();
  }

  @override
  Future<void> pause() async {
    await ttsController.pause();
    await _persistCurrentProgress();
    _broadcastState();
  }

  @override
  Future<void> stop() async {
    await _persistCurrentProgress();
    await ttsController.stop();
    _broadcastState();
    await super.stop();
  }

  /// "Sonraki Cümle / 15 sn İleri" tuşu (yaklaşık 2 cümle ileri atlar)
  @override
  Future<void> fastForward() async {
    final BookChapter? chapter = ttsController.currentChapter;
    if (chapter == null) return;
    final int target = (ttsController.activeSentenceIndex.value + 2).clamp(
      0,
      chapter.ttsSentences.length - 1,
    );
    await ttsController.jumpToSentence(target, autoPlay: ttsController.isPlaying);
    _broadcastState();
  }

  /// "Önceki Cümle / 15 sn Geri" tuşu (yaklaşık 2 cümle geri atlar)
  @override
  Future<void> rewind() async {
    final BookChapter? chapter = ttsController.currentChapter;
    if (chapter == null) return;
    final int target = (ttsController.activeSentenceIndex.value - 2).clamp(
      0,
      chapter.ttsSentences.length - 1,
    );
    await ttsController.jumpToSentence(target, autoPlay: ttsController.isPlaying);
    _broadcastState();
  }

  /// "Sonraki Bölüm" tuşu
  @override
  Future<void> skipToNext() async {
    await ttsController.nextChapter(autoPlay: ttsController.isPlaying);
    _broadcastState();
  }

  /// "Önceki Bölüm" tuşu
  @override
  Future<void> skipToPrevious() async {
    await ttsController.previousChapter(autoPlay: ttsController.isPlaying);
    _broadcastState();
  }

  /// Kulaklık tuşları (MediaButton) ile başlatma / duraklatma / ileri / geri
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (ttsController.isPlaying) {
          await pause();
        } else {
          await play();
        }
        break;
      case MediaButton.next:
        await fastForward();
        break;
      case MediaButton.previous:
        await rewind();
        break;
    }
  }
}
