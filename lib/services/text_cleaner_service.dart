import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import '../models/book_models.dart';

/// Türkçe kitaplarda seslendirme ve okuma kalitesini maksimuma çıkaran
/// çekirdek metin onarım ve kısaltma korumalı cümle bölme sınıfı.
class TurkishBookCleaner {
  // Türkçe kısaltmalar (Noktadan sonra cümle bölünmesini engeller)
  static final RegExp _kisaltmalar = RegExp(
    r'\b(Dr|Prof|Doç|Yrd|Av|Alb|Org|Gen|Bşk|Müh|MÖ|MS|M\.Ö|M\.S|vb|vs|bkz|çev|haz|ed|s|syf|c|no|tel|yy)\.\s+',
    caseSensitive: false,
  );

  // 1. Ham Metin Onarımı ve Gürültü Temizliği
  static String cleanRawText(String rawText) {
    String text = rawText;

    // PDF Ligature (birleşik harf) ve bozuk karakter düzeltmeleri
    final Map<String, String> charFixes = {
      'ﬁ': 'fi', 'ﬂ': 'fl', 'ﬀ': 'ff', 'ﬃ': 'ffi', 'ﬄ': 'ffl',
      '\u00AD': '', // Gizli tire (Soft hyphen)
      '\u200B': '', // Sıfır genişlikli boşluk
    };
    charFixes.forEach((bozuk, duzgun) => text = text.replaceAll(bozuk, duzgun));

    // Satır sonu tirelemesi ile bölünmüş kelimeleri birleştir (Örn: "gele-\ncek" -> "gelecek")
    text = text.replaceAllMapped(
      RegExp(r'([a-zA-ZçğıöşüÇĞİÖŞÜ]+)-\s*\n+\s*([a-zA-ZçğıöşüÇĞİÖŞÜ]+)'),
      (m) => '${m.group(1)}${m.group(2)}',
    );

    // Köşeli ve normal parantez içindeki dipnot referanslarını sil: [1], [12], (dipnot 1)
    text = text.replaceAll(RegExp(r'\[\s*\d+\s*\]|\[\s*[a-zA-Z]\s*\]'), '');
    text = text.replaceAll(
      RegExp(r'\(\s*dipnot\s*\d+\s*\)', caseSensitive: false),
      '',
    );

    // Tek başına satırda duran sayfa numaralarını ve Roma rakamlarını sil
    text = text.replaceAll(
      RegExp(r'^\s*[-–—]?\s*\d+\s*[-–—]?\s*$', multiLine: true),
      '',
    );
    text = text.replaceAll(
      RegExp(r'^\s*[IVXLCDM]+\s*$', multiLine: true),
      '',
    );

    // Yayınevi künye, ISBN ve URL gürültülerini temizle
    text = text.replaceAll(
      RegExp(
        r'^.*(ISBN|Tüm hakları saklıdır|Copyright|Baskı:|Matbaa).*$',
        multiLine: true,
        caseSensitive: false,
      ),
      '',
    );
    text = text.replaceAll(RegExp(r'https?:\/\/\S+|www\.\S+'), '');

    // Paragraf yapısını korumak için:
    // İki veya daha fazla alt satırı (gerçek paragraf) geçici bir işaretle koru,
    // tekil alt satırları (PDF satır kırılmalarını) boşluğa çevir.
    text = text.replaceAll(RegExp(r'\n\s*\n+'), '{{PARAGRAF}}');
    text = text.replaceAll(RegExp(r'\n+'), ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    text = text.replaceAll('{{PARAGRAF}}', '\n\n');

    return text.trim();
  }

  // 2. TTS İçin Türkçe Kısaltma Korumalı Cümle Bölücü
  static List<String> splitIntoTtsSentences(String paragraph) {
    // Kısaltmalardaki ve sıra sayılarındaki (Örn: "19. yüzyıl") noktaları geçici olarak koru
    String protectedText = paragraph.replaceAllMapped(
      _kisaltmalar,
      (m) => m.group(0)!.replaceAll('.', '{{NOKTA}}'),
    );
    protectedText = protectedText.replaceAllMapped(
      RegExp(r'(\b\d+)\.\s+([a-zçğıöşü])'), // Küçük harfle devam eden sıra sayıları (15. yüzyıl)
      (m) => '${m.group(1)}{{NOKTA}} ${m.group(2)}',
    );

    // Cümle sonlarından (. ! ? …) böl
    List<String> rawSentences = protectedText.split(RegExp(r'(?<=[.!?…])\s+'));

    // Geçici nokta işaretlerini geri koy ve boşlukları temizle
    return rawSentences
        .map((s) => s.replaceAll('{{NOKTA}}', '.').trim())
        .where((s) => s.length > 1)
        .toList();
  }
}

/// PDF Running Header/Footer temizliği, EPUB DOM filtrelemesi ve
/// İkili Çıktı (Paragraf + TTS Cümle) üretimini yöneten üst servis.
class TextCleanerService {
  /// Ardışık PDF sayfalarında en üst veya en alt satırda tekrar eden
  /// (running header / running footer - kitap adı, yazar adı, bölüm başlığı)
  /// metinleri tespit edip siler.
  static List<List<String>> removeRunningHeadersAndFooters(
    List<List<String>> pagesLines,
  ) {
    if (pagesLines.length < 2) return pagesLines;

    // Satırı karşılaştırma için normalize eder (sayıları ve noktalama işaretlerini soyutlar)
    String normalizeEdgeLine(String line) {
      return line
          .replaceAll(RegExp(r'\d+'), '')
          .replaceAll(RegExp(r'[^\wçğıöşüÇĞİÖŞÜ]'), '')
          .toLowerCase()
          .trim();
    }

    final Map<String, int> topLineFrequency = {};
    final Map<String, int> bottomLineFrequency = {};

    for (final lines in pagesLines) {
      if (lines.isEmpty) continue;
      final firstNorm = normalizeEdgeLine(lines.first);
      if (firstNorm.isNotEmpty && firstNorm.length <= 80) {
        topLineFrequency[firstNorm] = (topLineFrequency[firstNorm] ?? 0) + 1;
      }
      if (lines.length > 1) {
        final lastNorm = normalizeEdgeLine(lines.last);
        if (lastNorm.isNotEmpty && lastNorm.length <= 80) {
          bottomLineFrequency[lastNorm] =
              (bottomLineFrequency[lastNorm] ?? 0) + 1;
        }
      }
    }

    final List<List<String>> cleanedPages = [];

    for (int i = 0; i < pagesLines.length; i++) {
      final currentLines = List<String>.from(pagesLines[i]);
      if (currentLines.isEmpty) {
        cleanedPages.add(currentLines);
        continue;
      }

      // 1. Üst satır (Running Header) kontrolü:
      // Bir önceki/sonraki sayfayla (veya tek-çift sayfa düzeniyle i-2 / i+2) aynıysa
      // ya da 3 ve daha fazla sayfada en üstte tekrar ediyorsa sil.
      final firstNorm = normalizeEdgeLine(currentLines.first);
      if (firstNorm.isNotEmpty) {
        final bool repeatsGlobally = (topLineFrequency[firstNorm] ?? 0) >= 3;
        final bool repeatsPrev = i > 0 &&
            pagesLines[i - 1].isNotEmpty &&
            normalizeEdgeLine(pagesLines[i - 1].first) == firstNorm;
        final bool repeatsNext = i + 1 < pagesLines.length &&
            pagesLines[i + 1].isNotEmpty &&
            normalizeEdgeLine(pagesLines[i + 1].first) == firstNorm;
        final bool repeatsEvenOdd = i >= 2 &&
            pagesLines[i - 2].isNotEmpty &&
            normalizeEdgeLine(pagesLines[i - 2].first) == firstNorm;

        if (repeatsGlobally || repeatsPrev || repeatsNext || repeatsEvenOdd) {
          currentLines.removeAt(0);
        }
      }

      // 2. Alt satır (Running Footer) kontrolü:
      if (currentLines.isNotEmpty) {
        final lastNorm = normalizeEdgeLine(currentLines.last);
        if (lastNorm.isNotEmpty) {
          final bool repeatsGlobally =
              (bottomLineFrequency[lastNorm] ?? 0) >= 3;
          final bool repeatsPrev = i > 0 &&
              pagesLines[i - 1].isNotEmpty &&
              normalizeEdgeLine(pagesLines[i - 1].last) == lastNorm;
          final bool repeatsNext = i + 1 < pagesLines.length &&
              pagesLines[i + 1].isNotEmpty &&
              normalizeEdgeLine(pagesLines[i + 1].last) == lastNorm;
          final bool repeatsEvenOdd = i >= 2 &&
              pagesLines[i - 2].isNotEmpty &&
              normalizeEdgeLine(pagesLines[i - 2].last) == lastNorm;

          if (repeatsGlobally || repeatsPrev || repeatsNext || repeatsEvenOdd) {
            currentLines.removeLast();
          }
        }
      }

      cleanedPages.add(currentLines);
    }

    return cleanedPages;
  }

