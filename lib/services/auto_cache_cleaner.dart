import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Edge-TTS'ten önbelleğe (`getTemporaryDirectory()/edge_tts_cache`) indirilen
/// geçici MP3 parçalarının telefon hafızasını şişirmemesi için okunup geçilen
/// ve süresi dolan geçici ses dosyalarını otomatik silen temizleyici servis.
class AutoCacheCleaner {
  static const String _cacheFolderName = 'edge_tts_cache';

  /// Belirli bir cümle indeksinden önce oluşturulmuş geçici ses dosyalarını siler.
  static Future<void> cleanPassedSentenceFiles({
    required String bookId,
    required int chapterIndex,
    required int keepFromSentenceIndex,
  }) async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final Directory cacheDir = Directory('${tempDir.path}/$_cacheFolderName');
      if (!await cacheDir.exists()) return;

      final String prefix = 'b_${bookId}_c_${chapterIndex}_s_';
      await for (final FileSystemEntity entity in cacheDir.list()) {
        if (entity is File) {
          final String fileName = entity.uri.pathSegments.last;
          if (fileName.startsWith(prefix)) {
            final List<String> parts =
                fileName.substring(prefix.length).split('_');
            if (parts.isNotEmpty) {
              final int? sIdx = int.tryParse(parts.first);
              if (sIdx != null && sIdx < keepFromSentenceIndex) {
                await entity.delete().catchError((_) => entity);
              }
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Uygulama açılışında veya önbellek boyutu büyüdüğünde eski geçici MP3 dosyalarını temizler.
  static Future<int> purgeAllTempAudioCache() async {
    int deletedCount = 0;
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final Directory cacheDir = Directory('${tempDir.path}/$_cacheFolderName');
      if (!await cacheDir.exists()) return 0;

      await for (final FileSystemEntity entity in cacheDir.list()) {
        if (entity is File && entity.path.endsWith('.mp3')) {
          await entity.delete().catchError((_) => entity);
          deletedCount++;
        }
      }
    } catch (_) {}
    return deletedCount;
  }

  /// Mevcut önbellek boyutunu MB cinsinden hesaplar.
  static Future<double> getCacheSizeInMb() async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final Directory cacheDir = Directory('${tempDir.path}/$_cacheFolderName');
      if (!await cacheDir.exists()) return 0.0;

      int totalBytes = 0;
      await for (final FileSystemEntity entity in cacheDir.list()) {
        if (entity is File) {
          totalBytes += await entity.length();
        }
      }
      return totalBytes / (1024 * 1024);
    } catch (_) {
      return 0.0;
    }
  }
}
