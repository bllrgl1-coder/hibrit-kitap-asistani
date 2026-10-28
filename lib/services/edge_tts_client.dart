import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

/// Doğal Türkçe Nöral Ses Seçenekleri (Microsoft Edge Neural TTS)
enum TurkishNeuralVoice {
  ahmet(
    shortName: 'tr-TR-AhmetNeural',
    displayName: 'Ahmet (Doğal Erkek Sesi)',
    gender: 'Male',
  ),
  emel(
    shortName: 'tr-TR-EmelNeural',
    displayName: 'Emel (Doğal Kadın Sesi)',
    gender: 'Female',
  );

  final String shortName;
  final String displayName;
  final String gender;

  const TurkishNeuralVoice({
    required this.shortName,
    required this.displayName,
    required this.gender,
  });
}

/// Microsoft Edge Neural TTS WebSocket İstemcisi.
/// SSML `<prosody>` etiketi ile hız kontrolü yapar ve gelen MP3 akışını
/// geçici önbellek dizinine (`path_provider` temp) kaydeder.
class EdgeTtsClient {
  static const String _trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const String _baseWsUrl =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';

  final Uuid _uuid = const Uuid();

  /// Hız çarpanını (örn. 0.8x -> -20%, 1.0x -> +0%, 1.5x -> +50%, 2.0x -> +100%)
  /// SSML `<prosody rate="...">` formatına dönüştürür.
  static String formatProsodyRate(double speedMultiplier) {
    final double clamped = speedMultiplier.clamp(0.75, 2.0);
    final int percentDelta = ((clamped - 1.0) * 100).round();
    if (percentDelta >= 0) {
      return '+$percentDelta%';
    } else {
      return '$percentDelta%';
    }
  }

  /// Edge TTS WebSocket sunucusu için güncel Sec-MS-GEC güvenlik anahtarını üretir.
  static String _generateSecMsGecToken() {
    // Windows epoch (1601-01-01) farkı: 11644473600 saniye
    double ticks = (DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0) +
        11644473600.0;
    ticks -= ticks % 300; // 5 dakikalık yuvarlama
    ticks *= 10000000; // 100-nanosaniye birimine çevir
    final String strToHash = '${ticks.toStringAsFixed(0)}$_trustedClientToken';
    return sha256.convert(utf8.encode(strToHash)).toString().toUpperCase();
  }

  /// Verilen cümleyi Microsoft Edge Neural TTS üzerinden MP3 dosyasına dönüştürür
  /// ve `getTemporaryDirectory()` altında bir `File` olarak döner.
  Future<File> synthesizeToTempMp3({
    required String sentenceText,
    required TurkishNeuralVoice voice,
    required double speedMultiplier,
    required String cacheKey,
    Duration timeout = const Duration(seconds: 7),
  }) async {
    final Directory tempDir = await getTemporaryDirectory();
    final Directory ttsCacheDir = Directory('${tempDir.path}/edge_tts_cache');
    if (!await ttsCacheDir.exists()) {
      await ttsCacheDir.create(recursive: true);
    }

    final File targetFile = File('${ttsCacheDir.path}/$cacheKey.mp3');
    if (await targetFile.exists() && await targetFile.length() > 128) {
      return targetFile;
    }

    final String requestId = _uuid.v4().replaceAll('-', '');
    final String secMsGec = _generateSecMsGecToken();
    final String wsUrl =
        '$_baseWsUrl?TrustedClientToken=$_trustedClientToken&Sec-MS-GEC=$secMsGec&Sec-MS-GEC-Version=1-130.0.2849.68&ConnectionId=$requestId';

    IOWebSocketChannel? channel;
    final Completer<File> completer = Completer<File>();
    final BytesBuilder audioBytesBuilder = BytesBuilder(copy: false);

    try {
      final WebSocket ws = await WebSocket.connect(
        wsUrl,
        headers: {
          'Pragma': 'no-cache',
          'Cache-Control': 'no-cache',
          'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0',
        },
      ).timeout(timeout);

      channel = IOWebSocketChannel(ws);

      // 1. Konfigürasyon başlığını gönder (24khz 48kbps mono mp3)
      final String timestamp = DateTime.now().toUtc().toIso8601String();
      final String configPayload =
          'X-Timestamp:$timestamp\r\n'
          'Content-Type:application/json; charset=utf-8\r\n'
          'Path:speech.config\r\n\r\n'
          '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}';

      channel.sink.add(configPayload);

      // 2. SSML içeriğini oluştur ve gönder (<prosody rate="..."> ile hız kontrolü)
      final String prosodyRate = formatProsodyRate(speedMultiplier);
      final String escapedText = _escapeXml(sentenceText);
      final String ssml =
          "<speak version='1.0' xmlns='http://www.w3.org/2001/10/speak' xml:lang='tr-TR'>"
          "<voice name='${voice.shortName}'>"
          "<prosody pitch='+0Hz' rate='$prosodyRate' volume='+0%'>"
          "$escapedText"
          "</prosody>"
          "</voice>"
          "</speak>";

      final String ssmlMessage =
          'X-RequestId:$requestId\r\n'
          'Content-Type:application/ssml+xml\r\n'
          'X-Timestamp:${timestamp}Z\r\n'
          'Path:ssml\r\n\r\n'
          '$ssml';

      channel.sink.add(ssmlMessage);

      // 3. Gelen ses paketlerini (Path:audio) ve bitiş sinyalini (Path:turn.end) dinle
      StreamSubscription? sub;
      sub = channel.stream.listen(
        (dynamic message) async {
          if (message is String) {
            if (message.contains('Path:turn.end')) {
              await sub?.cancel();
              await channel?.sink.close();

              final Uint8List mp3Bytes = audioBytesBuilder.takeBytes();
              if (mp3Bytes.isEmpty) {
                if (!completer.isCompleted) {
                  completer.completeError(
                    StateError('Edge TTS boş ses verisi döndürdü.'),
                  );
                }
                return;
              }

              await targetFile.writeAsBytes(mp3Bytes, flush: true);
              if (!completer.isCompleted) {
                completer.complete(targetFile);
              }
            }
          } else if (message is List<int>) {
            final Uint8List data =
                message is Uint8List ? message : Uint8List.fromList(message);
            if (data.length > 2) {
              // İlk 2 byte header uzunluğunu (big-endian uint16) verir
              final int headerLength = (data[0] << 8) | data[1];
              final int audioStartOffset = 2 + headerLength;
              if (audioStartOffset < data.length) {
                final String headerStr = utf8.decode(
                  data.sublist(2, audioStartOffset),
                  allowMalformed: true,
                );
                if (headerStr.contains('Path:audio')) {
                  audioBytesBuilder.add(data.sublist(audioStartOffset));
                }
              }
            }
          }
        },
        onError: (Object error) {
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.completeError(
              StateError('Edge TTS WebSocket bağlantısı beklenmedik şekilde kapandı.'),
            );
          }
        },
        cancelOnError: true,
      );

      return await completer.future.timeout(timeout);
    } catch (e) {
      await channel?.sink.close();
      rethrow;
    }
  }

  static String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
