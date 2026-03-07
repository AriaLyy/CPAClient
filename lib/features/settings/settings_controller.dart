import 'dart:async';
import 'dart:io';

import 'package:cpaclient/core/constants/core_defaults.dart';
import 'package:cpaclient/core/models/app_settings.dart';
import 'package:cpaclient/core/services/app_services.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webdav_client/webdav_client.dart';

class SettingsController extends ChangeNotifier {
  SettingsController();

  AppSettings settings = AppSettings.defaults();
  bool launchAtStartupEnabled = false;
  String lastStatus = '';
  int currentPort = 8317;
  String webuiPassword = '';
  List<String> recentVersions = const [];

  ThemeMode get themeMode {
    switch (settings.themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> load() async {
    settings = await AppServices.settings.load();
    await refreshRecentVersions();

    var startupReady = true;
    try {
      await AppServices.startup.ensureReady();
    } catch (e) {
      startupReady = false;
      await AppServices.log.error('Startup ensureReady failed', e);
      _setStatus('核心未运行: $e');
    }

    launchAtStartup.setup(
      appName: 'CPAClient',
      appPath: Platform.resolvedExecutable,
    );
    try {
      launchAtStartupEnabled = await launchAtStartup.isEnabled();
    } on UnsupportedError {
      launchAtStartupEnabled = false;
    }
    currentPort = await AppServices.sandboxConfig.readPort();
    webuiPassword = await AppServices.sandboxConfig.readSecretKey();
    _startStatusPolling();
    if (startupReady) {
      lastStatus = '';
    }
  }

  Future<String> setLaunchAtStartup(bool value) async {
    try {
      if (value) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
      launchAtStartupEnabled = await launchAtStartup.isEnabled();
      notifyListeners();
      return launchAtStartupEnabled ? '已开启开机启动' : '已关闭开机启动';
    } on UnsupportedError {
      return '当前运行环境不支持开机启动（请使用打包后的桌面应用）';
    } catch (e) {
      return '开机启动设置失败: $e';
    }
  }

  Future<String> updateVersion(String value) async {
    final version = value.trim();
    if (!recentVersions.contains(version)) {
      return '请选择最近发布的版本';
    }
    settings = settings.copyWith(coreVersion: version);
    await AppServices.settings.save(settings);
    notifyListeners();
    return '核心版本已更新为 $version';
  }

  Future<String> saveWebdavForm({
    required String url,
    required String username,
    required String password,
  }) async {
    final inputUrl = url.trim();
    if (inputUrl.endsWith('/')) {
      return 'WebDAV 地址不能以 / 结尾';
    }
    final normalizedUrl = inputUrl.endsWith('/CpaClient') ? inputUrl : '$inputUrl/CpaClient';
    settings = settings.copyWith(
      webdavUrl: normalizedUrl,
      webdavUsername: username.trim(),
      webdavPassword: password,
    );
    await AppServices.settings.save(settings);
    notifyListeners();
    return 'WebDAV 设置已保存: $normalizedUrl';
  }

  Future<void> reloadWebdavSettings() async {
    settings = await AppServices.settings.load();
    notifyListeners();
  }

  Future<String> testWebdavConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    final inputUrl = url.trim();
    if (inputUrl.isEmpty) {
      return '请先填写 WebDAV 地址';
    }
    if (inputUrl.endsWith('/')) {
      return 'WebDAV 地址不能以 / 结尾';
    }
    final normalizedUrl = inputUrl.endsWith('/CpaClient') ? inputUrl : '$inputUrl/CpaClient';
    try {
      await AppServices.log.info('WebDAV test start: url=$normalizedUrl user=${username.trim()}');
      final client = newClient(
        normalizedUrl,
        user: username.trim(),
        password: password,
        debug: true,
      );
      await client.ping();
      await AppServices.log.info('WebDAV test success: url=$normalizedUrl');
      return 'WebDAV 连接成功';
    } catch (e) {
      await AppServices.log.error('WebDAV test failed: url=$normalizedUrl', _formatDioError(e));
      return 'WebDAV 连接失败: $e';
    }
  }

  Future<String> backupConfigToWebdav() async {
    if (settings.webdavUrl.trim().isEmpty) {
      return '请先填写 WebDAV 地址';
    }
    try {
      final cfg = await AppServices.sandboxConfig.ensureSandboxConfig();
      await AppServices.log.info('WebDAV backup start: url=${settings.webdavUrl} local=${cfg.path}');
      final client = newClient(
        settings.webdavUrl,
        user: settings.webdavUsername,
        password: settings.webdavPassword,
        debug: false,
      );
      try {
        await _writeConfigToWebdav(client: client, localConfigPath: cfg.path);
      } catch (e) {
        if (_shouldTryParentFallback(e)) {
          await _writeConfigToWebdavFromParent(localConfigPath: cfg.path);
        } else {
          rethrow;
        }
      }
      await AppServices.log.info('WebDAV backup success');
      return '已备份到 config.yaml';
    } catch (e) {
      await AppServices.log.error('WebDAV backup failed', _formatDioError(e));
      return 'WebDAV 备份失败: $e';
    }
  }

  Future<String> restoreConfigFromWebdav() async {
    if (settings.webdavUrl.trim().isEmpty) {
      return '请先填写 WebDAV 地址';
    }
    try {
      final cfg = await AppServices.sandboxConfig.ensureSandboxConfig();
      await AppServices.log.info('WebDAV restore start: url=${settings.webdavUrl} local=${cfg.path}');
      final client = newClient(
        settings.webdavUrl,
        user: settings.webdavUsername,
        password: settings.webdavPassword,
        debug: false,
      );
      try {
        await _readConfigFromWebdav(client: client, localConfigPath: cfg.path);
      } catch (e) {
        if (_shouldTryParentFallback(e)) {
          await _readConfigFromWebdavFromParent(localConfigPath: cfg.path);
        } else {
          rethrow;
        }
      }
      currentPort = await AppServices.sandboxConfig.readPort();
      notifyListeners();
      await AppServices.log.info('WebDAV restore success');
      return '已从 config.yaml 还原';
    } catch (e) {
      await AppServices.log.error('WebDAV restore failed', _formatDioError(e));
      return 'WebDAV 还原失败: $e';
    }
  }

  Future<void> _writeConfigToWebdav({
    required dynamic client,
    required String localConfigPath,
  }) async {
    await _writeConfigWithCandidates(
      client: client,
      localConfigPath: localConfigPath,
      remoteCandidates: const ['config.yaml', '/config.yaml'],
      logPrefix: 'WebDAV backup',
    );
  }

  Future<void> _writeConfigToWebdavFromParent({required String localConfigPath}) async {
    final parentUrl = _parentWebdavUrl(settings.webdavUrl);
    if (parentUrl == settings.webdavUrl) {
      throw Exception('父级 WebDAV 地址未变化，无法执行回退写入');
    }
    await AppServices.log.info('WebDAV backup fallback to parent url: $parentUrl');
    final parentClient = newClient(
      parentUrl,
      user: settings.webdavUsername,
      password: settings.webdavPassword,
      debug: false,
    );
    await _writeConfigWithCandidates(
      client: parentClient,
      localConfigPath: localConfigPath,
      remoteCandidates: const [
        'CpaClient/config.yaml',
        '/CpaClient/config.yaml',
        'config.yaml',
        '/config.yaml',
      ],
      logPrefix: 'WebDAV backup(parent)',
    );
  }

  Future<void> _writeConfigWithCandidates({
    required dynamic client,
    required String localConfigPath,
    required List<String> remoteCandidates,
    required String logPrefix,
  }) async {
    Object? lastError;
    for (final remotePath in remoteCandidates) {
      try {
        await AppServices.log.info('$logPrefix try path: $remotePath');
        await client.writeFromFile(localConfigPath, remotePath);
        await AppServices.log.info('$logPrefix path success: $remotePath');
        return;
      } catch (e) {
        lastError = e;
        await AppServices.log.error('$logPrefix path failed: $remotePath', _formatDioError(e));
      }
    }
    throw Exception('上传 config.yaml 失败: ${_formatDioError(lastError ?? 'unknown error')}');
  }

  Future<void> _readConfigFromWebdav({
    required dynamic client,
    required String localConfigPath,
  }) async {
    await _readConfigWithCandidates(
      client: client,
      localConfigPath: localConfigPath,
      remoteCandidates: const ['config.yaml', '/config.yaml'],
      logPrefix: 'WebDAV restore',
    );
  }

  Future<void> _readConfigFromWebdavFromParent({required String localConfigPath}) async {
    final parentUrl = _parentWebdavUrl(settings.webdavUrl);
    if (parentUrl == settings.webdavUrl) {
      throw Exception('父级 WebDAV 地址未变化，无法执行回退读取');
    }
    await AppServices.log.info('WebDAV restore fallback to parent url: $parentUrl');
    final parentClient = newClient(
      parentUrl,
      user: settings.webdavUsername,
      password: settings.webdavPassword,
      debug: false,
    );
    await _readConfigWithCandidates(
      client: parentClient,
      localConfigPath: localConfigPath,
      remoteCandidates: const [
        'CpaClient/config.yaml',
        '/CpaClient/config.yaml',
        'config.yaml',
        '/config.yaml',
      ],
      logPrefix: 'WebDAV restore(parent)',
    );
  }

  Future<void> _readConfigWithCandidates({
    required dynamic client,
    required String localConfigPath,
    required List<String> remoteCandidates,
    required String logPrefix,
  }) async {
    Object? lastError;
    for (final remotePath in remoteCandidates) {
      try {
        await AppServices.log.info('$logPrefix try path: $remotePath');
        await client.read2File(remotePath, localConfigPath);
        await AppServices.log.info('$logPrefix path success: $remotePath');
        return;
      } catch (e) {
        lastError = e;
        await AppServices.log.error('$logPrefix path failed: $remotePath', _formatDioError(e));
      }
    }
    throw Exception('下载 config.yaml 失败: ${_formatDioError(lastError ?? 'unknown error')}');
  }

  bool _shouldTryParentFallback(Object error) {
    if (error is DioException) {
      if (error.response?.statusCode == 409) {
        return true;
      }
      final body = error.response?.data?.toString() ?? '';
      if (body.contains('AncestorsNotFound')) {
        return true;
      }
    }
    final text = error.toString();
    return text.contains('status=409') || text.contains('AncestorsNotFound');
  }

  String _parentWebdavUrl(String url) {
    final uri = Uri.parse(url);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      return url;
    }
    final parentSegments = segments.sublist(0, segments.length - 1);
    final parentPath = parentSegments.isEmpty ? '/' : '/${parentSegments.join('/')}';
    return uri.replace(path: parentPath).toString();
  }

