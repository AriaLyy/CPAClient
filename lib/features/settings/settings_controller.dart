import 'dart:async';
import 'dart:io';

import 'package:cpaclient/core/constants/core_defaults.dart';
import 'package:cpaclient/core/models/app_settings.dart';
import 'package:cpaclient/core/models/webdav_backup_version.dart';
import 'package:cpaclient/core/services/app_services.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:url_launcher/url_launcher.dart';

enum WebdavStatusLevel { idle, running, success, failure }

class SettingsController extends ChangeNotifier {
  SettingsController();

  static const Duration _localUsageExportInterval = Duration(minutes: 1);
  static const Duration _postCoreReadyUsageImportDelay = Duration(seconds: 20);
  static const String _defaultWebuiPassword = '123456';
  static const int webdavAutoBackupOnStartupOnly = -1;
  static const List<int> webdavAutoBackupIntervals = <int>[
    5,
    30,
    60,
    360,
    1440,
    webdavAutoBackupOnStartupOnly,
  ];

  AppSettings settings = AppSettings.defaults();
  bool launchAtStartupEnabled = false;
  String lastStatus = '';
  int currentPort = 8317;
  String webuiPassword = '';
  List<String> recentVersions = const [];
  WebdavStatusLevel webdavStatusLevel = WebdavStatusLevel.idle;
  String webdavStatusText = '尚未测试 WebDAV 连接';
  bool _startupWebdavCheckTriggered = false;
  bool _startupAutoBackupTriggered = false;
  bool _localUsageExportInProgress = false;

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
    final loadedSettings = await AppServices.settings.load();
    settings = _withNormalizedWebdavAutoBackupInterval(loadedSettings);
    if (settings.webdavAutoBackupIntervalMinutes !=
        loadedSettings.webdavAutoBackupIntervalMinutes) {
      await AppServices.settings.save(settings);
    }
    await refreshRecentVersions();
    _restartWebdavAutoBackupTimer();
    _restartLocalUsageExportTimer();

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
    } on MissingPluginException {
      launchAtStartupEnabled = false;
    }
    currentPort = await AppServices.sandboxConfig.readPort();
    webuiPassword = settings.webuiSecretKey;
    _startStatusPolling();
    if (startupReady) {
      lastStatus = '';
      await _importLocalUsageAfterDelay(trigger: 'startup');
    }

    _triggerStartupWebdavCheck();
    _triggerStartupAutoBackupIfNeeded();
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
    } on MissingPluginException {
      launchAtStartupEnabled = false;
      notifyListeners();
      return '当前运行环境缺少开机启动插件实现（请使用打包后的桌面应用）';
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
    if (inputUrl.isNotEmpty && inputUrl.endsWith('/')) {
      return 'WebDAV 地址不能以 / 结尾';
    }
    final normalizedUrl =
        inputUrl.isEmpty ? '' : AppServices.webdav.normalizeUrl(inputUrl);
    settings = settings.copyWith(
      webdavUrl: normalizedUrl,
      webdavUsername: username.trim(),
      webdavPassword: password,
    );
    await AppServices.settings.save(settings);
    _restartWebdavAutoBackupTimer();
    notifyListeners();
    return 'WebDAV 设置已保存: $normalizedUrl';
  }

  Future<String> saveKeepGithubToken(bool enabled) async {
    settings = settings.copyWith(
      keepGithubToken: enabled,
      githubToken: enabled ? settings.githubToken : '',
    );
    await AppServices.settings.save(settings);
    if (!enabled) {
      await refreshRecentVersions();
    }
    notifyListeners();
    return enabled ? '已开启保持 Token（本地加密保存）' : '已关闭保持 Token，Token 已清空';
  }

  Future<String> saveWebdavAutoBackupEnabled(bool enabled) async {
    settings = settings.copyWith(webdavAutoBackupEnabled: enabled);
    await AppServices.settings.save(settings);
    _restartWebdavAutoBackupTimer();
    notifyListeners();
    if (!enabled) {
      return '已关闭 WebDAV 自动备份';
    }
    if (settings.webdavAutoBackupIntervalMinutes ==
        webdavAutoBackupOnStartupOnly) {
      return '已开启 WebDAV 自动备份（每次启动）';
    }
    return '已开启 WebDAV 自动备份（每 ${settings.webdavAutoBackupIntervalMinutes} 分钟）';
  }

  Future<String> saveWebdavAutoBackupIntervalMinutes(int minutes) async {
    final normalized = _normalizeWebdavAutoBackupInterval(minutes);
    settings = settings.copyWith(webdavAutoBackupIntervalMinutes: normalized);
    await AppServices.settings.save(settings);
    _restartWebdavAutoBackupTimer();
    notifyListeners();
    if (normalized == webdavAutoBackupOnStartupOnly) {
      return '自动备份间隔已设置为每次启动';
    }
    return '自动备份间隔已设置为每 $normalized 分钟';
  }

  Future<void> reloadWebdavSettings() async {
    final loadedSettings = await AppServices.settings.load();
    settings = _withNormalizedWebdavAutoBackupInterval(loadedSettings);
    if (settings.webdavAutoBackupIntervalMinutes !=
        loadedSettings.webdavAutoBackupIntervalMinutes) {
      await AppServices.settings.save(settings);
    }
    notifyListeners();
  }

  int _normalizeWebdavAutoBackupInterval(int minutes) {
    if (webdavAutoBackupIntervals.contains(minutes)) {
      return minutes;
    }
    return 60;
  }

  AppSettings _withNormalizedWebdavAutoBackupInterval(AppSettings value) {
    final normalized = _normalizeWebdavAutoBackupInterval(
        value.webdavAutoBackupIntervalMinutes);
    if (normalized == value.webdavAutoBackupIntervalMinutes) {
      return value;
    }
    return value.copyWith(webdavAutoBackupIntervalMinutes: normalized);
  }

  bool _hasCompleteWebdavConfig() {
    return settings.webdavUrl.trim().isNotEmpty &&
        settings.webdavUsername.trim().isNotEmpty &&
        settings.webdavPassword.trim().isNotEmpty;
  }

  void _triggerStartupWebdavCheck() {
    if (_startupWebdavCheckTriggered) {
      return;
    }
    _startupWebdavCheckTriggered = true;
    if (!_hasCompleteWebdavConfig()) {
      _setWebdavStatus(WebdavStatusLevel.idle, 'WebDAV 配置未完整，已跳过自动测试');
      return;
    }
    unawaited(
      testWebdavConnection(
        url: settings.webdavUrl,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
      ),
    );
  }

  void _triggerStartupAutoBackupIfNeeded() {
    if (_startupAutoBackupTriggered || !settings.webdavAutoBackupEnabled) {
      return;
    }
    if (settings.webdavAutoBackupIntervalMinutes !=
        webdavAutoBackupOnStartupOnly) {
      return;
    }
    _startupAutoBackupTriggered = true;
    unawaited(_performWebdavBackup(isAuto: true));
  }

  Future<String> _resolveLocalUsageJsonPath() async {
    final usageFile = await AppServices.paths.usageJsonFile();
    return usageFile.path;
  }

  Future<void> _exportLocalUsageSnapshot({
    required String trigger,
    bool throwOnError = false,
  }) async {
    if (_localUsageExportInProgress) {
      await AppServices.log
          .info('Local usage export skipped: in-progress, trigger=$trigger');
      return;
    }
    if (!AppServices.process.isRunning) {
      final message =
          'Local usage export skipped: core not running, trigger=$trigger';
      if (throwOnError) {
        throw Exception(message);
      }
      await AppServices.log.info(message);
      return;
    }
    _localUsageExportInProgress = true;
    try {
      final usageJsonPath = await _resolveLocalUsageJsonPath();
      final port = await AppServices.sandboxConfig.readPort();
      final secretKey = await _resolveManagementKeyForUsage();
      await _exportUsageJson(
        localUsageJsonPath: usageJsonPath,
        port: port,
        secretKey: secretKey,
      );
      await AppServices.log.info(
          'Local usage export success: trigger=$trigger output=$usageJsonPath');
    } catch (e) {
      if (throwOnError) {
        rethrow;
      }
      await AppServices.log
          .error('Local usage export failed: trigger=$trigger', e);
    } finally {
      _localUsageExportInProgress = false;
    }
  }

  void _restartLocalUsageExportTimer() {
    _localUsageExportTimer?.cancel();
    _localUsageExportTimer = Timer.periodic(_localUsageExportInterval, (_) {
      unawaited(_exportLocalUsageSnapshot(trigger: 'timer-1m'));
    });
  }

  Future<void> _importLocalUsageIfExists({required String trigger}) async {
    final usageJsonPath = await _resolveLocalUsageJsonPath();
    final usageFile = File(usageJsonPath);
    if (!usageFile.existsSync()) {
      await AppServices.log.info(
          'Local usage import skipped: file missing, trigger=$trigger path=$usageJsonPath');
      return;
    }
    final port = await AppServices.sandboxConfig.readPort();
    final secretKey = await _resolveManagementKeyForUsage();
    await _importUsageJsonWithRetry(
      localUsageJsonPath: usageJsonPath,
      port: port,
      secretKey: secretKey,
      trigger: trigger,
    );
    await AppServices.log.info(
        'Local usage import completed: trigger=$trigger input=$usageJsonPath');
  }

  Future<void> _importLocalUsageAfterDelay({required String trigger}) async {
    await AppServices.log.info(
      'Local usage import delayed: trigger=$trigger wait=${_postCoreReadyUsageImportDelay.inSeconds}s',
    );
    await Future<void>.delayed(_postCoreReadyUsageImportDelay);
    await _importLocalUsageIfExists(trigger: trigger);
  }

  Future<bool> _restoreLatestWebdavBackupIfAvailable({
    required String trigger,
  }) async {
    if (!_hasCompleteWebdavConfig()) {
      await AppServices.log.info(
          'WebDAV restore latest skipped: incomplete config, trigger=$trigger');
      return false;
    }
    try {
      final versions = await listWebdavBackupVersions();
      if (versions.isEmpty) {
        await AppServices.log.info(
            'WebDAV restore latest skipped: no backups, trigger=$trigger');
        return false;
      }
      final latestVersion = versions.first.id;
      await AppServices.log.info(
        'WebDAV restore latest usage start: trigger=$trigger version=$latestVersion',
      );
      return await _restoreUsageFromWebdav(versionId: latestVersion);
    } catch (e) {
      await AppServices.log.error(
          'WebDAV restore latest usage failed: trigger=$trigger',
          _formatDioError(e));
      return false;
    }
  }

  Future<String> testWebdavConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    _setWebdavStatus(WebdavStatusLevel.running, '正在测试连接...');
    try {
      await AppServices.webdav.testConnection(
        url: url,
        username: username,
        password: password,
      );
      const msg = 'WebDAV 连接成功';
      _setWebdavStatus(WebdavStatusLevel.success, msg);
      return msg;
    } catch (e) {
      final msg = 'WebDAV 连接失败: $e';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
  }

  Future<String> backupConfigToWebdav() async {
    return _performWebdavBackup(isAuto: false);
  }

  Future<String> _performWebdavBackup({required bool isAuto}) async {
    final url = settings.webdavUrl.trim();
    if (url.isEmpty) {
      const msg = '请先填写 WebDAV 地址';
      if (!isAuto) {
        _setWebdavStatus(WebdavStatusLevel.failure, msg);
      }
      await AppServices.log
          .info('WebDAV backup skipped: empty url, isAuto=$isAuto');
      return msg;
    }
    if (!isAuto) {
      _setWebdavStatus(WebdavStatusLevel.running, '正在备份配置...');
    }
    try {
      final msg = await AppServices.webdav.backup(
        url: url,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
        settingsWebuiSecretKey: settings.webuiSecretKey,
        defaultWebuiPassword: _defaultWebuiPassword,
        isCoreRunning: AppServices.process.isRunning,
        isAuto: isAuto,
      );
      if (!isAuto) {
        _setWebdavStatus(WebdavStatusLevel.success, msg);
      }
      return msg;
    } catch (e) {
      final logPath = await AppServices.log.logFilePath();
      final msg = 'WebDAV 备份失败: $e\n日志: $logPath';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
  }

  Future<bool> _restoreUsageFromWebdav({required String versionId}) async {
    final url = settings.webdavUrl.trim();
    if (url.isEmpty) {
      return false;
    }
    final restored = await AppServices.webdav.restoreUsage(
      url: url,
      username: settings.webdavUsername,
      password: settings.webdavPassword,
      versionId: versionId,
      settingsWebuiSecretKey: settings.webuiSecretKey,
      defaultWebuiPassword: _defaultWebuiPassword,
    );
    if (restored) {
      currentPort = await AppServices.sandboxConfig.readPort();
      notifyListeners();
    }
    return restored;
  }

  Future<String> restoreConfigFromWebdav({required String versionId}) async {
    final url = settings.webdavUrl.trim();
    if (url.isEmpty) {
      const msg = '请先填写 WebDAV 地址';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }

    if (versionId.trim().isEmpty) {
      const msg = '请选择要还原的备份版本';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }

    _setWebdavStatus(WebdavStatusLevel.running, '正在还原配置...');
    try {
      final result = await AppServices.webdav.restoreConfig(
        url: url,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
        versionId: versionId,
        settingsWebuiSecretKey: settings.webuiSecretKey,
        defaultWebuiPassword: _defaultWebuiPassword,
      );
      currentPort = result.restoredPort;
      webuiPassword = result.restoredSecretKey;
      notifyListeners();
      _setWebdavStatus(WebdavStatusLevel.success, result.message);
      return result.message;
    } catch (e) {
      final logPath = await AppServices.log.logFilePath();
      final msg = 'WebDAV 还原失败: $e\n日志: $logPath';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
  }

  Future<List<WebdavBackupVersion>> listWebdavBackupVersions() async {
    return AppServices.webdav.listVersions(
      url: settings.webdavUrl,
      username: settings.webdavUsername,
      password: settings.webdavPassword,
    );
  }

  Future<String> _resolveManagementKeyForUsage() {
    return AppServices.managementAccess.resolveUsageSecretKey(
      settingsWebuiSecretKey: settings.webuiSecretKey,
      defaultSecretKey: _defaultWebuiPassword,
    );
  }

  Future<void> _exportUsageJson({
    required String localUsageJsonPath,
    required int port,
    required String secretKey,
  }) async {
    final key = secretKey.trim();
    if (key.isEmpty) {
      throw Exception('导出 usage.json 失败: WebUI 密码不能为空');
    }
    final uri = Uri.parse('http://127.0.0.1:$port/v0/management/usage/export');
    await AppServices.log
        .info('Usage export start: uri=$uri output=$localUsageJsonPath');
    try {
      await AppServices.usageNetwork.downloadUsageJson(
        uri: uri,
        secretKey: key,
        outputPath: localUsageJsonPath,
      );
      await AppServices.log
          .info('Usage export success: uri=$uri output=$localUsageJsonPath');
    } on DioException catch (e) {
      throw Exception('导出 usage.json 失败: ${_formatDioError(e)}');
    }
  }

  Future<void> _importUsageJson({
    required String localUsageJsonPath,
    required int port,
    required String secretKey,
  }) async {
    final key = secretKey.trim();
    if (key.isEmpty) {
      throw Exception(
          '导入 usage.json 失败: config.yaml 未配置 remote-management.secret-key');
    }
    final usageFile = File(localUsageJsonPath);
    if (!usageFile.existsSync()) {
      throw Exception('导入 usage.json 失败: 本地文件不存在 $localUsageJsonPath');
    }
    final uri = Uri.parse('http://127.0.0.1:$port/v0/management/usage/import');
    await AppServices.log
        .info('Usage import start: uri=$uri input=$localUsageJsonPath');
    try {
      final payload = await usageFile.readAsString();
      await AppServices.usageNetwork.importUsageJson(
        uri: uri,
        secretKey: key,
        payload: payload,
      );
      await AppServices.log
          .info('Usage import success: uri=$uri input=$localUsageJsonPath');
    } on DioException catch (e) {
      throw Exception('导入 usage.json 失败: ${_formatDioError(e)}');
    }
  }

  Future<void> _importUsageJsonWithRetry({
    required String localUsageJsonPath,
    required int port,
    required String secretKey,
    required String trigger,
  }) async {
    const maxAttempts = 8;
    Object? lastError;
    var currentPort = port;
    var currentKey = secretKey;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await AppServices.log.info(
          'Usage import attempt $attempt/$maxAttempts: trigger=$trigger port=$currentPort',
        );
        await _importUsageJson(
          localUsageJsonPath: localUsageJsonPath,
          port: currentPort,
          secretKey: currentKey,
        );
        return;
      } catch (e) {
        lastError = e;
        await AppServices.log.error(
          'Usage import attempt failed: trigger=$trigger attempt=$attempt',
          e,
        );
        if (attempt == maxAttempts) {
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        currentPort = await AppServices.sandboxConfig.readPort();
        currentKey = await _resolveManagementKeyForUsage();
      }
    }

    throw Exception('导入 usage.json 失败（重试 $maxAttempts 次）: $lastError');
  }

  String _formatDioError(Object error) {
    return AppServices.webdav.formatDioErrorForTest(error);
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

  Future<String> openWebUi() async {
    try {
      final uri =
          Uri.parse('http://127.0.0.1:$currentPort/management.html#/login');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return '已打开 WebUI';
    } catch (e) {
      return '打开 WebUI 失败: $e';
    }
  }

  Future<String> openConfigFile() async {
    try {
      final cfg = await AppServices.sandboxConfig.ensureSandboxConfig();
      await launchUrl(cfg.uri, mode: LaunchMode.externalApplication);
      return '已打开 config.yaml';
    } catch (e) {
      return '打开 config.yaml 失败: $e';
    }
  }

  Future<String> openConfigDirectory() async {
    try {
      final cfg = await AppServices.sandboxConfig.ensureSandboxConfig();
      final dir = cfg.parent;
      await launchUrl(dir.uri, mode: LaunchMode.externalApplication);
      return '已打开配置目录';
    } catch (e) {
      return '打开配置目录失败: $e';
    }
  }

  Future<String> openSandboxDirectory() async {
    try {
      final dir = await AppServices.paths.sandboxRoot();
      await launchUrl(dir.uri, mode: LaunchMode.externalApplication);
      return '已打开 sandbox 目录';
    } catch (e) {
      return '打开 sandbox 目录失败: $e';
    }
  }

  Future<String> updateCore() async {
    try {
      currentPort = await AppServices.coreControl.updateCore(
        version: settings.coreVersion,
        githubToken: settings.githubToken,
      );
      notifyListeners();
      await _importLocalUsageAfterDelay(trigger: 'core-update');
      await AppServices.log
          .info('Core update success: version=${settings.coreVersion}');
      return '核心更新完成并已重启';
    } catch (e) {
      await AppServices.log
          .error('Core update failed: version=${settings.coreVersion}', e);
      final logPath = await AppServices.log.logFilePath();
      return '核心更新失败: $e\n日志: $logPath';
    }
  }

  Future<String> restartCore() async {
    try {
      currentPort = await AppServices.coreControl.restartCore();
      notifyListeners();
      await _importLocalUsageAfterDelay(trigger: 'manual-restart');
      await AppServices.log.info('Core restart success');
      return '核心已重启';
    } catch (e) {
      await AppServices.log.error('Core restart failed', e);
      final logPath = await AppServices.log.logFilePath();
      return '重启核心失败: $e\n日志: $logPath';
    }
  }

  Future<String> stopCore() async {
    try {
      await AppServices.coreControl.stopCore();
      notifyListeners();
      return '核心已停止';
    } catch (e) {
      final logPath = await AppServices.log.logFilePath();
      return '停止核心失败: $e\n日志: $logPath';
    }
  }

  Future<String> saveGithubToken(String value) async {
    final token = value.trim();
    settings = settings.copyWith(githubToken: token);
    await AppServices.settings.save(settings);
    await refreshRecentVersions();
    notifyListeners();
    if (token.isEmpty) {
      return 'GitHub Token 已清空';
    }
    if (!settings.keepGithubToken) {
      return 'GitHub Token 已保存（未开启保持 Token，重启后不会保留）';
    }
    return 'GitHub Token 已保存';
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
      settings = settings.copyWith(webuiSecretKey: secret);
      await AppServices.settings.save(settings);
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
      if (recentVersions.isNotEmpty &&
          !recentVersions.contains(settings.coreVersion)) {
        settings = settings.copyWith(coreVersion: recentVersions.first);
        await AppServices.settings.save(settings);
      }
    } catch (e) {
      await AppServices.log.error('Load recent versions failed', e);
      recentVersions = settings.coreVersion.trim().isEmpty
          ? const []
          : [settings.coreVersion];
    }
  }

  bool get isCoreRunning => AppServices.process.isRunning;

  Timer? _statusTimer;
  Timer? _webdavAutoBackupTimer;
  Timer? _localUsageExportTimer;

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      notifyListeners();
    });
  }

  void _restartWebdavAutoBackupTimer() {
    _webdavAutoBackupTimer?.cancel();
    _webdavAutoBackupTimer = null;
    if (!settings.webdavAutoBackupEnabled) {
      return;
    }
    final normalizedInterval = _normalizeWebdavAutoBackupInterval(
        settings.webdavAutoBackupIntervalMinutes);
    if (normalizedInterval == webdavAutoBackupOnStartupOnly) {
      return;
    }
    _webdavAutoBackupTimer =
        Timer.periodic(Duration(minutes: normalizedInterval), (_) {
      unawaited(_performWebdavBackup(isAuto: true));
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

  void _setWebdavStatus(WebdavStatusLevel level, String text) {
    webdavStatusLevel = level;
    webdavStatusText = text;
    notifyListeners();
  }

  Future<void> disposeController() async {
    _statusTimer?.cancel();
    _statusTimer = null;
    _webdavAutoBackupTimer?.cancel();
    _webdavAutoBackupTimer = null;
    _localUsageExportTimer?.cancel();
    _localUsageExportTimer = null;
    await AppServices.startup.shutdown();
  }
}
