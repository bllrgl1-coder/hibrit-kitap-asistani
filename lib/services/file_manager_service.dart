import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/book_models.dart';
import 'epub_parser_service.dart';
import 'pdf_parser_service.dart';

/// PDF ve EPUB dosyalarını cihazdan seçen, uygulama hafızasına kopyalayan
/// ve Akıllı Metin Ayrıştırıcı/Temizleyici motorlara yönlendiren servis.
class FileManagerService {
  /// Cihazdan PDF veya EPUB dosyası seçer, uygulama dizinine kaydeder ve ayrıştırır.
  static Future<ParsedBook?> pickAndParseBook({
    int? startPageOrChapter,
    int? endPageOrChapter,
  }) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'epub'],
      allowMultiple: false,
    );

    if (result == null || result.files.single.path == null) {
      return null;
    }

    final String pickedPath = result.files.single.path!;
    final String savedPath = await _copyBookToAppDirectory(pickedPath);

    return parseBookFromPath(
      filePath: savedPath,
      startPageOrChapter: startPageOrChapter,
      endPageOrChapter: endPageOrChapter,
    );
  }

  /// Verilen dosya yolundaki PDF veya EPUB kitabını ayrıştırır.
  static Future<ParsedBook> parseBookFromPath({
    required String filePath,
    int? startPageOrChapter,
    int? endPageOrChapter,
  }) async {
    final String lowerPath = filePath.toLowerCase();

    if (lowerPath.endsWith('.pdf')) {
      return PdfParserService.parsePdfFile(
        filePath: filePath,
        customStartPage: startPageOrChapter,
        customEndPage: endPageOrChapter,
      );
    } else if (lowerPath.endsWith('.epub')) {
      return EpubParserService.parseEpubFile(
        filePath: filePath,
        customStartChapterIndex: startPageOrChapter,
        customEndChapterIndex: endPageOrChapter,
      );
    } else {
      throw UnsupportedError(
        'Desteklenmeyen dosya formatı. Lütfen yalnızca PDF veya EPUB seçin.',
      );
    }
  }

  /// Kullanıcının "Önsözü/İçindekileri atla, şu sayfadan/bölümden başla"
  /// filtresini mevcut kitap üzerinde günceller.
  static ParsedBook applyPageOrChapterFilter({
    required ParsedBook book,
    required int startPageOrChapter,
    required int endPageOrChapter,
    Set<int>? manuallyExcludedChapterIndices,
  }) {
    final int clampedStart = startPageOrChapter.clamp(1, book.totalPages);
    final int clampedEnd = endPageOrChapter.clamp(clampedStart, book.totalPages);

    final List<BookChapter> updatedChapters = book.chapters.map((chapter) {
      final bool inRange =
          chapter.endPage >= clampedStart && chapter.startPage <= clampedEnd;
      final bool notExcluded = manuallyExcludedChapterIndices == null ||
          !manuallyExcludedChapterIndices.contains(chapter.index);

      return chapter.copyWith(isIncluded: inRange && notExcluded);
    }).toList();

    return book.copyWith(
      filterStartPage: clampedStart,
      filterEndPage: clampedEnd,
      chapters: updatedChapters,
    );
  }

  /// Seçilen dosyayı geçici önbellekten uygulamanın kalıcı klasörüne kopyalar.
  static Future<String> _copyBookToAppDirectory(String sourcePath) async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final Directory booksDir = Directory('${appDocDir.path}/books');
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }

    final File sourceFile = File(sourcePath);
    final String fileName = sourceFile.uri.pathSegments.last;
    final String targetPath = '${booksDir.path}/$fileName';

    if (sourcePath != targetPath) {
      await sourceFile.copy(targetPath);
    }
    return targetPath;
  }
}
