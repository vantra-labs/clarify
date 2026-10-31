import 'package:flutter/material.dart';

/// Урезанная копия токенов Clarify (frontend/lib/core/theme/design_tokens.dart).
/// Копия, а не импорт: установщик — отдельное приложение и отдельный
/// репозиторий-каталог, тянуть весь пакет приложения ради шести цветов значило
/// бы тянуть и Supabase, и Hive, и всё остальное. Значения обязаны совпадать с
/// docs/DESIGN_SYSTEM.md — установщик должен читаться как часть продукта.
class InstallerTokens {
  InstallerTokens._();

  static const Color bg = Color(0xFF0F1115);
  static const Color surface = Color(0xFF161A21);
  static const Color surfaceSunken = Color(0xFF11141A);
  static const Color border = Color(0x1FFFFFFF);
  static const Color borderStrong = Color(0x2EFFFFFF);

  static const Color text = Color(0xFFF2F4F8);
  static const Color text2 = Color(0xFF9BA3B4);
  static const Color text3 = Color(0xFF6B7382);

  static const Color accent = Color(0xFF6366F1);
  static const Color accentHover = Color(0xFF7C7EF4);
  static const Color accentSoft = Color(0x336366F1);
  static const Color onAccent = Colors.white;

  static const Color danger = Color(0xFFF87171);
  static const Color success = Color(0xFF34D399);
}

class InstallerRadius {
  InstallerRadius._();
  static const double sm = 8;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;
}

class InstallerMotion {
  InstallerMotion._();
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 180);
  static const Duration slow = Duration(milliseconds: 280);
  static const Duration deliberate = Duration(milliseconds: 420);
  static const Curve standard = Cubic(0.2, 0.7, 0.3, 1.0);
}

ThemeData buildInstallerTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    fontFamily: 'Golos Text',
    scaffoldBackgroundColor: InstallerTokens.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: InstallerTokens.accent,
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
  );
}
