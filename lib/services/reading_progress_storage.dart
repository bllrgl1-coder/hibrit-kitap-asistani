import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book_models.dart';

/// Kitapta kalınan bölüm, cümle, paragraf, sayfa, kaydırma konumu (scrollPosition)
/// ve sayfa filtresi bilgisini milimetrik olarak tutan model.
class SavedReadingPosition {
  final String bookId;
  final String bookTitle;
  final String author;
  final String filePath;
  final BookFormat format;
  final int chapterIndex;
  final String chapterTitle;
  final int sentenceIndex;
  final int paragraphIndex;
  final int pageNumber;
  final double scrollPosition;
  final double progressPercent; // 0.0 - 1.0 arası (Örn: 0.42 -> %42)
  final int filterStartPage;
  final int filterEndPage;
  final List<int> excludedChapterIndices;
  final DateTime savedAt;

  const SavedReadingPosition({
    required this.bookId,
    required this.bookTitle,
    this.author = 'Bilinmeyen Yazar',
    this.filePath = '',
    this.format = BookFormat.epub,
    required this.chapterIndex,
    this.chapterTitle = '',
    required this.sentenceIndex,
    required this.paragraphIndex,
    required this.pageNumber,
    this.scrollPosition = 0.0,
    this.progressPercent = 0.0,
    this.filterStartPage = 1,
    this.filterEndPage = 9999,
    this.excludedChapterIndices = const [],
    required this.savedAt,
  });