  String _formatDioError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final method = error.requestOptions.method;
      final uri = error.requestOptions.uri;
      final data = error.response?.data;
      final body = data == null ? 'null' : data.toString();
      return 'DioException(type=${error.type}, status=$status, method=$method, uri=$uri, message=${error.message}, body=$body)';
    }
    return error.toString();
  }

  Future<String> openAbout() async {
    try {
      final uri = Uri.parse(CoreDefaults.aboutUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return '已打开关于页面';
    } catch (e) {
      return '打开关于页面失败: $e';
    }
  }

  Future<String> updateCore() async {
    try {
      await AppServices.startup.updateCore(
        version: settings.coreVersion,
        githubToken: settings.githubToken,
      );
      currentPort = await AppServices.sandboxConfig.readPort();
      notifyListeners();
      return '核心更新完成并已重启';
    } catch (e) {
      final logPath = await AppServices.log.logFilePath();
      return '核心更新失败: $e\n日志: $logPath';
    }
  }

  Future<String> saveGithubToken(String value) async {
    final token = value.trim();
    settings = settings.copyWith(githubToken: token);
    await AppServices.settings.save(settings);
    await refreshRecentVersions();
    notifyListeners();
    return token.isEmpty ? 'GitHub Token 已清空' : 'GitHub Token 已保存';
  }

  Future<String> saveThemeMode(ThemeMode mode) async {
    final modeValue = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    settings = settings.copyWith(themeMode: modeValue);
    await AppServices.settings.save(settings);
    notifyListeners();
    return '主题已切换';
  }

  Future<String> saveWebuiPassword(String value) async {
    final secret = value.trim();
    if (secret.isEmpty) {
      return 'WebUI 密码不能为空';
    }
    try {
      await AppServices.sandboxConfig.updateSecretKey(secret);
      webuiPassword = secret;
      notifyListeners();
      return 'WebUI 密码已同步到 secret-key';
    } catch (e) {
      return 'WebUI 密码保存失败: $e';
    }
  }

  Future<void> refreshRecentVersions() async {
    try {
      if (settings.githubToken.trim().isNotEmpty) {
        final versions = await AppServices.githubRelease.fetchRecentVersions(
          githubToken: settings.githubToken,
          limit: 20,
        );
        recentVersions = versions;
      }
      if (recentVersions.isEmpty) {
        recentVersions = [settings.coreVersion];
      }
      if (recentVersions.isNotEmpty && !recentVersions.contains(settings.coreVersion)) {
        settings = settings.copyWith(coreVersion: recentVersions.first);
        await AppServices.settings.save(settings);
      }
    } catch (e) {
      await AppServices.log.error('Load recent versions failed', e);
      recentVersions = settings.coreVersion.trim().isEmpty ? const [] : [settings.coreVersion];
    }
  }

  bool get isCoreRunning => AppServices.process.isRunning;

  Timer? _statusTimer;

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      notifyListeners();
    });
  }

  bool get needsGithubToken => settings.githubToken.trim().isEmpty;

  Future<String> openGithubTokenPage() async {
    try {
      final uri = Uri.parse(CoreDefaults.githubTokenUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return '已打开 GitHub Token 页面';
    } catch (e) {
      return '打开 GitHub Token 页面失败: $e';
    }
  }

  void _setStatus(String value) {
    lastStatus = value;
    notifyListeners();
  }

  Future<void> disposeController() async {
    _statusTimer?.cancel();
    _statusTimer = null;
    await AppServices.startup.shutdown();
  }
}
