import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'audio_handler.dart';
import 'library_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  audioHandler = await AudioService.init(
    builder: () => TtsAudioHandler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.example.wanna_read.tts',
      androidNotificationChannelName: 'Reading',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wanna Read',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const LibraryScreen(),
    );
  }
}
