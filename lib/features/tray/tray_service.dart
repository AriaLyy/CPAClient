import 'dart:async';
import 'dart:io';

import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:cpaclient/core/services/sandbox_config_service.dart';
import 'package:cpaclient/features/tray/native_tray_bridge.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';

class TrayService with TrayListener {
  TrayService({
    required SandboxConfigService sandboxConfig,
    required Future<void> Function() onOpenSettings,
    required Future<void> Function() onStopCore,
    required Future<void> Function() onExit,
    required AppLogService log,
    NativeTrayBridge? nativeTrayBridge,
  })  : _sandboxConfig = sandboxConfig,
        _onOpenSettings = onOpenSettings,
        _onStopCore = onStopCore,
        _onExit = onExit,
        _log = log,
        _nativeTrayBridge = nativeTrayBridge ?? NativeTrayBridge();
  final SandboxConfigService _sandboxConfig;
  final Future<void> Function() _onOpenSettings;
  final Future<void> Function() _onStopCore;
  final Future<void> Function() _onExit;
  final AppLogService _log;
  final NativeTrayBridge _nativeTrayBridge;
  int? _lastTrayIconMouseDownAtMs;

  Future<void> init() async {
    await _log.info('Tray init begin');
    trayManager.addListener(this);
    await trayManager.setIcon(
      _trayIconPath()!,
      isTemplate: Platform.isMacOS,
      iconSize: Platform.isMacOS ? 18 : 0,
    );
    await trayManager.setToolTip('CPAClient');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'webui', label: 'WebUI'),
          MenuItem(key: 'settings', label: '设置'),
          MenuItem(key: 'stop_core', label: '停止核心'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: '退出'),
        ],
      ),
    );
    await _log.info('Tray init completed');
  }

  String? _trayIconPath() {
    if (Platform.isWindows) {
      return 'windows/runner/resources/app_icon.ico';
    }
    if (Platform.isMacOS) {
      return 'macos/Runner/Assets.xcassets/AppIcon.appiconset/tray_icon_bw_128.png';
    }
    if (Platform.isLinux) {
      return 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png';
    }
    return null;
  }

  void _onTrayIconMouseDown() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastMs = _lastTrayIconMouseDownAtMs;
    _lastTrayIconMouseDownAtMs = nowMs;
    if (lastMs != null && nowMs - lastMs <= 500) {
      unawaited(_log.info('Tray icon double click'));
      unawaited(_onOpenSettings());
    }
  }

  @override
  void onTrayIconMouseDown() {
    _onTrayIconMouseDown();
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_onTrayIconRightMouseDown());
  }

  Future<void> _onTrayIconRightMouseDown() async {
    await _log.info('Tray right mouse down');
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key ?? '';
    unawaited(_onTrayMenuItemClick(key));
  }

  Future<void> _onTrayMenuItemClick(String key) async {
    await _log.info('Tray menu click: key=$key');
    switch (key) {
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
        await _log.info('Tray menu click ignored: key=$key');
    }
  }

  Future<void> _openWebui() async {
    final port = await _sandboxConfig.readPort();
    final url = Uri.parse('http://127.0.0.1:$port/management.html#/login');
    await _log.info('Tray open WebUI: $url');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> setDockVisible(bool visible) async {
    if (!Platform.isMacOS) {
      return;
    }
    await _nativeTrayBridge.setDockVisible(visible);
  }

  Future<void> dispose() async {
    await _log.info('Tray dispose begin');
    trayManager.removeListener(this);
    await trayManager.destroy();
    await _log.info('Tray dispose completed');
  }
}