  /// EPUB HTML içeriğini düz metne çevirmeden önce DOM ağacından:
  /// - `sup`, `sub`, `aside`, `figcaption`, `footer`, `nav` etiketlerini
  /// - `class` veya `id` içinde `footnote`, `pagenum`, `copyright` geçen elementleri
  /// tamamen kaldırır (`remove()`) ve paragraf yapısını koruyan ham metin üretir.
  static String cleanEpubHtmlDom(String htmlContent) {
    final dom.Document document = html_parser.parse(htmlContent);

    // 1. İstenmeyen etiketleri DOM ağacından tamamen kaldır
    const List<String> forbiddenTags = [
      'sup',
      'sub',
      'aside',
      'figcaption',
      'footer',
      'nav',
      'script',
      'style',
    ];
    for (final tag in forbiddenTags) {
      document.querySelectorAll(tag).forEach((element) => element.remove());
    }

    // 2. class, id veya epub:type içinde footnote, pagenum, copyright geçenleri kaldır
    final RegExp noisyAttrPattern = RegExp(
      r'(footnote|pagenum|page-num|copyright|noteref|endnote)',
      caseSensitive: false,
    );

    final List<dom.Element> allElements = document.querySelectorAll('*');
    for (final element in allElements) {
      final String classAttr = element.attributes['class'] ?? '';
      final String idAttr = element.attributes['id'] ?? '';
      final String epubType = element.attributes['epub:type'] ?? '';
      final String roleAttr = element.attributes['role'] ?? '';

      if (noisyAttrPattern.hasMatch(classAttr) ||
          noisyAttrPattern.hasMatch(idAttr) ||
          noisyAttrPattern.hasMatch(epubType) ||
          noisyAttrPattern.hasMatch(roleAttr)) {
        element.remove();
      }
    }

    // 3. Paragraf bütünlüğünü korumak için blok elementlerin sonuna çift satır sonu ekle
    final dom.Element? body = document.body;
    if (body == null) return '';

    final StringBuffer buffer = StringBuffer();
    _extractStructuredTextFromNode(body, buffer);

    return TurkishBookCleaner.cleanRawText(buffer.toString());
  }

