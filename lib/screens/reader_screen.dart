import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/book_models.dart';
import '../services/edge_tts_client.dart';
import '../services/file_manager_service.dart';
import '../services/hybrid_tts_controller.dart';
import '../services/reading_progress_storage.dart';
import '../services/sleep_timer_service.dart';

/// 4 Özel Göz Konforu Tema Seçeneği:
/// ☀️ Gündüz, 📜 Sepya / Sıcak Kâğıt, 🌑 Gece, 🖤 Tam Siyah AMOLED
enum ReaderThemeMode {
  day(
    key: 'day',
    emoji: '☀️',
    label: 'Gündüz',
    subtitle: 'Klasik Beyaz',
    backgroundColor: Color(0xFFFAF9F6),
    textColor: Color(0xFF1F2937),
    sentenceHighlightColor: Color(0xFFFFE082),
    paragraphCardColor: Color(0xFFFFFFFF),
    floatingBarColor: Color(0xF5FFFFFF),
  ),
  sepia(
    key: 'sepia',
    emoji: '📜',
    label: 'Sepya',
    subtitle: 'Sıcak Kâğıt',
    backgroundColor: Color(0xFFF4ECD8),
    textColor: Color(0xFF3E2723),
    sentenceHighlightColor: Color(0xFFFFCC80),
    paragraphCardColor: Color(0xFFFAF3E3),
    floatingBarColor: Color(0xF5FAF3E3),
  ),
  night(
    key: 'night',
    emoji: '🌑',
    label: 'Gece',
    subtitle: 'Koyu Lacivert',
    backgroundColor: Color(0xFF12161F),
    textColor: Color(0xFFE5E7EB),
    sentenceHighlightColor: Color(0xFF3730A3),
    paragraphCardColor: Color(0xFF1E2433),
    floatingBarColor: Color(0xF21E2433),
  ),
  amoled(
    key: 'amoled',
    emoji: '🖤',
    label: 'AMOLED',
    subtitle: 'Tam Siyah (#000)',
    backgroundColor: Color(0xFF000000),
    textColor: Color(0xFFBDBDBD),
    sentenceHighlightColor: Color(0xFF1E3A8A),
    paragraphCardColor: Color(0xFF0A0A0A),
    floatingBarColor: Color(0xF5121212),
  );

  final String key;
  final String emoji;
  final String label;
  final String subtitle;
  final Color backgroundColor;
  final Color textColor;
  final Color sentenceHighlightColor;
  final Color paragraphCardColor;
  final Color floatingBarColor;

  const ReaderThemeMode({
    required this.key,
    required this.emoji,
    required this.label,
    required this.subtitle,
    required this.backgroundColor,
    required this.textColor,
    required this.sentenceHighlightColor,
    required this.paragraphCardColor,
    required this.floatingBarColor,
  });

  static ReaderThemeMode fromKey(String key) {
    return ReaderThemeMode.values.firstWhere(
      (e) => e.key == key,
      orElse: () => ReaderThemeMode.sepia,
    );
  }
}

class ReaderScreen extends StatefulWidget {
  final double initialScrollOffset;

