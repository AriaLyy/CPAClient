import 'package:cpaclient/features/settings/settings_page.dart';
import 'package:flutter/material.dart';

class CpaClientApp extends StatefulWidget {
  const CpaClientApp({super.key, required this.initialThemeMode});

  final ThemeMode initialThemeMode;

  @override
  State<CpaClientApp> createState() => _CpaClientAppState();
}

class _CpaClientAppState extends State<CpaClientApp> {
  static const _fontFamily = 'NotoSansSC';

  late ThemeMode _themeMode;

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
      fontFamily: _fontFamily,
    );

    final primaryTextColor = colorScheme.onSurface;
    final secondaryTextColor = colorScheme.onSurfaceVariant;

    final textTheme = base.textTheme
        .apply(bodyColor: primaryTextColor, displayColor: primaryTextColor)
        .copyWith(
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: primaryTextColor,
          ),
          labelMedium: base.textTheme.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: secondaryTextColor,
          ),
          labelSmall: base.textTheme.labelSmall?.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: secondaryTextColor,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: primaryTextColor,
          ),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 12,
            color: primaryTextColor,
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