  static void _extractStructuredTextFromNode(
    dom.Node node,
    StringBuffer buffer,
  ) {
    if (node.nodeType == dom.Node.TEXT_NODE) {
      buffer.write(node.text);
      return;
    }

    if (node is dom.Element) {
      final String tag = node.localName?.toLowerCase() ?? '';
      const Set<String> blockTags = {
        'p',
        'div',
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'li',
        'blockquote',
        'section',
        'article',
      };

      if (tag == 'br') {
        buffer.write('\n');
        return;
      }

      for (final child in node.nodes) {
        _extractStructuredTextFromNode(child, buffer);
      }

      if (blockTags.contains(tag)) {
        buffer.write('\n\n');
      }
    }
  }

  /// Temizlenmiş metinden İkili Çıktı (Hem E-Kitap Paragrafları hem TTS Cümleleri) üretir.
  static BookChapter createChapterWithDualOutput({
    required int index,
    required String title,
    required int startPage,
    required int endPage,
    required String cleanedChapterText,
    bool isIncluded = true,
  }) {
    // 1. ÇIKTI: Ekranda paragraf bütünlüğü bozulmadan okunacak paragraflar listesi
    final List<String> paragraphs = cleanedChapterText
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    // 2. ÇIKTI: TTS motorunun Türkçe kısaltmalara takılmadan okuyacağı
    // ve ekranda hangi paragrafın okunduğunu vurgulayacağı cümle listesi
    final List<String> allSentences = [];
    final List<TtsSentence> ttsSentences = [];

    int globalSentenceIndex = 0;
    for (int pIndex = 0; pIndex < paragraphs.length; pIndex++) {
      final String paragraph = paragraphs[pIndex];
      final List<String> pSentences =
          TurkishBookCleaner.splitIntoTtsSentences(paragraph);

      for (final sentenceText in pSentences) {
        allSentences.add(sentenceText);
        ttsSentences.add(
          TtsSentence(
            sentenceIndex: globalSentenceIndex,
            paragraphIndex: pIndex,
            text: sentenceText,
          ),
        );
        globalSentenceIndex++;
      }
    }

    return BookChapter(
      index: index,
      title: title,
      startPage: startPage,
      endPage: endPage,
      paragraphs: paragraphs,
      sentences: allSentences,
      ttsSentences: ttsSentences,
      isIncluded: isIncluded,
    );
  }
}
