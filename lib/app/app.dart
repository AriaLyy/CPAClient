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

  @override
  Widget build(BuildContext context) {
    final fontFamily = Platform.isWindows ? 'Microsoft YaHei' : null;

    return MaterialApp(
      title: 'CPAClient',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        fontFamily: fontFamily,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
        useMaterial3: true,
        fontFamily: fontFamily,
      ),
      home: SettingsPage(onThemeModeChanged: _onThemeModeChanged),
    );
  }
}