  const ReaderScreen({
    super.key,
    this.initialScrollOffset = 0.0,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final ScrollController _scrollController;

  // Tipografi ve Tema Ayarları
  ReaderThemeMode _readerTheme = ReaderThemeMode.sepia;
  double _fontSize = 18.5;
  double _lineHeight = 1.60;
  double _horizontalPadding = 18.0;

  // 1. Akıllı Odak ve Tam Ekran Modu (Immersive Mode)
  bool _isImmersiveFullScreen = false;

  // 3. Kullanıcı Manuel Kaydırdığında Otomatik Takibi Duraklatma ("🎯 Okunan Yere Dön")
  bool _userDetachedAutoScroll = false;

  /// Her cümlenin ekrana çizildiği widget için GlobalKey (Scrollable.ensureVisible için)
  final Map<int, GlobalKey> _sentenceKeys = {};
  int _lastScrolledSentenceIndex = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    );

    _loadSavedUserPreferences();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tts = context.read<HybridTtsController>();
      tts.activeSentenceIndex.addListener(_onActiveSentenceChanged);
      // Açılışta aktif cümleye yumuşakça odaklan
      if (widget.initialScrollOffset <= 0) {
        _scrollToActiveSentence(force: true);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persistEverything();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    context
        .read<HybridTtsController>()
        .activeSentenceIndex
        .removeListener(_onActiveSentenceChanged);
    _scrollController.dispose();
    super.dispose();
  }

  /// Uygulama arka plana atıldığında veya kapatıldığında milimetrik durumu kaydet
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _persistEverything();
    }
  }

  Future<void> _loadSavedUserPreferences() async {
    final prefs = await ReadingProgressStorage.loadUserPreferences();
    if (!mounted) return;
    final tts = context.read<HybridTtsController>();

    setState(() {
      _readerTheme = ReaderThemeMode.fromKey(prefs.themeKey);
      _fontSize = prefs.fontSize.clamp(14.0, 28.0);
      _lineHeight = prefs.lineHeight.clamp(1.25, 2.10);
      _horizontalPadding = prefs.horizontalPadding.clamp(10.0, 36.0);
    });

    final voice = prefs.voiceName == 'emel'
        ? TurkishNeuralVoice.emel
        : TurkishNeuralVoice.ahmet;
    await tts.setNeuralVoice(voice);
    await tts.setSpeedMultiplier(prefs.speedMultiplier);
  }

  Future<void> _saveUserPreferences() async {
    final tts = context.read<HybridTtsController>();
    await ReadingProgressStorage.saveUserPreferences(
      UserReaderPreferences(
        themeKey: _readerTheme.key,
        fontSize: _fontSize,
        lineHeight: _lineHeight,
        horizontalPadding: _horizontalPadding,
        voiceName: tts.selectedVoice == TurkishNeuralVoice.emel
            ? 'emel'
            : 'ahmet',
        speedMultiplier: tts.speedMultiplier,
      ),
    );
  }

  /// Her cümle geçişinde ve ekran kapanışında milimetrik ilerlemeyi kaydet
  Future<void> _persistEverything() async {
    if (!mounted) return;
    final tts = context.read<HybridTtsController>();
    final ParsedBook? book = tts.currentBook;
    if (book == null) return;

    final double scrollPos =
        _scrollController.hasClients ? _scrollController.offset : 0.0;

    await ReadingProgressStorage.saveFullBookState(
      book: book,
      chapterIndex: tts.currentChapterIndex,
      sentenceIndex: tts.activeSentenceIndex.value.clamp(0, 999999),
      paragraphIndex: tts.activeParagraphIndex.value.clamp(0, 999999),
      scrollPosition: scrollPos,
    );
  }

  /// Tam Ekran Saf Okuma Modunu (Immersive Mode) açar/kapatır
  void _toggleImmersiveMode() {
    setState(() {
      _isImmersiveFullScreen = !_isImmersiveFullScreen;
    });
    if (_isImmersiveFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  /// Aktif cümle değiştiğinde çalışır:
  /// Eğer kullanıcı sayfayı manuel olarak başka yere kaydırmadıysa otomatik kaydırır
  void _onActiveSentenceChanged() {
    if (!mounted) return;
    _persistEverything();

    if (_userDetachedAutoScroll) {
      // Kullanıcı kendisi başka bir yeri okuyorsa otomatik kaydırma ile rahatsız etme!
      return;
    }
    _scrollToActiveSentence(force: false);
  }

  void _scrollToActiveSentence({required bool force}) {
    if (!mounted) return;
    final int activeIdx =
        context.read<HybridTtsController>().activeSentenceIndex.value;
    if (activeIdx < 0) return;
    if (!force && activeIdx == _lastScrolledSentenceIndex) return;

    _lastScrolledSentenceIndex = activeIdx;
    final GlobalKey? targetKey = _sentenceKeys[activeIdx];
    final BuildContext? targetContext = targetKey?.currentContext;

    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeInOutCubic,
        alignment: 0.34,
      );
    }
  }

  GlobalKey _getKeyForSentence(int sentenceIndex) {
    return _sentenceKeys.putIfAbsent(sentenceIndex, () => GlobalKey());
  }

  @override
  Widget build(BuildContext context) {
    final tts = context.watch<HybridTtsController>();
    final sleepTimer = context.watch<SleepTimerService>();
    final ParsedBook? book = tts.currentBook;
    final BookChapter? chapter = tts.currentChapter;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: _readerTheme.backgroundColor,
      drawer: _buildChaptersDrawer(context, tts, book),
      body: chapter == null || book == null
          ? Center(
              child: Text(
                'Kitap bulunamadı.',
                style: TextStyle(color: _readerTheme.textColor),
              ),
            )
          : Stack(
              children: [
                // 1. ANA OKUMA METNİ (Boş yere dokununca Tam Ekran Modu açılır/kapanır)
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleImmersiveMode,
                  child: NotificationListener<UserScrollNotification>(
                    onNotification: (notification) {
                      // Kullanıcı parmağıyla kaydırdığında otomatik takibi duraklat
                      // ve "🎯 Okunan Yere Dön" butonunu göster
                      if (notification.direction != ScrollDirection.idle &&
                          !_userDetachedAutoScroll) {
                        setState(() {
                          _userDetachedAutoScroll = true;
                        });
                      }
                      return false;
                    },
                    child: _buildSynchronizedReaderList(tts, chapter),
                  ),
                ),

                // 2. ÜST BAR (AppBar): Tam Ekran Modunda yumuşak animasyonla yukarı gizlenir
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    offset: _isImmersiveFullScreen
                        ? const Offset(0, -1.2)
                        : Offset.zero,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 220),
                      opacity: _isImmersiveFullScreen ? 0.0 : 1.0,
                      child: _buildFloatingTopBar(
                        context,
                        tts,
                        sleepTimer,
                        book,
                        chapter,
                      ),
                    ),
                  ),
                ),

                // 3. "🎯 Okunan Yere Dön" Butonu (Kullanıcı manuel kaydırdığında sağ altta belirir)
                if (_userDetachedAutoScroll)
                  Positioned(
                    right: 18,
                    bottom: _isImmersiveFullScreen ? 28 : 132,
                    child: FloatingActionButton.extended(
                      heroTag: 'return_to_active_sentence_btn',
                      backgroundColor: Colors.indigoAccent,
                      foregroundColor: Colors.white,
                      elevation: 6,
                      onPressed: () {
                        setState(() {
                          _userDetachedAutoScroll = false;
                        });
                        _scrollToActiveSentence(force: true);
                      },
                      icon: const Text('🎯', style: TextStyle(fontSize: 16)),
                      label: const Text(
                        'Okunan Yere Dön',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),

                // 4. ALTTAKİ YÜZEN SES OYNATICI (Floating Mini Player)
                // Tam ekran modunda aşağı doğru yumuşakça gizlenir
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 14,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    offset: _isImmersiveFullScreen
                        ? const Offset(0, 1.4)
                        : Offset.zero,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 220),
                      opacity: _isImmersiveFullScreen ? 0.0 : 1.0,
                      child: _buildFloatingMiniPlayer(
                        context,
                        tts,
                        sleepTimer,
                        chapter,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  /// Üstte yer alan, Tam Ekran modunda gizlenen modern kontrol çubuğu
  Widget _buildFloatingTopBar(
    BuildContext context,
    HybridTtsController tts,
    SleepTimerService sleepTimer,
    ParsedBook book,
    BookChapter chapter,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: _readerTheme.floatingBarColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              // Kitaplığa Geri Dön
              IconButton(
                tooltip: 'Kitaplığıma Dön',
                icon: Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: _readerTheme.textColor,
                  size: 20,
                ),
                onPressed: () async {
                  await _persistEverything();
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              ),
              // Hızlı Bölüm Çekmecesi (Drawer) Butonu
              IconButton(
                tooltip: 'Bölümler (Chapters)',
                icon: Icon(
                  Icons.toc_rounded,
                  color: _readerTheme.textColor,
                ),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
              // Kitap ve Bölüm Başlığı
              Expanded(
                child: GestureDetector(
                  onTap: () => _scaffoldKey.currentState?.openDrawer(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        book.title,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.bold,
                          color: _readerTheme.textColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        chapter.title,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: _readerTheme.textColor.withValues(alpha: 0.7),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
              // ✂️ Sayfa Filtrele Butonu (Önsöz / İçindekiler Atla)
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: _readerTheme.textColor,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _showPageFilterModal(context, tts, book),
                icon: const Text('✂️', style: TextStyle(fontSize: 14)),
                label: const Text(
                  'Sayfa Filtrele',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              // "Aa" Göz Konforu ve Tipografi Paneli Butonu
              IconButton(
                tooltip: 'Aa Görünüm ve Tema Ayarları',
                icon: Text(
                  'Aa',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: _readerTheme.textColor,
                  ),
                ),
                onPressed: () => _showTypographyAndThemeSheet(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Senkronize cümle vurgulamalı ve dokunulan cümleden seslendirme başlatan okuma listesi
  Widget _buildSynchronizedReaderList(
    HybridTtsController tts,
    BookChapter chapter,
  ) {
    final Map<int, List<TtsSentence>> sentencesByParagraph = {};
    for (final s in chapter.ttsSentences) {
      sentencesByParagraph.putIfAbsent(s.paragraphIndex, () => []).add(s);
    }

    return ValueListenableBuilder<int>(
      valueListenable: tts.activeSentenceIndex,
      builder: (context, activeSentenceIdx, _) {
        final int activeParagraphIdx = tts.activeParagraphIndex.value;

        return ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(
            _horizontalPadding,
            _isImmersiveFullScreen ? 44 : 104,
            _horizontalPadding,
            _isImmersiveFullScreen ? 64 : 150,
          ),
          itemCount: chapter.paragraphs.length,
          itemBuilder: (context, pIndex) {
            final List<TtsSentence> paragraphSentences =
                sentencesByParagraph[pIndex] ?? [];
            final bool isParagraphActive = pIndex == activeParagraphIdx;

            return AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: isParagraphActive
                    ? _readerTheme.paragraphCardColor
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border(
                  left: BorderSide(
                    color: isParagraphActive
                        ? Colors.indigoAccent
                        : Colors.transparent,
                    width: 3.5,
                  ),
                ),
              ),
              child: Wrap(
                spacing: 4,
                runSpacing: 5,
                children: paragraphSentences.map((ttsSentence) {
                  final bool isCurrentSentence =
                      ttsSentence.sentenceIndex == activeSentenceIdx;
                  final GlobalKey sentenceKey =
                      _getKeyForSentence(ttsSentence.sentenceIndex);

                  return GestureDetector(
                    key: sentenceKey,
                    onTap: () {
                      // Ekrandaki herhangi bir cümleye parmakla dokunulduğunda
                      // seslendirme anında o cümleden başlar ve otomatik takip aktifleşir
                      setState(() {
                        _userDetachedAutoScroll = false;
                      });
                      tts.jumpToSentence(
                        ttsSentence.sentenceIndex,
                        autoPlay: true,
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isCurrentSentence
                            ? _readerTheme.sentenceHighlightColor
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        ttsSentence.text,
                        style: TextStyle(
                          fontSize: _fontSize,
                          height: _lineHeight,
                          fontWeight: isCurrentSentence
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: _readerTheme.textColor,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            );
          },
        );
      },
    );
  }

  /// Alttaki Modern, Yuvarlatılmış Köşeli, Yüzen (Floating) Mini Ses Oynatıcı Bar
  Widget _buildFloatingMiniPlayer(
    BuildContext context,
    HybridTtsController tts,
    SleepTimerService sleepTimer,
    BookChapter chapter,
  ) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _readerTheme.floatingBarColor,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: _readerTheme.textColor.withValues(alpha: 0.12),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Üst ince bilgi ve ilerleme satırı
            ValueListenableBuilder<int>(
              valueListenable: tts.activeSentenceIndex,
              builder: (context, activeIdx, _) {
                final int total = chapter.ttsSentences.length;
                final int current = (activeIdx + 1).clamp(0, total);
                final double progress =
                    total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;

                return Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3.5,
                        backgroundColor:
                            _readerTheme.textColor.withValues(alpha: 0.12),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Cümle $current/$total • Syf. ${chapter.startPage}',
                          style: TextStyle(
                            fontSize: 11,
                            color:
                                _readerTheme.textColor.withValues(alpha: 0.75),
                          ),
                        ),
                        if (sleepTimer.isActive)
                          GestureDetector(
                            onTap: () =>
                                _showSleepTimerBottomSheet(context, sleepTimer),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: sleepTimer.isFadingOut
                                    ? Colors.deepOrange.withValues(alpha: 0.25)
                                    : Colors.indigoAccent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                sleepTimer.isFadingOut
                                    ? '🌙 Fade-Out ${sleepTimer.remainingSeconds}sn'
                                    : '🌙 ${sleepTimer.formattedCountdown}',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                  color: _readerTheme.textColor,
                                ),
                              ),
                            ),
                          )
                        else
                          Text(
                            tts.activeEngine ==
                                    ActiveTtsEngine.edgeNeuralOnline
                                ? 'Nöral Ses Aktif'
                                : 'Çevrimdışı TTS',
                            style: TextStyle(
                              fontSize: 11,
                              color: _readerTheme.textColor
                                  .withValues(alpha: 0.65),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 6),

            // Tek Bakışta Tüm Kontroller: Ses (Ahmet/Emel), 15sn Geri, Oynat/Duraklat, 15sn İleri, Hız (1.2x), Uyku
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Tek Dokunuşla Ses Seçimi (Ahmet / Emel)
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () async {
                    final nextVoice =
                        tts.selectedVoice == TurkishNeuralVoice.ahmet
                            ? TurkishNeuralVoice.emel
                            : TurkishNeuralVoice.ahmet;
                    await tts.setNeuralVoice(nextVoice);
                    await _saveUserPreferences();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _readerTheme.textColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.record_voice_over_rounded,
                          size: 14,
                          color: _readerTheme.textColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          tts.selectedVoice == TurkishNeuralVoice.ahmet
                              ? 'Ahmet'
                              : 'Emel',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _readerTheme.textColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 15 sn Geri / Oynat-Duraklat / 15 sn İleri
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '15 sn Geri (Önceki Cümle)',
                      icon: Icon(
                        Icons.replay_10_rounded,
                        color: _readerTheme.textColor,
                        size: 24,
                      ),
                      onPressed: () => tts.previousSentence(),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.indigoAccent,
                        foregroundColor: Colors.white,
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(12),
                      ),
                      onPressed: () {
                        if (tts.isPlaying) {
                          tts.pause();
                        } else {
                          tts.play();
                        }
                      },
                      child: Icon(
                        tts.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '15 sn İleri (Sonraki Cümle)',
                      icon: Icon(
                        Icons.forward_10_rounded,
                        color: _readerTheme.textColor,
                        size: 24,
                      ),
                      onPressed: () => tts.nextSentence(),
                    ),
                  ],
                ),

                // Hız Seçimi (1.0x, 1.2x, 1.5x vb.) + Uyku Zamanlayıcısı İkonu
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<double>(
                      tooltip: 'Okuma Hızı',
                      initialValue: tts.speedMultiplier,
                      onSelected: (speed) async {
                        await tts.setSpeedMultiplier(speed);
                        await _saveUserPreferences();
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 0.80, child: Text('0.8x (-20%)')),
                        PopupMenuItem(value: 0.90, child: Text('0.9x (-10%)')),
                        PopupMenuItem(value: 1.00, child: Text('1.0x (Normal)')),
                        PopupMenuItem(value: 1.20, child: Text('1.2x (+20%)')),
                        PopupMenuItem(value: 1.50, child: Text('1.5x (+50%)')),
                        PopupMenuItem(value: 1.75, child: Text('1.75x (+75%)')),
                        PopupMenuItem(value: 2.00, child: Text('2.0x (+100%)')),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: _readerTheme.textColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '${tts.speedMultiplier.toStringAsFixed(1)}x',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: _readerTheme.textColor,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Uyku Zamanlayıcısı',
                      icon: Icon(
                        sleepTimer.isActive
                            ? Icons.bedtime_rounded
                            : Icons.bedtime_outlined,
                        color: sleepTimer.isActive
                            ? Colors.amber
                            : _readerTheme.textColor,
                        size: 20,
                      ),
                      onPressed: () =>
                          _showSleepTimerBottomSheet(context, sleepTimer),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 2. GÖREV: Göz Konforu ve Tipografi Paneli ("Aa" Görünüm Ayarları BottomSheet)
  /// Yazı Boyutu, Satır Aralığı, Kenar Boşluğu ve 4 Özel Tema (☀️ Gündüz, 📜 Sepya, 🌑 Gece, 🖤 AMOLED)
  void _showTypographyAndThemeSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _readerTheme.paragraphCardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Göz Konforu ve Tipografi Ayarları',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: _readerTheme.textColor,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 4 Özel Tema Seçeneği
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.6,
                    children: ReaderThemeMode.values.map((mode) {
                      final bool isSelected = _readerTheme == mode;
                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          setState(() => _readerTheme = mode);
                          setModalState(() {});
                          _saveUserPreferences();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: mode.backgroundColor,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.indigoAccent
                                  : mode.textColor.withValues(alpha: 0.25),
                              width: isSelected ? 2.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(
                                mode.emoji,
                                style: const TextStyle(fontSize: 18),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      mode.label,
                                      style: TextStyle(
                                        color: mode.textColor,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    Text(
                                      mode.subtitle,
                                      style: TextStyle(
                                        color: mode.textColor
                                            .withValues(alpha: 0.7),
                                        fontSize: 10.5,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),

                  // 1. Yazı Boyutu Kaydırma Çubuğu
                  Row(
                    children: [
                      Icon(
                        Icons.format_size_rounded,
                        color: _readerTheme.textColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Yazı Boyutu',
                        style: TextStyle(
                          color: _readerTheme.textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _fontSize,
                          min: 14.0,
                          max: 28.0,
                          divisions: 14,
                          label: '${_fontSize.toStringAsFixed(0)} pt',
                          onChanged: (val) {
                            setState(() => _fontSize = val);
                            setModalState(() {});
                            _saveUserPreferences();
                          },
                        ),
                      ),
                      Text(
                        '${_fontSize.toStringAsFixed(0)} pt',
                        style: TextStyle(color: _readerTheme.textColor),
                      ),
                    ],
                  ),

                  // 2. Satır Aralığı Kaydırma Çubuğu
                  Row(
                    children: [
                      Icon(
                        Icons.format_line_spacing_rounded,
                        color: _readerTheme.textColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Satır Aralığı',
                        style: TextStyle(
                          color: _readerTheme.textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _lineHeight,
                          min: 1.25,
                          max: 2.10,
                          divisions: 17,
                          label: _lineHeight.toStringAsFixed(2),
                          onChanged: (val) {
                            setState(() => _lineHeight = val);
                            setModalState(() {});
                            _saveUserPreferences();
                          },
                        ),
                      ),
                      Text(
                        _lineHeight.toStringAsFixed(2),
                        style: TextStyle(color: _readerTheme.textColor),
                      ),
                    ],
                  ),

                  // 3. Kenar Boşluğu Kaydırma Çubuğu
                  Row(
                    children: [
                      Icon(
                        Icons.settings_overscan_rounded,
                        color: _readerTheme.textColor,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Kenar Boşluğu',
                        style: TextStyle(
                          color: _readerTheme.textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _horizontalPadding,
                          min: 10.0,
                          max: 36.0,
                          divisions: 13,
                          label: '${_horizontalPadding.round()} px',
                          onChanged: (val) {
                            setState(() => _horizontalPadding = val);
                            setModalState(() {});
                            _saveUserPreferences();
                          },
                        ),
                      ),
                      Text(
                        '${_horizontalPadding.round()} px',
                        style: TextStyle(color: _readerTheme.textColor),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Uyku Zamanlayıcısı (Fade-Out Sleep Timer) BottomSheet Menüsü
  void _showSleepTimerBottomSheet(
    BuildContext context,
    SleepTimerService sleepTimer,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return Consumer<SleepTimerService>(
          builder: (ctx, timerService, _) {
            final List<SleepTimerPreset> presets = [
              SleepTimerPreset.min15,
              SleepTimerPreset.min30,
              SleepTimerPreset.min45,
              SleepTimerPreset.min60,
              SleepTimerPreset.endOfChapter,
            ];

            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.bedtime_rounded, color: Colors.indigo),
                          SizedBox(width: 8),
                          Text(
                            'Akıllı Uyku Zamanlayıcısı',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      if (timerService.isActive)
                        Chip(
                          backgroundColor:
                              Colors.indigo.withValues(alpha: 0.15),
                          label: Text(
                            'Kalan: ${timerService.formattedCountdown}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Süre bitimine son 15 saniye kala ses aniden kesilmez; her saniye kademeli olarak kısılır (Fade-Out) ve kaldığınız cümle/sayfa hafızaya kaydedilir.',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey[700]),
                  ),
                  const SizedBox(height: 14),
                  ...presets.map((preset) {
                    final bool isSelected =
                        timerService.activePreset == preset;
                    return ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      selected: isSelected,
                      leading: Icon(
                        preset == SleepTimerPreset.endOfChapter
                            ? Icons.bookmark_added_rounded
                            : Icons.timer_outlined,
                      ),
                      title: Text(
                        preset.label,
                        style: TextStyle(
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: Colors.indigo)
                          : null,
                      onTap: () {
                        timerService.startTimer(preset);
                        Navigator.of(ctx).pop();
                      },
                    );
                  }),
                  if (timerService.isActive) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Zamanlayıcıyı Kapat'),
                        onPressed: () {
                          timerService.cancelTimer();
                          Navigator.of(ctx).pop();
                        },
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Hızlı Bölüm Çekmecesi (Drawer)
  Widget _buildChaptersDrawer(
    BuildContext context,
    HybridTtsController tts,
    ParsedBook? book,
  ) {
    return Drawer(
      child: SafeArea(
        child: book == null
            ? const Center(child: Text('Kitap yüklenmedi'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${book.author} • ${book.chapters.length} Bölüm',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: book.chapters.length,
                      itemBuilder: (context, idx) {
                        final ch = book.chapters[idx];
                        final bool isSelected =
                            idx == tts.currentChapterIndex;
                        final bool isCompleted = idx < tts.currentChapterIndex;

                        return ListTile(
                          selected: isSelected,
                          leading: Icon(
                            !ch.isIncluded
                                ? Icons.block_rounded
                                : isSelected
                                    ? Icons.volume_up_rounded
                                    : isCompleted
                                        ? Icons.check_circle_outline_rounded
                                        : Icons.menu_book_rounded,
                            color: !ch.isIncluded
                                ? Colors.grey
                                : isCompleted
                                    ? Colors.teal
                                    : null,
                          ),
                          title: Text(
                            ch.title,
                            style: TextStyle(
                              decoration: ch.isIncluded
                                  ? null
                                  : TextDecoration.lineThrough,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            'Sayfa ${ch.startPage}-${ch.endPage} • ${ch.ttsSentences.length} cümle',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            _sentenceKeys.clear();
                            _lastScrolledSentenceIndex = -1;
                            setState(() {
                              _userDetachedAutoScroll = false;
                            });
                            tts.selectChapter(idx, startSentenceIndex: 0);
                            _persistEverything();
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// "✂️ Sayfa Filtrele" (Başlangıç Sayfası - Bitiş Sayfası ile önsöz/içindekileri atlama) penceresi
  void _showPageFilterModal(
    BuildContext context,
    HybridTtsController tts,
    ParsedBook book,
  ) {
    int startPage = book.filterStartPage;
    int endPage = book.filterEndPage;
    final TextEditingController startController =
        TextEditingController(text: '$startPage');
    final TextEditingController endController =
        TextEditingController(text: '$endPage');
    final Set<int> excludedIndices = book.chapters
        .where((c) => !c.isIncluded)
        .map((c) => c.index)
        .toSet();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Text('✂️', style: TextStyle(fontSize: 20)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Sayfa ve Bölüm Filtrele (Önsözü Atla)',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Örn: 14. sayfadan başla diyerek kitabın başındaki önsöz, künye ve içindekiler kısımlarını anında atlayabilirsiniz.',
                    style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: startController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Başlangıç Sayfası',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (val) {
                            final int? parsed = int.tryParse(val);
                            if (parsed != null) {
                              setModalState(() {
                                startPage =
                                    parsed.clamp(1, book.totalPages);
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: endController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Bitiş Sayfası (Maks ${book.totalPages})',
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (val) {
                            final int? parsed = int.tryParse(val);
                            if (parsed != null) {
                              setModalState(() {
                                endPage = parsed.clamp(
                                  startPage,
                                  book.totalPages,
                                );
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  if (book.totalPages > 1)
                    RangeSlider(
                      values: RangeValues(
                        startPage.clamp(1, book.totalPages).toDouble(),
                        endPage.clamp(startPage, book.totalPages).toDouble(),
                      ),
                      min: 1,
                      max: book.totalPages.toDouble(),
                      divisions: (book.totalPages - 1).clamp(1, 500),
                      labels: RangeLabels('$startPage', '$endPage'),
                      onChanged: (values) {
                        setModalState(() {
                          startPage = values.start.round();
                          endPage = values.end.round();
                          startController.text = '$startPage';
                          endController.text = '$endPage';
                        });
                      },
                    ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: book.chapters.length,
                      itemBuilder: (context, idx) {
                        final ch = book.chapters[idx];
                        final bool isIncluded =
                            !excludedIndices.contains(ch.index);
                        return CheckboxListTile(
                          dense: true,
                          value: isIncluded,
                          title: Text(ch.title),
                          subtitle: Text(
                            'Syf. ${ch.startPage}-${ch.endPage} • ${ch.ttsSentences.length} cümle',
                          ),
                          onChanged: (val) {
                            setModalState(() {
                              if (val == true) {
                                excludedIndices.remove(ch.index);
                              } else {
                                excludedIndices.add(ch.index);
                              }
                            });
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Sayfa Filtresini Uygula ve Kaydet'),
                      onPressed: () async {
                        final updatedBook =
                            FileManagerService.applyPageOrChapterFilter(
                          book: book,
                          startPageOrChapter: startPage,
                          endPageOrChapter: endPage,
                          manuallyExcludedChapterIndices: excludedIndices,
                        );
                        await tts.loadBook(
                          updatedBook,
                          initialChapterIndex: tts.currentChapterIndex,
                        );
                        await _persistEverything();
                        if (ctx.mounted) {
                          Navigator.of(ctx).pop();
                        }
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
