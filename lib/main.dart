import 'package:cpaclient/app/app.dart';
import 'package:cpaclient/core/services/app_services.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const fixedWindowSize = Size(860, 640);
  const options = WindowOptions(
    size: fixedWindowSize,
    minimumSize: fixedWindowSize,
    maximumSize: fixedWindowSize,
    center: true,
    title: 'CPAClient',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setResizable(false);
    await windowManager.show();
    await windowManager.focus();
  });

  final settings = await AppServices.settings.load();
  final initialThemeMode = switch (settings.themeMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  runApp(CpaClientApp(initialThemeMode: initialThemeMode));
}
