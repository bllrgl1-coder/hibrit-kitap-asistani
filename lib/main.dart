import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'screens/library_screen.dart';
import 'services/auto_cache_cleaner.dart';
import 'services/book_audio_handler.dart';
import 'services/hybrid_tts_controller.dart';
import 'services/sleep_timer_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _requestRequiredPermissions();

  // Uygulama açılışında önceki oturumdan kalan geçici MP3 önbelleğini temizle
  await AutoCacheCleaner.purgeAllTempAudioCache();

  // 1. Hibrit TTS Kontrolcüsü ve Akıllı Uyku Zamanlayıcısı (Faz 4 & Faz 5 - Aynen Korundu)
  final HybridTtsController ttsController = HybridTtsController();
  final SleepTimerService sleepTimerService = SleepTimerService(
    ttsController: ttsController,
  );

  // 2. Arka Plan Medya Servisi (AudioService) ve Kilit Ekranı Kontrolleri (Faz 5 - Aynen Korundu)
  late final BookAudioHandler audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: () => BookAudioHandler(ttsController: ttsController),
      config: const AudioServiceConfig(
        androidNotificationChannelId:
            'com.bilal.hibrit_kitap_asistani.channel.audio',
        androidNotificationChannelName: 'Hibrit Sesli Kitap Oynatıcı',
        androidNotificationChannelDescription:
            'Arka planda ve kilit ekranında kesintisiz sesli kitap kontrolleri',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (_) {
    audioHandler = BookAudioHandler(ttsController: ttsController);
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<HybridTtsController>.value(
          value: ttsController,
        ),
        ChangeNotifierProvider<SleepTimerService>.value(
          value: sleepTimerService,
        ),
        Provider<BookAudioHandler>.value(
          value: audioHandler,
        ),
      ],
      child: const HibritKitapAsistaniApp(),
    ),
  );
}

Future<void> _requestRequiredPermissions() async {
  final notificationStatus = await Permission.notification.status;
  if (notificationStatus.isDenied) {
    await Permission.notification.request();
  }
}

class HibritKitapAsistaniApp extends StatelessWidget {
  const HibritKitapAsistaniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kişisel Hibrit Kitap Asistanı',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const LibraryScreen(),
    );
  }
}
