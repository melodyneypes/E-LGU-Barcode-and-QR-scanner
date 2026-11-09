import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'services/api_service.dart';
import 'services/realtime_service.dart';
import 'theme/theme_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {
    // Graceful fallback if .env is missing in certain test environments
  }
  await ThemeController.init();
  await RealtimeService.instance.initialize();
  final token = await ApiService.getToken();

  runApp(FrontdeskScannerApp(hasSavedSession: token != null && token.isNotEmpty));
}

class FrontdeskScannerApp extends StatelessWidget {
  final bool hasSavedSession;
  const FrontdeskScannerApp({super.key, required this.hasSavedSession});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.themeMode,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'Queue No. Scanner',
          debugShowCheckedModeBanner: false,
          themeMode: currentMode,
          theme: ThemeData(
            fontFamily: 'Roboto',
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF8FAFC),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF1E3A8A),
              primary: const Color(0xFF1E3A8A),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            fontFamily: 'Roboto',
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF0B0F17),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF3B82F6),
              primary: const Color(0xFF3B82F6),
              brightness: Brightness.dark,
              surface: const Color(0xFF151C28),
            ),
            cardTheme: const CardThemeData(
              color: Color(0xFF151C28),
            ),
            useMaterial3: true,
          ),
          home: hasSavedSession ? const HomeScreen() : const LoginScreen(),
        );
      },
    );
  }
}
