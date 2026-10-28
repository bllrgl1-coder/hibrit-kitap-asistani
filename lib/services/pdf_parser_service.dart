import 'dart:io';
import 'dart:ui';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../models/book_models.dart';
import 'reading_progress_storage.dart';
import 'text_cleaner_service.dart';

/// PDF dosyalarını %7 üst/alt marjin kırpması, ardışık sayfa running header/footer
/// tespiti ve Türkçe kısaltma korumalı ikili çıktı ile ayrıştıran servis.
class PdfParserService {
  static const double _topMarginRatio = 0.07; // Üst %7 marjin
  static const double _bottomMarginRatio = 0.93; // Alt %7 marjin (1.0 - 0.07)

  /// PDF dosyasını okur, filtreler ve bölümlere ayrılmış `ParsedBook` döner.
  static Future<ParsedBook> parsePdfFile({
    required String filePath,
    int? customStartPage,
    int? customEndPage,
    int pagesPerChapter = 10,
  }) async {
    final File file = File(filePath);
    final List<int> bytes = await file.readAsBytes();
    final PdfDocument document = PdfDocument(inputBytes: bytes);

    try {
      final int totalPages = document.pages.count;
      final int startPage = (customStartPage ?? 1).clamp(1, totalPages);
      final int endPage = (customEndPage ?? totalPages).clamp(startPage, totalPages);

      final PdfTextExtractor extractor = PdfTextExtractor(document);

      // 1. ADIM: Her sayfa için %7 üst ve %7 alt marjin dışında kalan satırları çıkar
      final List<List<_ExtractedPdfLine>> rawPagesLines = [];

      for (int pageIdx = 0; pageIdx < totalPages; pageIdx++) {
        final PdfPage page = document.pages[pageIdx];
        final Size pageSize = page.size;
        final double topLimit = pageSize.height * _topMarginRatio;
        final double bottomLimit = pageSize.height * _bottomMarginRatio;

        final List<TextLine> textLines = extractor.extractTextLines(
          startPageIndex: pageIdx,
          endPageIndex: pageIdx,
        );

        final List<_ExtractedPdfLine> validLines = [];
        for (final line in textLines) {
          final Rect bounds = line.bounds;
          final String trimmedText = line.text.trim();
          if (trimmedText.isEmpty) continue;

          // Sayfa yüksekliğinin üst %7'si ve alt %7'si dışında kalan alanı al
          final double lineCenterY = bounds.top + (bounds.height / 2.0);
          if (lineCenterY >= topLimit && lineCenterY <= bottomLimit) {
            validLines.add(
              _ExtractedPdfLine(
                text: trimmedText,
                bounds: bounds,
              ),
            );
          }
        }

        rawPagesLines.add(validLines);
      }

      // 2. ADIM: Ardışık sayfalarda en üst veya en alt satırda tekrar eden
      // (running header / footer) metinleri tespit et ve sil
      final List<List<String>> plainPagesLines = rawPagesLines
          .map((page) => page.map((l) => l.text).toList())
          .toList();

      final List<List<String>> headerFooterCleanedPages =
          TextCleanerService.removeRunningHeadersAndFooters(plainPagesLines);

      // Silinen üst/alt satırları koordinatlı listeyle eşleştirerek sayfa metinlerini oluştur
      final List<String> cleanedPageTexts = [];
      for (int i = 0; i < totalPages; i++) {
        final List<_ExtractedPdfLine> originalLines = rawPagesLines[i];
        final List<String> survivingStrings = headerFooterCleanedPages[i];

        if (survivingStrings.isEmpty || originalLines.isEmpty) {
          cleanedPageTexts.add('');
          continue;
        }

        // Koordinat farklarına göre gerçek paragraf boşluklarını (\n\n) belirle
        final List<_ExtractedPdfLine> filteredLines =
            _matchSurvivingLines(originalLines, survivingStrings);

        final String pageRawText = _reconstructPageParagraphs(filteredLines);
        final String cleanedText = TurkishBookCleaner.cleanRawText(pageRawText);
        cleanedPageTexts.add(cleanedText);
      }

      // 3. ADIM: PDF'i anlamlı cümle/paragraf bütünlüğüne göre bölümlere (Chapters) ayır
      final List<BookChapter> chapters = _buildMeaningfulPdfChapters(
        cleanedPageTexts: cleanedPageTexts,
        filterStartPage: startPage,
        filterEndPage: endPage,
        pagesPerChapter: pagesPerChapter,
      );

      final String rawTitle = document.documentInformation.title.trim();
      final String bookTitle = rawTitle.isNotEmpty
          ? rawTitle
          : file.uri.pathSegments.last.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      final String bookAuthor = document.documentInformation.author.trim().isNotEmpty
          ? document.documentInformation.author.trim()
          : 'Bilinmeyen Yazar';

      return ParsedBook(
        id: ReadingProgressStorage.generateConsistentBookId(filePath, bookTitle),
        title: bookTitle,
        author: bookAuthor,
        filePath: filePath,
        format: BookFormat.pdf,
        totalPages: totalPages,
        filterStartPage: startPage,
        filterEndPage: endPage,
        chapters: chapters,
        addedAt: DateTime.now(),
      );
    } finally {
      document.dispose();
    }
  }

