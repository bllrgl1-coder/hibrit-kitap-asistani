/// Kitap türünü belirten enum (PDF veya EPUB)
enum BookFormat { pdf, epub }

/// TTS motorunun okurken hem cümleyi hem de ait olduğu paragrafı
/// ekranda senkronize vurgulayabilmesi (highlight) için kullanılan model.
class TtsSentence {
  /// Bölüm içindeki genel cümle sırası
  final int sentenceIndex;

  /// Bu cümlenin ait olduğu paragrafın `paragraphs` listesindeki indeksi
  final int paragraphIndex;

  /// Temizlenmiş ve kısaltmaları korunmuş cümle metni
  final String text;

  const TtsSentence({
    required this.sentenceIndex,
    required this.paragraphIndex,
    required this.text,
  });

  Map<String, dynamic> toJson() => {
        'sentenceIndex': sentenceIndex,
        'paragraphIndex': paragraphIndex,
        'text': text,
      };

  factory TtsSentence.fromJson(Map<String, dynamic> json) => TtsSentence(
        sentenceIndex: json['sentenceIndex'] as int,
        paragraphIndex: json['paragraphIndex'] as int,
        text: json['text'] as String,
      );
}

/// İkili Çıktı Üretimi sağlayan Bölüm (Chapter) modeli:
/// 1. `paragraphs`: Ekranda e-kitap olarak paragraf bütünlüğü bozulmadan okunacak liste.
/// 2. `sentences` ve `ttsSentences`: TTS motorunun Türkçe kısaltmalara takılmadan
///    okuyacağı ve ekranda hangi paragrafın/cümlenin okunduğunu vurgulayacağı liste.
class BookChapter {
  final int index;
  final String title;
  final int startPage;
  final int endPage;

  /// 1. Çıktı: Ekranda paragraf bütünlüğü korunarak gösterilecek paragraflar
  final List<String> paragraphs;

  /// 2. Çıktı (Düz Liste): Türkçe kısaltma korumalı bölünmüş TTS cümle listesi
  final List<String> sentences;

  /// 2. Çıktı (Eşleşmeli Liste): Her TTS cümlesinin hangi paragrafa ait olduğunu tutar
  final List<TtsSentence> ttsSentences;

  /// Kullanıcının "Önsözü/İçindekileri atla" filtresinde bu bölümü dahil edip etmediği
  final bool isIncluded;

  const BookChapter({
    required this.index,
    required this.title,
    required this.startPage,
    required this.endPage,
    required this.paragraphs,
    required this.sentences,
    required this.ttsSentences,
    this.isIncluded = true,
  });

  BookChapter copyWith({
    int? index,
    String? title,
    int? startPage,
    int? endPage,
    List<String>? paragraphs,
    List<String>? sentences,
    List<TtsSentence>? ttsSentences,
    bool? isIncluded,
  }) {
    return BookChapter(
      index: index ?? this.index,
      title: title ?? this.title,
      startPage: startPage ?? this.startPage,
      endPage: endPage ?? this.endPage,
      paragraphs: paragraphs ?? this.paragraphs,
      sentences: sentences ?? this.sentences,
      ttsSentences: ttsSentences ?? this.ttsSentences,
      isIncluded: isIncluded ?? this.isIncluded,
    );
  }
}

/// Ayrıştırılmış ve temizlenmiş E-Kitap / Sesli Kitap modeli
class ParsedBook {
  final String id;
  final String title;
  final String author;
  final String filePath;
  final BookFormat format;
  final int totalPages;
  final int filterStartPage;
  final int filterEndPage;
  final List<BookChapter> chapters;
  final DateTime addedAt;

  const ParsedBook({
    required this.id,
    required this.title,
    required this.author,
    required this.filePath,
    required this.format,
    required this.totalPages,
    required this.filterStartPage,
    required this.filterEndPage,
    required this.chapters,
    required this.addedAt,
  });

  ParsedBook copyWith({
    String? title,
    String? author,
    int? filterStartPage,
    int? filterEndPage,
    List<BookChapter>? chapters,
  }) {
    return ParsedBook(
      id: id,
      title: title ?? this.title,
      author: author ?? this.author,
      filePath: filePath,
      format: format,
      totalPages: totalPages,
      filterStartPage: filterStartPage ?? this.filterStartPage,
      filterEndPage: filterEndPage ?? this.filterEndPage,
      chapters: chapters ?? this.chapters,
      addedAt: addedAt,
    );
  }
}
