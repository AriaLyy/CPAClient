import 'dart:async';
import 'dart:io';

import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:cpaclient/core/services/sandbox_config_service.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';

class TrayService with TrayListener {
  TrayService({
    required SandboxConfigService sandboxConfig,
    required Future<void> Function() onOpenSettings,
    required Future<void> Function() onStopCore,
    required Future<void> Function() onExit,
    required AppLogService log,
  })  : _sandboxConfig = sandboxConfig,
        _onOpenSettings = onOpenSettings,
        _onStopCore = onStopCore,
        _onExit = onExit,
        _log = log;

  final SandboxConfigService _sandboxConfig;
  final Future<void> Function() _onOpenSettings;
  final Future<void> Function() _onStopCore;
  final Future<void> Function() _onExit;
  final AppLogService _log;

  Future<void> init() async {
    await _log.info('Tray init begin');
    trayManager.addListener(this);
    final iconPath = _trayIconPath();
    if (iconPath != null) {
      await _log.info('Tray set icon: $iconPath');
      await trayManager.setIcon(iconPath);
    } else {
      await _log.info('Tray icon not found, skip setIcon');
    }
    await trayManager.setToolTip('CPAClient');
    await trayManager.setContextMenu(
      Menu(items: [
        MenuItem(key: 'webui', label: 'WebUI'),
        MenuItem(key: 'settings', label: '设置'),
        MenuItem(key: 'stop_core', label: '停止核心'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]),
    );
    await _log.info('Tray init completed');
  }

  String? _trayIconPath() {
    final candidates = <String>[];
    if (Platform.isWindows) {
      candidates.add('windows/runner/resources/app_icon.ico');
    }
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      candidates.add('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png');
      candidates.add('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png');
      candidates.add('macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png');
    }

    for (final relativePath in candidates) {
      final local = File(relativePath);
      if (local.existsSync()) {
        return local.absolute.path;
      }
      final fromCwd = File(p.join(Directory.current.path, relativePath));
      if (fromCwd.existsSync()) {
        return fromCwd.absolute.path;
      }
    }
    return null;
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_log.info('Tray right mouse down'));
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayIconRightMouseUp() {
    unawaited(_log.info('Tray right mouse up'));
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    await _log.info('Tray menu click: key=${menuItem.key}');
    switch (menuItem.key) {
      case 'webui':
        await _openWebui();
        break;
      case 'settings':
        await _onOpenSettings();
        break;
      case 'stop_core':
        await _onStopCore();
        break;
      case 'quit':
        await _onExit();
        break;
      default:
        await _log.info('Tray menu click ignored: key=${menuItem.key}');
    }
  }

  Future<void> _openWebui() async {
    final port = await _sandboxConfig.readPort();
    final url = Uri.parse('http://127.0.0.1:$port/management.html#/login');
    await _log.info('Tray open WebUI: $url');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> dispose() async {
    await _log.info('Tray dispose begin');
    trayManager.removeListener(this);
    await trayManager.destroy();
    await _log.info('Tray dispose completed');
  }
}
