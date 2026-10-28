import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/book_models.dart';
import 'hybrid_tts_controller.dart';
import 'reading_progress_storage.dart';

/// Uyku Zamanlayıcısı Seçenekleri
enum SleepTimerPreset {
  off(minutes: 0, label: 'Kapalı'),
  min15(minutes: 15, label: '15 Dakika'),
  min30(minutes: 30, label: '30 Dakika'),
  min45(minutes: 45, label: '45 Dakika'),
  min60(minutes: 60, label: '60 Dakika'),
  endOfChapter(minutes: -1, label: 'Bölüm Sonunda Durdur');

  final int minutes;
  final String label;

  const SleepTimerPreset({
    required this.minutes,
    required this.label,
  });
}

/// Yumuşak Geçişli (Son 15 Saniye Fade-Out) Akıllı Uyku Zamanlayıcısı Servisi.
/// Süre bittiğinde sesi aniden kesmez, son 15 saniyede her saniye kademeli olarak kısar,
/// oynatmayı durdurur ve kalınan cümle/sayfa indeksini `shared_preferences` ile kaydeder.
class SleepTimerService extends ChangeNotifier {
  static const int fadeOutDurationSeconds = 15;

  final HybridTtsController ttsController;

  Timer? _countdownTimer;
  SleepTimerPreset _activePreset = SleepTimerPreset.off;
  int _remainingSeconds = 0;
  bool _isFadingOut = false;

  SleepTimerService({required this.ttsController}) {
    // "Bölüm Sonunda Durdur" seçeneği için HybridTtsController kancasını bağla
    ttsController.onChapterFinishedShouldStop = _handleChapterFinished;
  }

  SleepTimerPreset get activePreset => _activePreset;
  int get remainingSeconds => _remainingSeconds;
  bool get isActive => _activePreset != SleepTimerPreset.off;
  bool get isStopAtEndOfChapter =>
      _activePreset == SleepTimerPreset.endOfChapter;
  bool get isFadingOut => _isFadingOut;

  /// Ekranda gösterilecek canlı geri sayım metni (Örn: "14:52" veya "Bölüm Sonu")
  String get formattedCountdown {
    if (_activePreset == SleepTimerPreset.off) return '';
    if (_activePreset == SleepTimerPreset.endOfChapter) {
      return 'Bölüm Sonu';
    }
    final int mins = _remainingSeconds ~/ 60;
    final int secs = _remainingSeconds % 60;
    final String minStr = mins.toString().padLeft(2, '0');
    final String secStr = secs.toString().padLeft(2, '0');
    return '$minStr:$secStr';
  }

  /// Uyku zamanlayıcısını seçilen moda göre başlatır veya iptal eder
  Future<void> startTimer(SleepTimerPreset preset) async {
    _countdownTimer?.cancel();
    _activePreset = preset;
    _isFadingOut = false;

    // Önceki bir fade-out yarıda kaldıysa sesi tekrar %100'e çıkar
    await ttsController.setMasterVolume(1.0);

    if (preset == SleepTimerPreset.off) {
      _remainingSeconds = 0;
      notifyListeners();
      return;
    }

    if (preset == SleepTimerPreset.endOfChapter) {
      _remainingSeconds = 0;
      notifyListeners();
      return;
    }

    _remainingSeconds = preset.minutes * 60;
    notifyListeners();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_remainingSeconds > 0) {
        _remainingSeconds--;

        // Süre bitimine son 15 saniye kala sesi her saniye kademeli olarak kıs (Fade-out)
        if (_remainingSeconds <= fadeOutDurationSeconds &&
            _remainingSeconds > 0) {
          _isFadingOut = true;
          final double targetVolume =
              (_remainingSeconds / fadeOutDurationSeconds).clamp(0.05, 1.0);
          await ttsController.setMasterVolume(targetVolume);
        }

        notifyListeners();
      } else {
        // Süre bitti: Oynatmayı durdur, kalınan cümle/sayfa indeksini kaydet ve sesi sıfırla
        timer.cancel();
        await _completeSleepTimerAndSaveProgress();
      }
    });
  }

  /// Zamanlayıcıyı iptal eder ve sesi normal seviyesine döndürür
  Future<void> cancelTimer() async {
    await startTimer(SleepTimerPreset.off);
  }

  /// Bölüm bittiğinde "Bölüm Sonunda Durdur" aktifse tetiklenir
  bool _handleChapterFinished() {
    if (_activePreset == SleepTimerPreset.endOfChapter) {
      unawaited(_completeSleepTimerAndSaveProgress());
      return true;
    }
    return false;
  }

  /// Süre dolduğunda oynatmayı durdurur, tam olarak kalınan cümle/sayfa indeksini
  /// `shared_preferences` ile kalıcı hafızaya kaydeder ve sesi sonraki dinleme için 1.0 yapar.
  Future<void> _completeSleepTimerAndSaveProgress() async {
    _countdownTimer?.cancel();
    _activePreset = SleepTimerPreset.off;
    _remainingSeconds = 0;
    _isFadingOut = false;

    // 1. Oynatmayı durdur
    await ttsController.pause();

    // 2. Kalınan cümle, bölüm ve sayfa indeksini kalıcı hafızaya (`shared_preferences`) kaydet
    final ParsedBook? book = ttsController.currentBook;
    final BookChapter? chapter = ttsController.currentChapter;
    if (book != null && chapter != null) {
      await ReadingProgressStorage.savePosition(
        bookId: book.id,
        bookTitle: book.title,
        chapterIndex: ttsController.currentChapterIndex,
        sentenceIndex: ttsController.activeSentenceIndex.value.clamp(0, 999999),
        paragraphIndex:
            ttsController.activeParagraphIndex.value.clamp(0, 999999),
        pageNumber: chapter.startPage,
      );
    }

    // 3. Kullanıcı tekrar "Oynat" dediğinde sesin kısık kalmaması için ses seviyesini 1.0'a geri hazırla
    await ttsController.setMasterVolume(1.0);
    notifyListeners();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }
}