  /// Running header/footer silindikten sonra kalan satırları koordinatlarıyla eşleştirir.
  static List<_ExtractedPdfLine> _matchSurvivingLines(
    List<_ExtractedPdfLine> original,
    List<String> surviving,
  ) {
    if (original.length == surviving.length) return original;

    int startOffset = 0;
    if (original.isNotEmpty &&
        surviving.isNotEmpty &&
        original.first.text != surviving.first) {
      startOffset = 1;
    }

    final List<_ExtractedPdfLine> result = [];
    for (int i = 0; i < surviving.length; i++) {
      final int origIdx = startOffset + i;
      if (origIdx < original.length) {
        result.add(original[origIdx]);
      }
    }
    return result;
  }

  /// Satırların Y koordinatlarını kullanarak satır arası boşluktan paragraf geçişlerini tespit eder.
  static String _reconstructPageParagraphs(List<_ExtractedPdfLine> lines) {
    if (lines.isEmpty) return '';
    final StringBuffer buffer = StringBuffer();

    for (int i = 0; i < lines.length; i++) {
      final current = lines[i];
      buffer.write(current.text);

      if (i + 1 < lines.length) {
        final next = lines[i + 1];
        final double verticalGap = next.bounds.top - current.bounds.bottom;
        final double avgLineHeight =
            (current.bounds.height + next.bounds.height) / 2.0;

        // Eğer iki satır arasındaki dikey boşluk normal satır yüksekliğinin %65'inden fazlaysa
        // veya mevcut satır nokta/iki nokta ile bitip sonraki satır içeriden (girintili) başlıyorsa
        // gerçek paragraf sonu (\n\n) ekle.
        final bool isLargeVerticalGap = verticalGap > (avgLineHeight * 0.65);
        final bool isIndentedNewParagraph =
            RegExp(r'[.!?…:"]$').hasMatch(current.text) &&
                (next.bounds.left - current.bounds.left) > 12.0;

        if (isLargeVerticalGap || isIndentedNewParagraph) {
          buffer.write('\n\n');
        } else {
          buffer.write('\n');
        }
      }
    }

    return buffer.toString();
  }

