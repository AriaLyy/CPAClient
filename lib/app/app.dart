import 'dart:io';

import 'package:cpaclient/features/settings/settings_page.dart';
import 'package:flutter/material.dart';

class CpaClientApp extends StatefulWidget {
  const CpaClientApp({super.key, required this.initialThemeMode});

  final ThemeMode initialThemeMode;

  @override
  State<CpaClientApp> createState() => _CpaClientAppState();
}

class _CpaClientAppState extends State<CpaClientApp> {
  late ThemeMode _themeMode;

  List<String> get _fontFallbacks {
    if (Platform.isWindows) {
      return const <String>[
        '微软雅黑',
        'Microsoft YaHei',
        'Segoe UI',
        'sans-serif',
      ];
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return const <String>['PingFang SC', 'Helvetica Neue', 'sans-serif'];
    }
    if (Platform.isAndroid) {
      return const <String>['Noto Sans CJK SC', 'sans-serif'];
    }
    if (Platform.isLinux) {
      return const <String>[
        'Noto Sans CJK SC',
        'WenQuanYi Zen Hei',
        'sans-serif'
      ];
    }
    return const <String>['sans-serif'];
  }

  @override
  void initState() {
    super.initState();
    _themeMode = widget.initialThemeMode;
  }

  void _onThemeModeChanged(ThemeMode mode) {
    if (_themeMode == mode) {
      return;
    }
    setState(() {
      _themeMode = mode;
    });
  }

  ThemeData _buildTheme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    );

    final base = ThemeData(
      primarySwatch: Colors.indigo,
      colorScheme: colorScheme,
      useMaterial3: true,
    );

    final primaryTextColor = colorScheme.onSurface;
    final secondaryTextColor = colorScheme.onSurfaceVariant;
    final fontFallbacks = _fontFallbacks;

    final baseTextTheme = base.textTheme
        .apply(bodyColor: primaryTextColor, displayColor: primaryTextColor);

    final textTheme = baseTextTheme.copyWith(
      titleSmall: baseTextTheme.titleSmall?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: primaryTextColor,
        fontFamilyFallback: fontFallbacks,
      ),
      labelMedium: baseTextTheme.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: secondaryTextColor,
        fontFamilyFallback: fontFallbacks,
      ),
      labelSmall: baseTextTheme.labelSmall?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: secondaryTextColor,
        fontFamilyFallback: fontFallbacks,
      ),
      bodyLarge: baseTextTheme.bodyLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: primaryTextColor,
        fontFamilyFallback: fontFallbacks,
      ),
      bodyMedium: baseTextTheme.bodyMedium?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: primaryTextColor,
        fontFamilyFallback: fontFallbacks,
      ),
      bodySmall: baseTextTheme.bodySmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: primaryTextColor,
        fontFamilyFallback: fontFallbacks,
      ),
    );

    final inputDecorationTheme = InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerLowest,
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(
          color: brightness == Brightness.light
              ? colorScheme.outline
              : colorScheme.outlineVariant,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      isDense: true,
      hintStyle: textTheme.bodySmall,
      helperStyle: textTheme.bodySmall,
    );

    const controlMinHeight = 38.0;
    const controlPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );

    return base.copyWith(
      scaffoldBackgroundColor:
          brightness == Brightness.light ? Colors.white : null,
      textTheme: textTheme,
      inputDecorationTheme: inputDecorationTheme,
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, controlMinHeight),
          padding: controlPadding,
          shape: controlShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, controlMinHeight),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: controlShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, controlMinHeight),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: controlShape,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CPAClient',
      themeMode: _themeMode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: SettingsPage(onThemeModeChanged: _onThemeModeChanged),
    );
  }
}