  int get lastChapterIndex => chapterIndex;
  int get lastSentenceIndex => sentenceIndex;

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'bookTitle': bookTitle,
        'author': author,
        'filePath': filePath,
        'format': format.name,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'sentenceIndex': sentenceIndex,
        'paragraphIndex': paragraphIndex,
        'pageNumber': pageNumber,
        'scrollPosition': scrollPosition,
        'progressPercent': progressPercent,
        'filterStartPage': filterStartPage,
        'filterEndPage': filterEndPage,
        'excludedChapterIndices': excludedChapterIndices,
        'savedAt': savedAt.toIso8601String(),
      };

  factory SavedReadingPosition.fromJson(Map<String, dynamic> json) {
    final String formatStr = json['format'] as String? ?? 'epub';
    final List<dynamic> rawExcluded =
        json['excludedChapterIndices'] as List<dynamic>? ?? const [];

    return SavedReadingPosition(
      bookId: json['bookId'] as String? ?? '',
      bookTitle: json['bookTitle'] as String? ?? '',
      author: json['author'] as String? ?? 'Bilinmeyen Yazar',
      filePath: json['filePath'] as String? ?? '',
      format: formatStr == 'pdf' ? BookFormat.pdf : BookFormat.epub,
      chapterIndex: json['chapterIndex'] as int? ?? 0,
      chapterTitle: json['chapterTitle'] as String? ?? '',
      sentenceIndex: json['sentenceIndex'] as int? ?? 0,
      paragraphIndex: json['paragraphIndex'] as int? ?? 0,
      pageNumber: json['pageNumber'] as int? ?? 1,
      scrollPosition: (json['scrollPosition'] as num?)?.toDouble() ?? 0.0,
      progressPercent: (json['progressPercent'] as num?)?.toDouble() ?? 0.0,
      filterStartPage: json['filterStartPage'] as int? ?? 1,
      filterEndPage: json['filterEndPage'] as int? ?? 9999,
      excludedChapterIndices: rawExcluded.map((e) => e as int).toList(),
      savedAt: DateTime.tryParse(json['savedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Kullanıcının Kişisel Görünüm, Tipografi ve Ses Ayarları Modeli
class UserReaderPreferences {
  final String themeKey; // 'day', 'sepia', 'night', 'amoled'
  final double fontSize;
  final double lineHeight;
  final double horizontalPadding;
  final String voiceName; // 'ahmet' veya 'emel'
  final double speedMultiplier;

  const UserReaderPreferences({
    this.themeKey = 'sepia',
    this.fontSize = 18.0,
    this.lineHeight = 1.6,
    this.horizontalPadding = 18.0,
    this.voiceName = 'ahmet',
    this.speedMultiplier = 1.0,
  });

  Map<String, dynamic> toJson() => {
        'themeKey': themeKey,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'horizontalPadding': horizontalPadding,
        'voiceName': voiceName,
        'speedMultiplier': speedMultiplier,
      };

  factory UserReaderPreferences.fromJson(Map<String, dynamic> json) {
    return UserReaderPreferences(
      themeKey: json['themeKey'] as String? ?? 'sepia',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18.0,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.6,
      horizontalPadding:
          (json['horizontalPadding'] as num?)?.toDouble() ?? 18.0,
      voiceName: json['voiceName'] as String? ?? 'ahmet',
      speedMultiplier: (json['speedMultiplier'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// `shared_preferences` kullanarak tüm kitaplığı, kalınan cümle/bölüm/sayfa/kaydırma
/// indeksini, sayfa filtrelerini ve tipografi/ses tercihlerini kalıcı hafızaya kaydeden servis.
class ReadingProgressStorage {
  static const String _keyPrefix = 'reading_pos_';
  static const String _lastActiveBookKey = 'last_active_book_id';
  static const String _libraryBookIdsKey = 'library_book_ids_list';
  static const String _userPrefsKey = 'user_reader_preferences_v1';

  /// Belirtilen kitap için tam olarak kalınan cümle, bölüm, sayfa, kaydırma ve filtre bilgisini kaydeder.
  static Future<void> savePosition({
    required String bookId,
    required String bookTitle,
    String? author,
    String? filePath,
    BookFormat? format,
    required int chapterIndex,
    String? chapterTitle,
    required int sentenceIndex,
    required int paragraphIndex,
    required int pageNumber,
    double? scrollPosition,
    double? progressPercent,
    int? filterStartPage,
    int? filterEndPage,
    List<int>? excludedChapterIndices,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    // Mevcut kaydı oku ki eksik parametre varsa (örn. arka plan servisinden çağrıldığında) korunsun
    final SavedReadingPosition? existing = await loadPosition(bookId);

    final SavedReadingPosition position = SavedReadingPosition(
      bookId: bookId,
      bookTitle: bookTitle,
      author: author ?? existing?.author ?? 'Bilinmeyen Yazar',
      filePath: filePath ?? existing?.filePath ?? '',
      format: format ?? existing?.format ?? BookFormat.epub,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle ?? existing?.chapterTitle ?? '',
      sentenceIndex: sentenceIndex,
      paragraphIndex: paragraphIndex,
      pageNumber: pageNumber,
      scrollPosition: scrollPosition ?? existing?.scrollPosition ?? 0.0,
      progressPercent: progressPercent ?? existing?.progressPercent ?? 0.0,
      filterStartPage: filterStartPage ?? existing?.filterStartPage ?? 1,
      filterEndPage: filterEndPage ?? existing?.filterEndPage ?? 9999,
      excludedChapterIndices:
          excludedChapterIndices ?? existing?.excludedChapterIndices ?? const [],
      savedAt: DateTime.now(),
    );

    await prefs.setString(
      '$_keyPrefix$bookId',
      jsonEncode(position.toJson()),
    );
    await prefs.setString(_lastActiveBookKey, bookId);

    // Kitaplık listesine ekle
    final List<String> bookIds =
        prefs.getStringList(_libraryBookIdsKey) ?? <String>[];
    if (!bookIds.contains(bookId)) {
      bookIds.insert(0, bookId);
    } else {
      bookIds.remove(bookId);
      bookIds.insert(0, bookId);
    }
    await prefs.setStringList(_libraryBookIdsKey, bookIds);
  }

  /// Kitap nesnesinden tüm ilerleme yüzdesini hesaplayarak milimetrik kayıt yapar.
  static Future<void> saveFullBookState({
    required ParsedBook book,
    required int chapterIndex,
    required int sentenceIndex,
    required int paragraphIndex,
    required double scrollPosition,
  }) async {
    // Kitap genelinde okunma yüzdesini (0.0 - 1.0) hesapla
    int totalSentencesInBook = 0;
    int completedSentences = 0;

    for (int i = 0; i < book.chapters.length; i++) {
      final ch = book.chapters[i];
      if (!ch.isIncluded) continue;
      final int chCount = ch.ttsSentences.length;
      totalSentencesInBook += chCount;
      if (i < chapterIndex) {
        completedSentences += chCount;
      } else if (i == chapterIndex) {
        completedSentences += (sentenceIndex + 1).clamp(0, chCount);
      }
    }

    final double progress = totalSentencesInBook > 0
        ? (completedSentences / totalSentencesInBook).clamp(0.0, 1.0)
        : 0.0;

    final BookChapter? activeChapter =
        (chapterIndex >= 0 && chapterIndex < book.chapters.length)
            ? book.chapters[chapterIndex]
            : null;

    final List<int> excluded = book.chapters
        .where((c) => !c.isIncluded)
        .map((c) => c.index)
        .toList();

    await savePosition(
      bookId: book.id,
      bookTitle: book.title,
      author: book.author,
      filePath: book.filePath,
      format: book.format,
      chapterIndex: chapterIndex,
      chapterTitle: activeChapter?.title ?? 'Bölüm ${chapterIndex + 1}',
      sentenceIndex: sentenceIndex,
      paragraphIndex: paragraphIndex,
      pageNumber: activeChapter?.startPage ?? 1,
      scrollPosition: scrollPosition,
      progressPercent: progress,
      filterStartPage: book.filterStartPage,
      filterEndPage: book.filterEndPage,
      excludedChapterIndices: excluded,
    );
  }

  /// Belirtilen kitap için kaydedilmiş son okuma/dinleme konumunu getirir.
  static Future<SavedReadingPosition?> loadPosition(String bookId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? rawJson = prefs.getString('$_keyPrefix$bookId');
    if (rawJson == null || rawJson.isEmpty) return null;

    try {
      final Map<String, dynamic> decoded =
          jsonDecode(rawJson) as Map<String, dynamic>;
      return SavedReadingPosition.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Dosya yoluna göre daha önce yüklenmiş kitabın sabit kimliğini (`bookId`) üretir.
  static String generateConsistentBookId(String filePath, String fallbackTitle) {
    final String source = filePath.trim().isNotEmpty ? filePath.trim() : fallbackTitle;
    int hash = 5381;
    for (int i = 0; i < source.length; i++) {
      hash = ((hash << 5) + hash) ^ source.codeUnitAt(i);
    }
    return 'book_${hash.abs()}';
  }

  /// Kitaplıktaki tüm kitapların kayıtlı ilerleme durumlarını son okunma sırasına göre getirir.
  static Future<List<SavedReadingPosition>> loadAllLibraryBooks() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> bookIds =
        prefs.getStringList(_libraryBookIdsKey) ?? <String>[];

    final List<SavedReadingPosition> items = [];
    for (final id in bookIds) {
      final pos = await loadPosition(id);
      if (pos != null) {
        items.add(pos);
      }
    }
    items.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return items;
  }

  /// Son okunan kitabın kaydını getirir.
  static Future<SavedReadingPosition?> loadLastActiveBookPosition() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? lastId = prefs.getString(_lastActiveBookKey);
    if (lastId != null) {
      final pos = await loadPosition(lastId);
      if (pos != null) return pos;
    }
    final all = await loadAllLibraryBooks();
    return all.isNotEmpty ? all.first : null;
  }

  /// Kitabı kütüphaneden siler.
  static Future<void> removeBookFromLibrary(String bookId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_keyPrefix$bookId');
    final List<String> bookIds =
        prefs.getStringList(_libraryBookIdsKey) ?? <String>[];
    bookIds.remove(bookId);
    await prefs.setStringList(_libraryBookIdsKey, bookIds);
  }

  /// Kullanıcının tema, font boyutu, satır aralığı, kenar boşluğu, ses ve hız tercihlerini kaydeder.
  static Future<void> saveUserPreferences(UserReaderPreferences userPrefs) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userPrefsKey, jsonEncode(userPrefs.toJson()));
  }

  /// Kullanıcının kayıtlı görünüm ve ses tercihlerini yükler.
  static Future<UserReaderPreferences> loadUserPreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_userPrefsKey);
    if (raw == null || raw.isEmpty) {
      return const UserReaderPreferences();
    }
    try {
      return UserReaderPreferences.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return const UserReaderPreferences();
    }
  }
}