  /// Sayfa sonlarında yarım kalan cümleleri bir sonraki sayfanın başıyla birleştirerek
  /// anlamlı cümle bütünlüğüne sahip bölümler (Chapters) oluşturur.
  static List<BookChapter> _buildMeaningfulPdfChapters({
    required List<String> cleanedPageTexts,
    required int filterStartPage,
    required int filterEndPage,
    required int pagesPerChapter,
  }) {
    final List<BookChapter> chapters = [];
    final int totalPages = cleanedPageTexts.length;

    int chapterIdx = 0;
    String carryOverIncompleteSentence = '';

    for (int startP = 1; startP <= totalPages; startP += pagesPerChapter) {
      final int endP = (startP + pagesPerChapter - 1).clamp(startP, totalPages);
      final StringBuffer chapterBuffer = StringBuffer();

      // Önceki bölümden devreden yarım cümle varsa bölüm başına ekle
      if (carryOverIncompleteSentence.isNotEmpty) {
        chapterBuffer.write('$carryOverIncompleteSentence ');
        carryOverIncompleteSentence = '';
      }

      for (int p = startP; p <= endP; p++) {
        final String pageText = cleanedPageTexts[p - 1];
        if (pageText.isEmpty) continue;

        if (chapterBuffer.isNotEmpty) {
          final String currentStr = chapterBuffer.toString().trimRight();
          // Önceki sayfa cümle bitiş noktalama işaretiyle bitmiyorsa cümleyi kesmeden bağla
          if (!RegExp(r'[.!?…:"]$').hasMatch(currentStr)) {
            chapterBuffer.write(' $pageText');
          } else {
            chapterBuffer.write('\n\n$pageText');
          }
        } else {
          chapterBuffer.write(pageText);
        }
      }

      String combinedText = chapterBuffer.toString().trim();

      // Bölümün en sonundaki cümle yarım kaldıysa ve sonraki sayfalar varsa,
      // cümle bütünlüğünü bozmamak için yarım kalan kısmı sonraki bölüme devret
      if (endP < totalPages &&
          combinedText.isNotEmpty &&
          !RegExp(r'[.!?…:"]$').hasMatch(combinedText)) {
        final int lastPunctIndex =
            combinedText.lastIndexOf(RegExp(r'[.!?…]\s+'));
        if (lastPunctIndex != -1 && lastPunctIndex > combinedText.length * 0.5) {
          carryOverIncompleteSentence =
              combinedText.substring(lastPunctIndex + 1).trim();
          combinedText = combinedText.substring(0, lastPunctIndex + 1).trim();
        }
      }

      if (combinedText.isEmpty) continue;

      final bool isWithinUserFilter =
          endP >= filterStartPage && startP <= filterEndPage;

      final String detectedTitle = _detectChapterHeading(
        combinedText,
        chapterNumber: chapterIdx + 1,
        startPage: startP,
        endPage: endP,
      );

      final BookChapter chapter =
          TextCleanerService.createChapterWithDualOutput(
        index: chapterIdx,
        title: detectedTitle,
        startPage: startP,
        endPage: endP,
        cleanedChapterText: combinedText,
        isIncluded: isWithinUserFilter,
      );

      if (chapter.paragraphs.isNotEmpty) {
        chapters.add(chapter);
        chapterIdx++;
      }
    }

    return chapters;
  }

  /// Bölümün ilk satırında "BÖLÜM 1", "1. Bölüm", "GİRİŞ" gibi bir başlık varsa yakalar,
  /// yoksa sayfa aralığını başlık olarak atar.
  static String _detectChapterHeading(
    String chapterText, {
    required int chapterNumber,
    required int startPage,
    required int endPage,
  }) {
    final List<String> lines = chapterText.split('\n');
    if (lines.isNotEmpty) {
      final String firstParagraph = lines.first.trim();
      final RegExp headingRegex = RegExp(
        r'^(\d+\.\s*Bölüm|Bölüm\s*\d+|BÖLÜM\s*[IVXLCDM\d]+|GİRİŞ|ÖNSÖZ|SONSÖZ)\b.*',
        caseSensitive: false,
      );
      if (firstParagraph.length <= 65 && headingRegex.hasMatch(firstParagraph)) {
        return '$firstParagraph (Syf. $startPage-$endPage)';
      }
    }
    return 'Bölüm $chapterNumber (Sayfa $startPage - $endPage)';
  }
}

class _ExtractedPdfLine {
  final String text;
  final Rect bounds;

  const _ExtractedPdfLine({
    required this.text,
    required this.bounds,
  });
}
