import 'package:flutter/material.dart';
import 'screens/main_shell_screen.dart';
import 'widgets/platform_bootstrap_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PlatformBootstrapGate(child: MyApp()));
}

/// Root widget for Lingua Canvas application.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const LinguaCanvasApp();
  }
}

/// Configures the minimalist dark-mode IT workplace theme and mounts MainShellScreen.
class LinguaCanvasApp extends StatelessWidget {
  const LinguaCanvasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lingua Canvas',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
          surface: const Color(0xFF1E293B),
        ),
        useMaterial3: true,
      ),
      home: const MainShellScreen(),
    );
  }
}
