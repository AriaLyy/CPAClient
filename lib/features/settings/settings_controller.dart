import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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

class WebdavBackupVersion {
  const WebdavBackupVersion({
    required this.id,
    required this.displayLabel,
  });

  final String id;
  final String displayLabel;
}

class _WebdavVersionListingResult {
  const _WebdavVersionListingResult({
    required this.root,
    required this.versions,
  });

  final String root;
  final List<String> versions;
}

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
      final versionId = _newBackupVersionId();
      final versionRoot = '${CoreDefaults.webdavBackupVersionsDirName}/$versionId';
      final remoteArchivePath = '$versionRoot/backup.tar.gz';
      await AppServices.log.info(
        'WebDAV backup start: url=${settings.webdavUrl} version=$versionId local=${cfg.path} authDir=${authRoot.path} count=${authJsonFiles.length} usage=$usageJsonPath isAuto=$isAuto',
      );
      final client = _createWebdavClient(
        url: settings.webdavUrl,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
        debug: false,
      );

      final archivePath = await _buildBackupArchive(
        localConfigPath: cfg.path,
        localUsageJsonPath: usageJsonPath,
        localAuthJsonFiles: authJsonFiles,
      );
      try {
        await _writeBackupArchiveToWebdav(
          client: client,
          localArchivePath: archivePath,
          remoteArchivePath: remoteArchivePath,
        );
      } finally {
        final archiveFile = File(archivePath);
        if (archiveFile.existsSync()) {
          archiveFile.deleteSync();
        }
      }

      final cleanupWarning = await _cleanupOldWebdavBackups();
      final msgBase =
          '已备份压缩包版本 $versionId（backup.tar.gz，最多保留 ${CoreDefaults.webdavBackupMaxVersions} 个）';
      final msg = cleanupWarning == null ? msgBase : '$msgBase；$cleanupWarning';
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

  Future<String> restoreConfigFromWebdav({required String versionId}) async {
    if (settings.webdavUrl.trim().isEmpty) {
      const msg = '请先填写 WebDAV 地址';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }

    final selectedVersionId = versionId.trim();
    if (selectedVersionId.isEmpty) {
      const msg = '请选择要还原的备份版本';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }

    final remoteArchivePath =
        '${CoreDefaults.webdavBackupVersionsDirName}/$selectedVersionId/backup.tar.gz';

    _setWebdavStatus(WebdavStatusLevel.running, '正在还原配置...');
    try {
      final cfg = await AppServices.sandboxConfig.ensureSandboxConfig();
      final authDir = await AppServices.sandboxConfig.readAuthDir();
      final authRoot = AppServices.paths.resolveAuthDir(authDir);
      final usageJsonPath = p.join(cfg.parent.path, _usageJsonFileName);
      final localArchivePath = p.join(cfg.parent.path, 'webdav_restore_backup.tar.gz');
      await AppServices.log.info(
        'WebDAV restore start: url=${settings.webdavUrl} version=$selectedVersionId local=${cfg.path} restoreTo=${authRoot.path} usage=$usageJsonPath archive=$localArchivePath',
      );

      final client = _createWebdavClient(
        url: settings.webdavUrl,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
        debug: false,
      );

      await _readBackupArchiveFromWebdav(
        client: client,
        localArchivePath: localArchivePath,
        remoteArchivePath: remoteArchivePath,
      );

      int restoredJsonCount = 0;
      try {
        restoredJsonCount = _extractBackupArchive(
          localArchivePath: localArchivePath,
          localConfigPath: cfg.path,
          localUsageJsonPath: usageJsonPath,
          localAuthDir: authRoot,
        );
      } finally {
        final archiveFile = File(localArchivePath);
        if (archiveFile.existsSync()) {
          archiveFile.deleteSync();
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
      await AppServices.log.info(
        'WebDAV restore success: version=$selectedVersionId archive=backup.tar.gz auth-json($restoredJsonCount)',
      );
      final msg = '已解压还原版本 $selectedVersionId（backup.tar.gz，auth-json $restoredJsonCount 个），并重启核心';
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

  List<String> _remotePathCandidates(String remotePath) {
    final normalized = remotePath.startsWith('/')
        ? remotePath.substring(1)
        : remotePath;
    return <String>[normalized, '/$normalized'];
  }

  String _newBackupVersionId() {
    final now = DateTime.now().toUtc();
    String pad2(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${pad2(now.month)}${pad2(now.day)}T${pad2(now.hour)}${pad2(now.minute)}${pad2(now.second)}Z';
  }

  DateTime? _parseBackupVersionTime(String versionId) {
    final match = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$').firstMatch(versionId);
    if (match == null) {
      return null;
    }
    return DateTime.utc(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  String _formatBackupVersionLabel(String versionId) {
    final time = _parseBackupVersionTime(versionId);
    if (time == null) {
      return versionId;
    }
    final local = time.toLocal();
    String pad2(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${pad2(local.month)}-${pad2(local.day)} ${pad2(local.hour)}:${pad2(local.minute)}:${pad2(local.second)}';
  }

  Future<_WebdavVersionListingResult> _listVersionDirectories() async {
    final client = _createWebdavClient(
      url: settings.webdavUrl,
      username: settings.webdavUsername,
      password: settings.webdavPassword,
      debug: false,
    );
    final root = CoreDefaults.webdavBackupVersionsDirName;

    try {
      final entries = await client.readDir(root);
      final versions = <String>[];
      for (final entry in entries.where((entry) => entry.isDir == true)) {
        final name = p.basename((entry.path ?? '').replaceAll('\\', '/'));
        if (_parseBackupVersionTime(name) == null) {
          continue;
        }
        final remoteArchivePath = '$root/$name/backup.tar.gz';
        if (await _remoteFileExists(client: client, remotePath: remoteArchivePath)) {
          versions.add(name);
        }
      }
      final sorted = versions.toSet().toList(growable: false)
        ..sort((String a, String b) => b.compareTo(a));
      return _WebdavVersionListingResult(root: root, versions: sorted);
    } catch (e) {
      if (_isRemoteNotFound(e)) {
        return _WebdavVersionListingResult(root: root, versions: const <String>[]);
      }
      rethrow;
    }
  }

  Future<List<WebdavBackupVersion>> listWebdavBackupVersions() async {
    if (settings.webdavUrl.trim().isEmpty) {
      return const <WebdavBackupVersion>[];
    }

    final listing = await _listVersionDirectories();
    return listing.versions
        .map((id) => WebdavBackupVersion(id: id, displayLabel: _formatBackupVersionLabel(id)))
        .toList(growable: false);
  }

  Future<String?> _cleanupOldWebdavBackups() async {
    try {
      final listing = await _listVersionDirectories();
      if (listing.versions.length <= CoreDefaults.webdavBackupMaxVersions) {
        return null;
      }
      final toDelete = listing.versions.skip(CoreDefaults.webdavBackupMaxVersions);
      final client = _createWebdavClient(
        url: settings.webdavUrl,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
        debug: false,
      );
      for (final version in toDelete) {
        await client.removeAll('${listing.root}/$version');
      }
      return null;
    } catch (e) {
      await AppServices.log.error('WebDAV backup cleanup failed', _formatDioError(e));
      return '清理旧版本失败（不影响本次备份）';
    }
  }

  Future<bool> _remoteFileExists({
    required dynamic client,
    required String remotePath,
  }) async {
    try {
      await client.read(remotePath);
      return true;
    } catch (e) {
      if (_isRemoteNotFound(e)) {
        return false;
      }
      rethrow;
    }
  }

  Future<String> _buildBackupArchive({
    required String localConfigPath,
    required String localUsageJsonPath,
    required List<File> localAuthJsonFiles,
  }) async {
    final configFile = File(localConfigPath);
    final usageFile = File(localUsageJsonPath);
    if (!configFile.existsSync()) {
      throw Exception('config.yaml 不存在: $localConfigPath');
    }
    if (!usageFile.existsSync()) {
      throw Exception('usage.json 不存在: $localUsageJsonPath');
    }

    final tmpDir = await Directory.systemTemp.createTemp('cpaclient_webdav_backup_');
    final archivePath = p.join(tmpDir.path, 'backup.tar.gz');

    final archive = Archive()
      ..addFile(ArchiveFile('config.yaml', configFile.lengthSync(), configFile.readAsBytesSync()))
      ..addFile(ArchiveFile('usage.json', usageFile.lengthSync(), usageFile.readAsBytesSync()));

    for (final jsonFile in localAuthJsonFiles) {
      final name = p.basename(jsonFile.path);
      final bytes = jsonFile.readAsBytesSync();
      archive.addFile(ArchiveFile('${CoreDefaults.webdavAuthJsonDirName}/$name', bytes.length, bytes));
    }

    final tarData = TarEncoder().encode(archive);
    final gzipData = GZipEncoder().encode(tarData);

    await File(archivePath).writeAsBytes(gzipData, flush: true);
    return archivePath;
  }

  Future<void> _writeBackupArchiveToWebdav({
    required dynamic client,
    required String localArchivePath,
    required String remoteArchivePath,
  }) async {
    await _writeFileWithCandidates(
      client: client,
      localFilePath: localArchivePath,
      remoteCandidates: _remotePathCandidates(remoteArchivePath),
      logPrefix: 'WebDAV backup archive',
    );
  }

  Future<void> _writeFileWithCandidates({
    required dynamic client,
    required String localFilePath,
    required List<String> remoteCandidates,
    required String logPrefix,
  }) async {
    final localFile = File(localFilePath);
    if (!localFile.existsSync()) {
      throw Exception('本地文件不存在: $localFilePath');
    }
    Object? lastError;
    for (final remotePath in remoteCandidates) {
      try {
        await AppServices.log.info('$logPrefix try path: $remotePath');
        await client.writeFromFile(localFilePath, remotePath);
        await AppServices.log.info('$logPrefix path success: $remotePath');
        return;
      } catch (e) {
        lastError = e;
        await AppServices.log.error('$logPrefix path failed: $remotePath', _formatDioError(e));
      }
    }
    throw Exception('上传文件失败: ${_formatDioError(lastError ?? 'unknown error')}');
  }

  Future<void> _readBackupArchiveFromWebdav({
    required dynamic client,
    required String localArchivePath,
    required String remoteArchivePath,
  }) async {
    await _readFileWithCandidates(
      client: client,
      localFilePath: localArchivePath,
      remoteCandidates: _remotePathCandidates(remoteArchivePath),
      logPrefix: 'WebDAV restore archive',
    );
  }

  Future<void> _readFileWithCandidates({
    required dynamic client,
    required String localFilePath,
    required List<String> remoteCandidates,
    required String logPrefix,
  }) async {
    Object? lastError;
    for (final remotePath in remoteCandidates) {
      try {
        await AppServices.log.info('$logPrefix try path: $remotePath');
        await client.read2File(remotePath, localFilePath);
        await AppServices.log.info('$logPrefix path success: $remotePath');
        return;
      } catch (e) {
        lastError = e;
        await AppServices.log.error('$logPrefix path failed: $remotePath', _formatDioError(e));
      }
    }
    throw Exception('下载文件失败: ${_formatDioError(lastError ?? 'unknown error')}');
  }

  int _extractBackupArchive({
    required String localArchivePath,
    required String localConfigPath,
    required String localUsageJsonPath,
    required Directory localAuthDir,
  }) {
    final archiveFile = File(localArchivePath);
    if (!archiveFile.existsSync()) {
      throw Exception('备份压缩包不存在: $localArchivePath');
    }

    final tmpDir = Directory.systemTemp.createTempSync('cpaclient_webdav_restore_');
    try {
      final compressed = archiveFile.readAsBytesSync();
      final tarData = GZipDecoder().decodeBytes(compressed);
      final archive = TarDecoder().decodeBytes(tarData);
      for (final entry in archive.files.where((entry) => entry.isFile)) {
        final outputPath = p.join(tmpDir.path, entry.name);
        final outputFile = File(outputPath);
        outputFile.parent.createSync(recursive: true);
        outputFile.writeAsBytesSync(entry.content as List<int>, flush: true);
      }

      final extractedConfig = File(p.join(tmpDir.path, 'config.yaml'));
      final extractedUsage = File(p.join(tmpDir.path, 'usage.json'));
      if (!extractedConfig.existsSync()) {
        throw Exception('压缩包缺少 config.yaml');
      }
      if (!extractedUsage.existsSync()) {
        throw Exception('压缩包缺少 usage.json');
      }

      extractedConfig.copySync(localConfigPath);
      extractedUsage.copySync(localUsageJsonPath);

      if (!localAuthDir.existsSync()) {
        localAuthDir.createSync(recursive: true);
      }

      var restoredAuth = 0;
      final extractedAuthDir = Directory(p.join(tmpDir.path, CoreDefaults.webdavAuthJsonDirName));
      if (extractedAuthDir.existsSync()) {
        final authJsonFiles = extractedAuthDir
            .listSync(recursive: false, followLinks: false)
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.json'))
            .toList(growable: false);
        for (final file in authJsonFiles) {
          final name = p.basename(file.path);
          file.copySync(p.join(localAuthDir.path, name));
          restoredAuth += 1;
        }
      }

      return restoredAuth;
    } finally {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    }
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
