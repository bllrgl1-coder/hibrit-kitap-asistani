import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import '../models/book_models.dart';
import 'reading_progress_storage.dart';
import 'text_cleaner_service.dart';

/// EPUB dosyalarını (ZIP/OPF/XHTML standardı) orijinal bölüm sırasıyla okuyan,
/// DOM ağacından dipnot/sayfa no/künye etiketlerini (`remove()`) temizleyen
/// ve İkili Çıktı (Paragraf + TTS Cümle) üreten servis.
class EpubParserService {
  /// EPUB dosyasını ayrıştırır ve `ParsedBook` döner.
  static Future<ParsedBook> parseEpubFile({
    required String filePath,
    int? customStartChapterIndex,
    int? customEndChapterIndex,
  }) async {
    final File file = File(filePath);
    final List<int> bytes = await file.readAsBytes();
    final Archive archive = ZipDecoder().decodeBytes(bytes);

    String bookTitle = file.uri.pathSegments.last
        .replaceAll(RegExp(r'\.epub$', caseSensitive: false), '');
    String bookAuthor = 'Bilinmeyen Yazar';

    // Archive içindeki dosyaları hızlı erişim için haritala
    final Map<String, ArchiveFile> fileMap = {};
    for (final ArchiveFile archiveFile in archive) {
      if (archiveFile.isFile) {
        fileMap[archiveFile.name.replaceAll('\\', '/')] = archiveFile;
      }
    }

    // 1. OPF dosyasını bul ve kitap meta verilerini + okuma sırasını (spine) çıkar
    final List<String> orderedHtmlPaths = [];
    final ArchiveFile? opfFile = fileMap.values
        .where((f) => f.name.toLowerCase().endsWith('.opf'))
        .firstOrNull;

    if (opfFile != null) {
      final String opfContent =
          utf8.decode(opfFile.content as List<int>, allowMalformed: true);
      final dom.Document opfDoc = html_parser.parse(opfContent);

      final String? dcTitle =
          opfDoc.querySelector('dc\\:title, title')?.text.trim();
      if (dcTitle != null && dcTitle.isNotEmpty) {
        bookTitle = dcTitle;
      }

      final String? dcCreator =
          opfDoc.querySelector('dc\\:creator, creator')?.text.trim();
      if (dcCreator != null && dcCreator.isNotEmpty) {
        bookAuthor = dcCreator;
      }

      final String opfDir = _getParentDir(opfFile.name);
      final Map<String, String> manifestIdToHref = {};

      for (final item in opfDoc.querySelectorAll('manifest > item')) {
        final String? id = item.attributes['id'];
        final String? href = item.attributes['href'];
        if (id != null && href != null) {
          manifestIdToHref[id] = _joinPath(opfDir, Uri.decodeFull(href));
        }
      }

      for (final itemref in opfDoc.querySelectorAll('spine > itemref')) {
        final String? idref = itemref.attributes['idref'];
        if (idref != null && manifestIdToHref.containsKey(idref)) {
          orderedHtmlPaths.add(manifestIdToHref[idref]!);
        }
      }
    }

    // Eğer spine boşsa arşivdeki tüm .xhtml / .html dosyalarını alfabetik sırayla al
    if (orderedHtmlPaths.isEmpty) {
      final List<String> allHtmlKeys = fileMap.keys
          .where(
            (k) =>
                k.toLowerCase().endsWith('.xhtml') ||
                k.toLowerCase().endsWith('.html') ||
                k.toLowerCase().endsWith('.htm'),
          )
          .toList()
        ..sort();
      orderedHtmlPaths.addAll(allHtmlKeys);
    }

    final List<BookChapter> parsedChapters = [];
    int validChapterIdx = 0;

    for (final String htmlPath in orderedHtmlPaths) {
      final ArchiveFile? htmlArchiveFile =
          fileMap[htmlPath] ?? _findBySuffix(fileMap, htmlPath);
      if (htmlArchiveFile == null) continue;

      final String rawHtml = utf8.decode(
        htmlArchiveFile.content as List<int>,
        allowMalformed: true,
      );
      if (rawHtml.trim().isEmpty) continue;

      // Bölüm başlığını <h1>, <h2>, <h3> veya <title> etiketinden yakala
      final String extractedHeading =
          _extractHeadingFromHtml(rawHtml, validChapterIdx + 1);

      // 2. ADIM: HTML içeriğini düz metne çevirmeden önce DOM ağacından
      // sup, sub, aside, figcaption, footer, nav ve footnote/pagenum/copyright
      // içeren elementleri tamamen kaldır (remove()) ve TurkishBookCleaner ile temizle
      final String cleanedText = TextCleanerService.cleanEpubHtmlDom(rawHtml);

      if (cleanedText.isEmpty || cleanedText.length < 20) {
        continue;
      }

      final bool isFrontMatterNoise = RegExp(
        r'^(İçindekiler|Künye|Telif|Copyright|Kapak|İthaf)$',
        caseSensitive: false,
      ).hasMatch(extractedHeading.trim());

      final int chapterNumber = validChapterIdx + 1;
      final bool withinCustomRange = (customStartChapterIndex == null ||
              chapterNumber >= customStartChapterIndex) &&
          (customEndChapterIndex == null ||
              chapterNumber <= customEndChapterIndex);

      // 3. ADIM: İkili Çıktı Üretimi (Hem paragraphs hem kısaltma korumalı TTS sentences)
      final BookChapter chapter =
          TextCleanerService.createChapterWithDualOutput(
        index: validChapterIdx,
        title: extractedHeading,
        startPage: chapterNumber,
        endPage: chapterNumber,
        cleanedChapterText: cleanedText,
        isIncluded: withinCustomRange && !isFrontMatterNoise,
      );

      if (chapter.paragraphs.isNotEmpty) {
        parsedChapters.add(chapter);
        validChapterIdx++;
      }
    }

    final int totalChapters =
        parsedChapters.isEmpty ? 1 : parsedChapters.length;

    return ParsedBook(
      id: ReadingProgressStorage.generateConsistentBookId(filePath, bookTitle),
      title: bookTitle,
      author: bookAuthor,
      filePath: filePath,
      format: BookFormat.epub,
      totalPages: totalChapters,
      filterStartPage: customStartChapterIndex ?? 1,
      filterEndPage: customEndChapterIndex ?? totalChapters,
      chapters: parsedChapters,
      addedAt: DateTime.now(),
    );
  }

  static String _extractHeadingFromHtml(String htmlContent, int fallbackNumber) {
    final dom.Document doc = html_parser.parse(htmlContent);
    for (final selector in ['h1', 'h2', 'h3', 'title']) {
      final String? text = doc.querySelector(selector)?.text.trim();
      if (text != null && text.isNotEmpty && text.length <= 90) {
        return text.replaceAll(RegExp(r'\s+'), ' ');
      }
    }
    return 'Bölüm $fallbackNumber';
  }

  static String _getParentDir(String path) {
    final int idx = path.lastIndexOf('/');
    return idx == -1 ? '' : path.substring(0, idx);
  }

  static String _joinPath(String dir, String href) {
    if (dir.isEmpty) return href;
    return '$dir/$href';
  }

  static ArchiveFile? _findBySuffix(
    Map<String, ArchiveFile> map,
    String targetPath,
  ) {
    final String fileName = targetPath.split('/').last.toLowerCase();
    for (final entry in map.entries) {
      if (entry.key.toLowerCase().endsWith(fileName)) {
        return entry.value;
      }
    }
    return null;
  }
}
