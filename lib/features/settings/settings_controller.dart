import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:cpaclient/core/constants/core_defaults.dart';
import 'package:cpaclient/core/models/app_settings.dart';
import 'package:cpaclient/core/services/app_services.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

enum WebdavStatusLevel { idle, running, success, failure }

class SettingsController extends ChangeNotifier {
  SettingsController();

  static const String _usageJsonFileName = 'usage.json';
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
  bool _webdavBackupInProgress = false;
  bool _startupWebdavCheckTriggered = false;
  bool _startupAutoBackupTriggered = false;

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
    if (settings.webdavAutoBackupIntervalMinutes == webdavAutoBackupOnStartupOnly) {
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
    final normalized =
        _normalizeWebdavAutoBackupInterval(value.webdavAutoBackupIntervalMinutes);
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

  Future<String> testWebdavConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    final inputUrl = url.trim();
    if (inputUrl.isEmpty) {
      final msg = '请先填写 WebDAV 地址';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
    if (inputUrl.endsWith('/')) {
      final msg = 'WebDAV 地址不能以 / 结尾';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
    final normalizedUrl = inputUrl.endsWith('/CpaClient') ? inputUrl : '$inputUrl/CpaClient';
    _setWebdavStatus(WebdavStatusLevel.running, '正在测试连接...');
    try {
      await AppServices.log.info('WebDAV test start: url=$normalizedUrl user=${username.trim()}');
      final client = _createWebdavClient(
        url: normalizedUrl,
        username: username.trim(),
        password: password,
        debug: true,
      );
      await client.ping();
      await AppServices.log.info('WebDAV test success: url=$normalizedUrl');
      const msg = 'WebDAV 连接成功';
      _setWebdavStatus(WebdavStatusLevel.success, msg);
      return msg;
    } catch (e) {
      await AppServices.log.error('WebDAV test failed: url=$normalizedUrl', _formatDioError(e));
      final msg = 'WebDAV 连接失败: $e';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
  }

  Future<String> backupConfigToWebdav() async {
    return _performWebdavBackup(isAuto: false);
  }

  Future<String> _performWebdavBackup({required bool isAuto}) async {
    if (_webdavBackupInProgress) {
      const msg = '已有备份任务正在执行，已跳过';
      await AppServices.log.info('WebDAV backup skipped: in-progress, isAuto=$isAuto');
      return msg;
    }
    if (settings.webdavUrl.trim().isEmpty) {
      const msg = '请先填写 WebDAV 地址';
      if (!isAuto) {
        _setWebdavStatus(WebdavStatusLevel.failure, msg);
      }
      await AppServices.log.info('WebDAV backup skipped: empty url, isAuto=$isAuto');
      return msg;
    }
    if (!isAuto) {
      _setWebdavStatus(WebdavStatusLevel.running, '正在备份配置...');
    }
    _webdavBackupInProgress = true;
    try {
      final cfg = await AppServices.sandboxConfig.ensureSandboxConfig();
      final authDir = await AppServices.sandboxConfig.readAuthDir();
      final authRoot = AppServices.paths.resolveAuthDir(authDir);
      final authJsonFiles = _listRootJsonFiles(authRoot);
      final usageJsonPath = p.join(cfg.parent.path, _usageJsonFileName);
      final port = await AppServices.sandboxConfig.readPort();
      final secretKey = await _resolveManagementKeyForUsage();
      await _exportUsageJson(localUsageJsonPath: usageJsonPath, port: port, secretKey: secretKey);
      await AppServices.log.info(
        'WebDAV backup start: url=${settings.webdavUrl} local=${cfg.path} authDir=${authRoot.path} count=${authJsonFiles.length} usage=$usageJsonPath isAuto=$isAuto',
      );
      final client = _createWebdavClient(
        url: settings.webdavUrl,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
        debug: false,
      );
      try {
        await _writeConfigToWebdav(client: client, localConfigPath: cfg.path);
        await _writeAuthJsonToWebdav(
          client: client,
          localAuthDir: authRoot,
          localJsonFiles: authJsonFiles,
        );
        await _writeUsageJsonToWebdav(client: client, localUsageJsonPath: usageJsonPath);
      } catch (e) {
        if (_shouldTryParentFallback(e)) {
          await _writeConfigToWebdavFromParent(localConfigPath: cfg.path);
          await _writeAuthJsonToWebdavFromParent(
            localAuthDir: authRoot,
            localJsonFiles: authJsonFiles,
          );
          await _writeUsageJsonToWebdavFromParent(localUsageJsonPath: usageJsonPath);
        } else {
          rethrow;
        }
      }
      final msg = '已备份 config.yaml + auth-json(${authJsonFiles.length}) + usage.json';
      await AppServices.log.info('WebDAV backup success: $msg, isAuto=$isAuto');
      if (!isAuto) {
        _setWebdavStatus(WebdavStatusLevel.success, msg);
      }
      return msg;
    } catch (e) {
      await AppServices.log.error('WebDAV backup failed, isAuto=$isAuto', _formatDioError(e));
      final logPath = await AppServices.log.logFilePath();
      final msg = 'WebDAV 备份失败: $e\n日志: $logPath';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    } finally {
      _webdavBackupInProgress = false;
    }
  }

  Future<String> restoreConfigFromWebdav() async {
    if (settings.webdavUrl.trim().isEmpty) {
      const msg = '请先填写 WebDAV 地址';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
    _setWebdavStatus(WebdavStatusLevel.running, '正在还原配置...');
    try {
      final cfg = await AppServices.sandboxConfig.ensureSandboxConfig();
      final authDir = await AppServices.sandboxConfig.readAuthDir();
      final authRoot = AppServices.paths.resolveAuthDir(authDir);
      final usageJsonPath = p.join(cfg.parent.path, _usageJsonFileName);
      await AppServices.log.info(
        'WebDAV restore start: url=${settings.webdavUrl} local=${cfg.path} restoreTo=${authRoot.path} usage=$usageJsonPath',
      );
      final client = _createWebdavClient(
        url: settings.webdavUrl,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
        debug: false,
      );
      int restoredJsonCount = 0;
      try {
        await _readConfigFromWebdav(client: client, localConfigPath: cfg.path);
        restoredJsonCount = await _readAuthJsonFromWebdav(
          client: client,
          localAuthDir: authRoot,
          remoteAuthJsonRoot: CoreDefaults.webdavAuthJsonDirName,
          logPrefix: 'WebDAV restore auth-json',
        );
        await _readUsageJsonFromWebdav(client: client, localUsageJsonPath: usageJsonPath);
      } catch (e) {
        if (_shouldTryParentFallback(e)) {
          await _readConfigFromWebdavFromParent(localConfigPath: cfg.path);
          restoredJsonCount = await _readAuthJsonFromWebdavFromParent(
            localAuthDir: authRoot,
          );
          await _readUsageJsonFromWebdavFromParent(localUsageJsonPath: usageJsonPath);
        } else {
          rethrow;
        }
      }
      await _restartCoreAfterRestore();
      final restoredPort = await AppServices.sandboxConfig.readPort();
      final restoredSecretKey = await _resolveManagementKeyForUsage();
      await _importUsageJson(
        localUsageJsonPath: usageJsonPath,
        port: restoredPort,
        secretKey: restoredSecretKey,
      );
      currentPort = restoredPort;
      webuiPassword = restoredSecretKey;
      notifyListeners();
      await AppServices.log.info('WebDAV restore success: config.yaml + auth-json($restoredJsonCount) + usage.json');
      final msg = '已还原 config.yaml + auth-json($restoredJsonCount) + usage.json，并重启核心';
      _setWebdavStatus(WebdavStatusLevel.success, msg);
      return msg;
    } catch (e) {
      await AppServices.log.error('WebDAV restore failed', _formatDioError(e));
      final logPath = await AppServices.log.logFilePath();
      final msg = 'WebDAV 还原失败: $e\n日志: $logPath';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
  }

  List<File> _listRootJsonFiles(Directory root) {
    if (!root.existsSync()) {
      return const <File>[];
    }
    return root
        .listSync(recursive: false, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.json'))
        .toList(growable: false);
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

  Future<void> _writeUsageJsonToWebdav({
    required dynamic client,
    required String localUsageJsonPath,
  }) async {
    await _writeUsageJsonWithCandidates(
      client: client,
      localUsageJsonPath: localUsageJsonPath,
      remoteCandidates: const [_usageJsonFileName, '/$_usageJsonFileName'],
      logPrefix: 'WebDAV backup usage-json',
    );
  }

  Future<void> _writeConfigToWebdavFromParent({required String localConfigPath}) async {
    final parentUrl = _parentWebdavUrl(settings.webdavUrl);
    if (parentUrl == settings.webdavUrl) {
      throw Exception('父级 WebDAV 地址未变化，无法执行回退写入');
    }
    await AppServices.log.info('WebDAV backup fallback to parent url: $parentUrl');
    final parentClient = _createWebdavClient(
      url: parentUrl,
      username: settings.webdavUsername,
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

  Future<void> _writeUsageJsonToWebdavFromParent({required String localUsageJsonPath}) async {
    final parentUrl = _parentWebdavUrl(settings.webdavUrl);
    if (parentUrl == settings.webdavUrl) {
      throw Exception('父级 WebDAV 地址未变化，无法执行回退写入 usage.json');
    }
    await AppServices.log.info('WebDAV backup usage-json fallback to parent url: $parentUrl');
    final parentClient = _createWebdavClient(
      url: parentUrl,
      username: settings.webdavUsername,
      password: settings.webdavPassword,
      debug: false,
    );
    await _writeUsageJsonWithCandidates(
      client: parentClient,
      localUsageJsonPath: localUsageJsonPath,
      remoteCandidates: const [
        'CpaClient/$_usageJsonFileName',
        '/CpaClient/$_usageJsonFileName',
        _usageJsonFileName,
        '/$_usageJsonFileName',
      ],
      logPrefix: 'WebDAV backup(parent) usage-json',
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

  Future<void> _writeUsageJsonWithCandidates({
    required dynamic client,
    required String localUsageJsonPath,
    required List<String> remoteCandidates,
    required String logPrefix,
  }) async {
    final localFile = File(localUsageJsonPath);
    if (!localFile.existsSync()) {
      throw Exception('usage.json 不存在: $localUsageJsonPath');
    }
    Object? lastError;
    for (final remotePath in remoteCandidates) {
      try {
        await AppServices.log.info('$logPrefix try path: $remotePath');
        await client.writeFromFile(localUsageJsonPath, remotePath);
        await AppServices.log.info('$logPrefix path success: $remotePath');
        return;
      } catch (e) {
        lastError = e;
        await AppServices.log.error('$logPrefix path failed: $remotePath', _formatDioError(e));
      }
    }
    throw Exception('上传 usage.json 失败: ${_formatDioError(lastError ?? 'unknown error')}');
  }

  Future<void> _writeAuthJsonToWebdav({
    required dynamic client,
    required Directory localAuthDir,
    required List<File> localJsonFiles,
  }) async {
    await _writeAuthJsonWithCandidates(
      client: client,
      localAuthDir: localAuthDir,
      localJsonFiles: localJsonFiles,
      remoteRootCandidates: const [
        CoreDefaults.webdavAuthJsonDirName,
        '/${CoreDefaults.webdavAuthJsonDirName}',
      ],
      logPrefix: 'WebDAV backup auth-json',
    );
  }

  Future<void> _writeAuthJsonToWebdavFromParent({
    required Directory localAuthDir,
    required List<File> localJsonFiles,
  }) async {
    final parentUrl = _parentWebdavUrl(settings.webdavUrl);
    if (parentUrl == settings.webdavUrl) {
      throw Exception('父级 WebDAV 地址未变化，无法执行回退写入 auth-json');
    }
    await AppServices.log.info('WebDAV backup auth-json fallback to parent url: $parentUrl');
    final parentClient = _createWebdavClient(
      url: parentUrl,
      username: settings.webdavUsername,
      password: settings.webdavPassword,
      debug: false,
    );
    await _writeAuthJsonWithCandidates(
      client: parentClient,
      localAuthDir: localAuthDir,
      localJsonFiles: localJsonFiles,
      remoteRootCandidates: const [
        'CpaClient/${CoreDefaults.webdavAuthJsonDirName}',
        '/CpaClient/${CoreDefaults.webdavAuthJsonDirName}',
        CoreDefaults.webdavAuthJsonDirName,
        '/${CoreDefaults.webdavAuthJsonDirName}',
      ],
      logPrefix: 'WebDAV backup(parent) auth-json',
    );
  }

  Future<void> _writeAuthJsonWithCandidates({
    required dynamic client,
    required Directory localAuthDir,
    required List<File> localJsonFiles,
    required List<String> remoteRootCandidates,
    required String logPrefix,
  }) async {
    if (!localAuthDir.existsSync()) {
      await AppServices.log.info(
        '$logPrefix local root not found, skip upload: ${localAuthDir.path}',
      );
      return;
    }
    if (localJsonFiles.isEmpty) {
      await AppServices.log.info('$logPrefix no local json files under ${localAuthDir.path}');
      return;
    }

    Object? lastError;
    for (final remoteRoot in remoteRootCandidates) {
      try {
        await AppServices.log.info('$logPrefix try root: $remoteRoot');
        await client.mkdirAll(remoteRoot);
        for (final localFile in localJsonFiles) {
          final fileName = p.basename(localFile.path);
          final remotePath = '$remoteRoot/$fileName';
          await client.writeFromFile(localFile.path, remotePath);
        }
        await AppServices.log.info('$logPrefix root success: $remoteRoot, files=${localJsonFiles.length}');
        return;
      } catch (e) {
        lastError = e;
        await AppServices.log.error('$logPrefix root failed: $remoteRoot', _formatDioError(e));
      }
    }
    throw Exception('上传 auth-json 失败: ${_formatDioError(lastError ?? 'unknown error')}');
  }

  Future<int> _readAuthJsonFromWebdav({
    required dynamic client,
    required Directory localAuthDir,
    required String remoteAuthJsonRoot,
    required String logPrefix,
  }) async {
    await AppServices.log.info('$logPrefix list remote root: $remoteAuthJsonRoot');
    late final List<dynamic> entries;
    try {
      entries = await client.readDir(remoteAuthJsonRoot);
    } catch (e) {
      if (_isRemoteNotFound(e)) {
        await AppServices.log.info('$logPrefix remote root not found, skip restore: $remoteAuthJsonRoot');
        return 0;
      }
      rethrow;
    }
    final jsonEntries = entries
        .where((entry) => entry.isDir != true)
        .where((entry) => (entry.path ?? '').toLowerCase().endsWith('.json'))
        .toList(growable: false);

    if (jsonEntries.isEmpty) {
      await AppServices.log.info('$logPrefix no json files under remote root: $remoteAuthJsonRoot');
      return 0;
    }

    if (!localAuthDir.existsSync()) {
      localAuthDir.createSync(recursive: true);
    }

    var restoredCount = 0;
    for (final remoteFile in jsonEntries) {
      final remotePath = remoteFile.path;
      if (remotePath == null || remotePath.trim().isEmpty) {
        continue;
      }
      final fileName = p.basename(remotePath);
      final localPath = p.join(localAuthDir.path, fileName);
      await client.read2File(remotePath, localPath);
      restoredCount += 1;
    }

    await AppServices.log.info('$logPrefix restored json files: $restoredCount');
    return restoredCount;
  }

  Future<int> _readAuthJsonFromWebdavFromParent({
    required Directory localAuthDir,
  }) async {
    final parentUrl = _parentWebdavUrl(settings.webdavUrl);
    if (parentUrl == settings.webdavUrl) {
      throw Exception('父级 WebDAV 地址未变化，无法执行回退读取 auth-json');
    }
    await AppServices.log.info('WebDAV restore auth-json fallback to parent url: $parentUrl');
    final parentClient = _createWebdavClient(
      url: parentUrl,
      username: settings.webdavUsername,
      password: settings.webdavPassword,
      debug: false,
    );

    Object? lastError;
    const candidates = <String>[
      'CpaClient/${CoreDefaults.webdavAuthJsonDirName}',
      '/CpaClient/${CoreDefaults.webdavAuthJsonDirName}',
      CoreDefaults.webdavAuthJsonDirName,
      '/${CoreDefaults.webdavAuthJsonDirName}',
    ];

    for (final remoteRoot in candidates) {
      try {
        return await _readAuthJsonFromWebdav(
          client: parentClient,
          localAuthDir: localAuthDir,
          remoteAuthJsonRoot: remoteRoot,
          logPrefix: 'WebDAV restore(parent) auth-json',
        );
      } catch (e) {
        lastError = e;
        await AppServices.log.error(
          'WebDAV restore(parent) auth-json failed root: $remoteRoot',
          _formatDioError(e),
        );
      }
    }

    throw Exception('下载 auth-json 失败: ${_formatDioError(lastError ?? 'unknown error')}');
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

  Future<void> _readUsageJsonFromWebdav({
    required dynamic client,
    required String localUsageJsonPath,
  }) async {
    await _readUsageJsonWithCandidates(
      client: client,
      localUsageJsonPath: localUsageJsonPath,
      remoteCandidates: const [_usageJsonFileName, '/$_usageJsonFileName'],
      logPrefix: 'WebDAV restore usage-json',
    );
  }

  Future<void> _readConfigFromWebdavFromParent({required String localConfigPath}) async {
    final parentUrl = _parentWebdavUrl(settings.webdavUrl);
    if (parentUrl == settings.webdavUrl) {
      throw Exception('父级 WebDAV 地址未变化，无法执行回退读取');
    }
    await AppServices.log.info('WebDAV restore fallback to parent url: $parentUrl');
    final parentClient = _createWebdavClient(
      url: parentUrl,
      username: settings.webdavUsername,
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

  Future<void> _readUsageJsonFromWebdavFromParent({required String localUsageJsonPath}) async {
    final parentUrl = _parentWebdavUrl(settings.webdavUrl);
    if (parentUrl == settings.webdavUrl) {
      throw Exception('父级 WebDAV 地址未变化，无法执行回退读取 usage.json');
    }
    await AppServices.log.info('WebDAV restore usage-json fallback to parent url: $parentUrl');
    final parentClient = _createWebdavClient(
      url: parentUrl,
      username: settings.webdavUsername,
      password: settings.webdavPassword,
      debug: false,
    );
    await _readUsageJsonWithCandidates(
      client: parentClient,
      localUsageJsonPath: localUsageJsonPath,
      remoteCandidates: const [
        'CpaClient/$_usageJsonFileName',
        '/CpaClient/$_usageJsonFileName',
        _usageJsonFileName,
        '/$_usageJsonFileName',
      ],
      logPrefix: 'WebDAV restore(parent) usage-json',
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

  Future<void> _readUsageJsonWithCandidates({
    required dynamic client,
    required String localUsageJsonPath,
    required List<String> remoteCandidates,
    required String logPrefix,
  }) async {
    Object? lastError;
    for (final remotePath in remoteCandidates) {
      try {
        await AppServices.log.info('$logPrefix try path: $remotePath');
        await client.read2File(remotePath, localUsageJsonPath);
        await AppServices.log.info('$logPrefix path success: $remotePath');
        return;
      } catch (e) {
        lastError = e;
        await AppServices.log.error('$logPrefix path failed: $remotePath', _formatDioError(e));
      }
    }
    throw Exception('下载 usage.json 失败: ${_formatDioError(lastError ?? 'unknown error')}');
  }

  Future<String> _resolveManagementKeyForUsage() async {
    final key = settings.webuiSecretKey.trim();
    if (key.isNotEmpty) {
      return key;
    }
    throw Exception('导出 usage.json 失败: 请先在设置页保存 WebUI 密码（明文管理密钥）');
  }

  Future<void> _exportUsageJson({
    required String localUsageJsonPath,
    required int port,
    required String secretKey,
  }) async {
    final key = secretKey.trim();
    if (key.isEmpty) {
      throw Exception('导出 usage.json 失败: config.yaml 未配置 remote-management.secret-key');
    }
    final uri = Uri.parse('http://127.0.0.1:$port/v0/management/usage/export');
    await AppServices.log.info('Usage export start: uri=$uri output=$localUsageJsonPath');
    final dio = Dio();
    try {
      final response = await dio.getUri<dynamic>(
        uri,
        options: Options(
          headers: <String, String>{'X-Management-Key': key},
          responseType: ResponseType.plain,
        ),
      );
      final body = _responseBodyToText(response.data);
      await File(localUsageJsonPath).writeAsString(body);
      await AppServices.log.info('Usage export success: uri=$uri output=$localUsageJsonPath');
    } on DioException catch (e) {
      throw Exception('导出 usage.json 失败: ${_formatDioError(e)}');
    } finally {
      dio.close();
    }
  }

  Future<void> _importUsageJson({
    required String localUsageJsonPath,
    required int port,
    required String secretKey,
  }) async {
    final key = secretKey.trim();
    if (key.isEmpty) {
      throw Exception('导入 usage.json 失败: config.yaml 未配置 remote-management.secret-key');
    }
    final usageFile = File(localUsageJsonPath);
    if (!usageFile.existsSync()) {
      throw Exception('导入 usage.json 失败: 本地文件不存在 $localUsageJsonPath');
    }
    final uri = Uri.parse('http://127.0.0.1:$port/v0/management/usage/import');
    await AppServices.log.info('Usage import start: uri=$uri input=$localUsageJsonPath');
    final dio = Dio();
    try {
      final payload = await usageFile.readAsString();
      await dio.postUri<dynamic>(
        uri,
        data: payload,
        options: Options(
          headers: <String, String>{
            'X-Management-Key': key,
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.plain,
        ),
      );
      await AppServices.log.info('Usage import success: uri=$uri input=$localUsageJsonPath');
    } on DioException catch (e) {
      throw Exception('导入 usage.json 失败: ${_formatDioError(e)}');
    } finally {
      dio.close();
    }
  }

  String _responseBodyToText(dynamic data) {
    if (data == null) {
      return '';
    }
    if (data is String) {
      return data;
    }
    if (data is List<int>) {
      return utf8.decode(data);
    }
    return jsonEncode(data);
  }

  Future<void> _restartCoreAfterRestore() async {
    await AppServices.log.info('WebDAV restore restarting core begin');
    await AppServices.process.stop();
    await AppServices.process.start();
    await AppServices.log.info('WebDAV restore restarting core completed');
  }

  bool _isRemoteNotFound(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 404) {
        return true;
      }
    }
    final text = error.toString();
    return text.contains('status=404') || text.contains('404 Not Found');
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

  dynamic _createWebdavClient({
    required String url,
    required String username,
    required String password,
    required bool debug,
  }) {
    final client = newClient(
      url,
      user: username,
      password: password,
      debug: debug,
    );
    client.setHeaders(<String, dynamic>{'content-type': 'application/octet-stream'});
    return client;
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

  Future<String> openWebUi() async {
    try {
      final uri = Uri.parse('http://127.0.0.1:$currentPort/management.html#/login');
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
      await AppServices.log.info('Core update requested: version=${settings.coreVersion}');
      await AppServices.startup.updateCore(
        version: settings.coreVersion,
        githubToken: settings.githubToken,
      );
      currentPort = await AppServices.sandboxConfig.readPort();
      notifyListeners();
      await AppServices.log.info('Core update success: version=${settings.coreVersion}');
      return '核心更新完成并已重启';
    } catch (e) {
      await AppServices.log.error('Core update failed: version=${settings.coreVersion}', e);
      final logPath = await AppServices.log.logFilePath();
      return '核心更新失败: $e\n日志: $logPath';
    }
  }

  Future<String> restartCore() async {
    try {
      await AppServices.log.info('Core restart requested');
      await AppServices.process.stop();
      await AppServices.process.start();
      currentPort = await AppServices.sandboxConfig.readPort();
      notifyListeners();
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
      await AppServices.process.stop();
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
  Timer? _webdavAutoBackupTimer;

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
    final normalizedInterval =
        _normalizeWebdavAutoBackupInterval(settings.webdavAutoBackupIntervalMinutes);
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
    await AppServices.startup.shutdown();
  }
}
