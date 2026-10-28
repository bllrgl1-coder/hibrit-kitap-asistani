import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/book_models.dart';
import '../services/auto_cache_cleaner.dart';
import '../services/file_manager_service.dart';
import '../services/hybrid_tts_controller.dart';
import '../services/reading_progress_storage.dart';
import '../services/text_cleaner_service.dart';
import 'reader_screen.dart';

/// Faz 6: Modern "Kitaplığım" Ana Ekranı.
/// Yüklenen kitapları okunma yüzdesi (%42 gibi), son okunma tarihi ve
/// "Son Okunan Kitaba Devam Et" hızlı kartı ile listeler.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<SavedReadingPosition> _libraryBooks = [];
  bool _isLoading = true;
  bool _isImporting = false;
  double _cacheSizeMb = 0.0;

  @override
  void initState() {
    super.initState();
    _refreshLibrary();
  }

  Future<void> _refreshLibrary() async {
    setState(() => _isLoading = true);
    List<SavedReadingPosition> saved =
        await ReadingProgressStorage.loadAllLibraryBooks();

    // İlk kurulumda kitaplık boşsa örnek Türkçe rehber kitabını ekle
    if (saved.isEmpty) {
      final ParsedBook sampleBook = _buildSampleBook();
      await ReadingProgressStorage.saveFullBookState(
        book: sampleBook,
        chapterIndex: 1,
        sentenceIndex: 0,
        paragraphIndex: 0,
        scrollPosition: 0.0,
      );
      saved = await ReadingProgressStorage.loadAllLibraryBooks();
    }

    final double cacheMb = await AutoCacheCleaner.getCacheSizeInMb();
    if (mounted) {
      setState(() {
        _libraryBooks = saved;
        _cacheSizeMb = cacheMb;
        _isLoading = false;
      });
    }
  }

  ParsedBook _buildSampleBook() {
    const String sampleRawCh1 = '''
ÖNSÖZ VE KÜNYE
ISBN 978-605-0000-00-0
Tüm hakları saklıdır. Baskı: İstanbul Matbaa
Bu bölüm "Önsözü/İçindekileri atla" filtresini test etmek için eklenmiştir.
''';

    const String sampleRawCh2 = '''
1. Bölüm: Zaman ve Bilim Üzerine

Prof. Dr. Ahmet Cevdet ve Doç. Dr. Elif Kaya, 19. yüzyıl sonlarında İstanbul'da başlayan bilimsel çalışmaları inceledi [1]. Araştırmalara göre insan beyni, hem görsel olarak takip ettiği hem de doğal bir sesle dinlediği metinleri çok daha kalıcı şekilde hafızaya kaydeder.

Kitapların gele-
cek kuşaklara aktarılması yalnızca kağıt üzerinde değil, sesli ve etkileşimli ortamlarla da zenginleşmektedir [12]. Örneğin tarih, felsefe, edebiyat vb. alanlarda okuma yaparken gözlerimiz yorulduğunda tek tuşla dinleme moduna geçebilmek büyük bir konfordur.

Ekranda gördüğünüz herhangi bir cümleye doğrudan dokunarak seslendirmeyi tam o cümleden başlatabilirsiniz! Boş bir alana dokunduğunuzda üst bar ve alt oynatıcı gizlenerek Tam Ekran Saf Okuma Moduna geçer.
''';

    final ch1 = TextCleanerService.createChapterWithDualOutput(
      index: 0,
      title: 'Önsöz (Atlanabilir Bölüm)',
      startPage: 1,
      endPage: 2,
      cleanedChapterText: TurkishBookCleaner.cleanRawText(sampleRawCh1),
      isIncluded: false,
    );

    final ch2 = TextCleanerService.createChapterWithDualOutput(
      index: 1,
      title: '1. Bölüm: Zaman ve Bilim Üzerine',
      startPage: 3,
      endPage: 12,
      cleanedChapterText: TurkishBookCleaner.cleanRawText(sampleRawCh2),
      isIncluded: true,
    );

    return ParsedBook(
      id: 'sample_tr_book',
      title: 'Kişisel Hibrit Kitap Rehberi',
      author: 'Türkçe Akıllı Sesli Kitap Asistanı',
      filePath: '',
      format: BookFormat.epub,
      totalPages: 12,
      filterStartPage: 3,
      filterEndPage: 12,
      chapters: [ch1, ch2],
      addedAt: DateTime.now(),
    );
  }

  Future<void> _importNewBook() async {
    setState(() => _isImporting = true);
    try {
      final ParsedBook? parsed = await FileManagerService.pickAndParseBook();
      if (parsed != null && mounted) {
        final SavedReadingPosition? existing =
            await ReadingProgressStorage.loadPosition(parsed.id);

        final int initChapter = existing?.lastChapterIndex ??
            parsed.chapters.indexWhere((c) => c.isIncluded).clamp(0, 9999);
        final int initSentence = existing?.lastSentenceIndex ?? 0;

        await ReadingProgressStorage.saveFullBookState(
          book: parsed,
          chapterIndex: initChapter,
          sentenceIndex: initSentence,
          paragraphIndex: 0,
          scrollPosition: existing?.scrollPosition ?? 0.0,
        );

        await _refreshLibrary();
        if (mounted) {
          await _openBookInReader(parsed, existing);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kitap içe aktarma hatası: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _openSavedBook(SavedReadingPosition savedPos) async {
    setState(() => _isImporting = true);
    try {
      ParsedBook book;
      if (savedPos.bookId == 'sample_tr_book' || savedPos.filePath.isEmpty) {
        book = _buildSampleBook();
      } else {
        final File file = File(savedPos.filePath);
        if (!await file.exists()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Kitap dosyası bulunamadı, lütfen tekrar seçin.'),
              ),
            );
          }
          return;
        }
        book = await FileManagerService.parseBookFromPath(
          filePath: savedPos.filePath,
          startPageOrChapter: savedPos.filterStartPage,
          endPageOrChapter: savedPos.filterEndPage,
        );
      }

      // Kayıtlı sayfa ve bölüm filtrelerini uygula
      if (savedPos.excludedChapterIndices.isNotEmpty ||
          savedPos.filterStartPage > 1) {
        book = FileManagerService.applyPageOrChapterFilter(
          book: book,
          startPageOrChapter: savedPos.filterStartPage,
          endPageOrChapter: savedPos.filterEndPage.clamp(1, book.totalPages),
          manuallyExcludedChapterIndices:
              savedPos.excludedChapterIndices.toSet(),
        );
      }

      if (mounted) {
        await _openBookInReader(book, savedPos);
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _openBookInReader(
    ParsedBook book,
    SavedReadingPosition? savedPos,
  ) async {
    final tts = context.read<HybridTtsController>();
    await tts.loadBook(
      book,
      initialChapterIndex: savedPos?.lastChapterIndex ?? 0,
      initialSentenceIndex: savedPos?.lastSentenceIndex ?? 0,
    );

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          initialScrollOffset: savedPos?.scrollPosition ?? 0.0,
        ),
      ),
    );
    await _refreshLibrary();
  }

  String _formatDate(DateTime dt) {
    final Duration diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Az önce';
    if (diff.inHours < 1) return '${diff.inMinutes} dk önce';
    if (diff.inDays < 1) return '${diff.inHours} saat önce';
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final SavedReadingPosition? lastReadBook =
        _libraryBooks.isNotEmpty ? _libraryBooks.first : null;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.auto_stories_rounded, color: Colors.indigoAccent),
            SizedBox(width: 10),
            Text(
              'Kitaplığım',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          // Geçici Ses Dosyaları Önbellek Temizleyici
          TextButton.icon(
            tooltip: 'Geçici Ses Önbelleğini Temizle',
            icon: const Icon(Icons.cleaning_services_rounded, size: 18),
            label: Text(
              '${_cacheSizeMb.toStringAsFixed(1)} MB',
              style: const TextStyle(fontSize: 12),
            ),
            onPressed: () async {
              final int count =
                  await AutoCacheCleaner.purgeAllTempAudioCache();
              await _refreshLibrary();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '$count adet geçici TTS ses dosyası temizlendi.',
                    ),
                  ),
                );
              }
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isImporting ? null : _importNewBook,
        icon: const Icon(Icons.add_rounded),
        label: const Text('PDF / EPUB Ekle'),
      ),
      body: _isLoading || _isImporting
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    _isImporting
                        ? 'Kitap ayrıştırılıyor ve akıllı gürültü filtresi uygulanıyor...'
                        : 'Kitaplığınız yükleniyor...',
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _refreshLibrary,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                children: [
                  // 1. ÜST KART: "Son Okunan Kitaba Devam Et" Hızlı Kartı
                  if (lastReadBook != null) ...[
                    _buildContinueReadingHeroCard(context, lastReadBook),
                    const SizedBox(height: 24),
                  ],

                  // 2. TÜM KİTAPLAR BAŞLIĞI
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Yüklenen Kitaplar',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${_libraryBooks.length} Kitap',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 3. KİTAP KARTLARI LİSTESİ
                  ..._libraryBooks.map(
                    (bookPos) => _buildBookLibraryCard(context, bookPos),
                  ),
                ],
              ),
            ),
    );
  }

  /// Üstte yer alan "Son Okunan Kitaba Devam Et" hızlı erişim kartı
  Widget _buildContinueReadingHeroCard(
    BuildContext context,
    SavedReadingPosition lastBook,
  ) {
    final int percentInt = (lastBook.progressPercent * 100).round().clamp(0, 100);

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF312E81), Color(0xFF4338CA)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.indigo.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openSavedBook(lastBook),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.amberAccent,
                            size: 16,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'SON OKUNAN KİTABA DEVAM ET',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatDate(lastBook.savedAt),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  lastBook.bookTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${lastBook.chapterTitle.isNotEmpty ? lastBook.chapterTitle : "Bölüm ${lastBook.chapterIndex + 1}"} • Cümle ${lastBook.sentenceIndex + 1}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: lastBook.progressPercent.clamp(0.02, 1.0),
                          minHeight: 8,
                          backgroundColor: Colors.white.withValues(alpha: 0.2),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.amberAccent,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '%$percentInt',
                      style: const TextStyle(
                        color: Colors.amberAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF312E81),
                    ),
                    onPressed: () => _openSavedBook(lastBook),
                    icon: const Icon(Icons.headphones_rounded, size: 18),
                    label: const Text(
                      'Kaldığım Cümleden Devam Et',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Kitaplıktaki her bir kitabı okunma yüzdesi ve son okunma tarihiyle gösteren kart
  Widget _buildBookLibraryCard(
    BuildContext context,
    SavedReadingPosition bookPos,
  ) {
    final int percentInt = (bookPos.progressPercent * 100).round().clamp(0, 100);
    final bool isPdf = bookPos.format == BookFormat.pdf;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0.8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openSavedBook(bookPos),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Format İkonu (PDF / EPUB)
              Container(
                width: 52,
                height: 68,
                decoration: BoxDecoration(
                  color: isPdf
                      ? Colors.redAccent.withValues(alpha: 0.12)
                      : Colors.indigo.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isPdf
                          ? Icons.picture_as_pdf_rounded
                          : Icons.menu_book_rounded,
                      color: isPdf ? Colors.redAccent : Colors.indigo,
                      size: 26,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isPdf ? 'PDF' : 'EPUB',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: isPdf ? Colors.redAccent : Colors.indigo,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              // Kitap Bilgileri ve İlerleme Çubuğu
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bookPos.bookTitle,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      bookPos.author,
                      style: TextStyle(fontSize: 12.5, color: Colors.grey[600]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Son okuma: ${_formatDate(bookPos.savedAt)} • Cümle ${bookPos.sentenceIndex + 1}',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey[500]),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: bookPos.progressPercent.clamp(0.01, 1.0),
                              minHeight: 6,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '%$percentInt',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (bookPos.bookId != 'sample_tr_book')
                IconButton(
                  tooltip: 'Kitaplıktan Kaldır',
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  onPressed: () async {
                    await ReadingProgressStorage.removeBookFromLibrary(
                      bookPos.bookId,
                    );
                    await _refreshLibrary();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
