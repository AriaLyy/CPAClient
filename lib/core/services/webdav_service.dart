import 'dart:async';
import 'dart:io';

import 'package:cpaclient/core/constants/core_defaults.dart';
import 'package:cpaclient/core/models/webdav_backup_version.dart';
import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:cpaclient/core/services/core_process_manager.dart';
import 'package:cpaclient/core/services/management_access_service.dart';
import 'package:cpaclient/core/services/sandbox_config_service.dart';
import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:cpaclient/core/services/usage_network_service.dart';
import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:webdav_client/webdav_client.dart' hide File;

class WebdavRestoreConfigResult {
  const WebdavRestoreConfigResult({
    required this.message,
    required this.restoredPort,
    required this.restoredSecretKey,
  });

  final String message;
  final int restoredPort;
  final String restoredSecretKey;
}

class _WebdavVersionListingResult {
  const _WebdavVersionListingResult({
    required this.root,
    required this.versions,
  });

  final String root;
  final List<String> versions;
}

class WebdavService {
  WebdavService({
    required SandboxPathService paths,
    required SandboxConfigService sandboxConfig,
    required AppLogService log,
    required UsageNetworkService usageNetwork,
    required ManagementAccessService managementAccess,
    required CoreProcessManager process,
  })  : _paths = paths,
        _sandboxConfig = sandboxConfig,
        _log = log,
        _usageNetwork = usageNetwork,
        _managementAccess = managementAccess,
        _process = process;

  final SandboxPathService _paths;
  final SandboxConfigService _sandboxConfig;
  final AppLogService _log;
  final UsageNetworkService _usageNetwork;
  final ManagementAccessService _managementAccess;
  final CoreProcessManager _process;

  bool _webdavSyncInProgress = false;
  static const int _usageVersionProbeLimit = 5;
  DateTime? _webdavBlockedUntilUtc;
  int _webdavBlockedCooldownMinutes = 0;

  String normalizeUrl(String inputUrl) {
    final trimmed = inputUrl.trim();
    if (trimmed.endsWith('/')) {
      throw Exception('WebDAV 地址不能以 / 结尾');
    }
    return trimmed.endsWith('/CpaClient') ? trimmed : '$trimmed/CpaClient';
  }

  Future<void> testConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    final inputUrl = url.trim();
    if (inputUrl.isEmpty) {
      throw Exception('请先填写 WebDAV 地址');
    }
    final normalizedUrl = normalizeUrl(inputUrl);
    final cooldownMessage = _currentCooldownMessage();
    if (cooldownMessage != null) {
      throw Exception(cooldownMessage);
    }
    try {
      await _log.info(
        'WebDAV test start: url=$normalizedUrl user=${username.trim()}',
      );
      final client = _createWebdavClient(
        url: normalizedUrl,
        username: username.trim(),
        password: password,
        debug: true,
      );
      await client.ping();
      _resetBlockedCooldownState();
      await _log.info('WebDAV test success: url=$normalizedUrl');
    } catch (e) {
      _markBlockedCooldownIfNeeded(e);
      await _log.error(
          'WebDAV test failed: url=$normalizedUrl', _formatDioError(e));
      rethrow;
    }
  }

  Future<String> backup({
    required String url,
    required String username,
    required String password,
    required String settingsWebuiSecretKey,
    required String defaultWebuiPassword,
    required bool isCoreRunning,
    required bool isAuto,
  }) async {
    if (_webdavSyncInProgress) {
      const msg = '已有备份/还原任务正在执行，已跳过';
      await _log.info('WebDAV backup skipped: in-progress, isAuto=$isAuto');
      return msg;
    }

    final cooldownMessage = _currentCooldownMessage();
    if (cooldownMessage != null) {
      await _log.info('WebDAV backup skipped: $cooldownMessage');
      return cooldownMessage;
    }

    final normalizedUrl = normalizeUrl(url);
    _webdavSyncInProgress = true;
    try {
      final cfg = await _sandboxConfig.ensureSandboxConfig();
      final authDir = await _sandboxConfig.readAuthDir();
      final authRoot = _paths.resolveAuthDir(authDir);
      final authJsonFiles = _listRootJsonFiles(authRoot);
      final usageJsonPath = await _resolveLocalUsageJsonPath();
      await _exportUsageJsonSnapshot(
        isCoreRunning: isCoreRunning,
        localUsageJsonPath: usageJsonPath,
        settingsWebuiSecretKey: settingsWebuiSecretKey,
        defaultWebuiPassword: defaultWebuiPassword,
        trigger: isAuto ? 'webdav-backup-auto' : 'webdav-backup-manual',
      );
      final versionId = newBackupVersionId();
      final versionRoot =
          '${CoreDefaults.webdavBackupVersionsDirName}/$versionId';
      final remoteArchivePath =
          '$versionRoot/${CoreDefaults.webdavBackupArchiveName}';

      await _log.info(
        'WebDAV backup start: url=$normalizedUrl version=$versionId local=${cfg.path} authDir=${authRoot.path} count=${authJsonFiles.length} usage=$usageJsonPath isAuto=$isAuto',
      );

      final client = _createWebdavClient(
        url: normalizedUrl,
        username: username,
        password: password,
        debug: false,
      );

      final archivePath = await buildBackupArchive(
        localConfigPath: cfg.path,
        localUsageJsonPath: usageJsonPath,
        localAuthJsonFiles: authJsonFiles,
      );
      _validateBackupArchiveContents(archivePath);
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

      final cleanupWarning = await _cleanupOldWebdavBackups(
        url: normalizedUrl,
        username: username,
        password: password,
      );
      final msgBase =
          '已备份压缩包版本 $versionId（${CoreDefaults.webdavBackupArchiveName}，最多保留 ${CoreDefaults.webdavBackupMaxVersions} 个）';
      final msg = cleanupWarning == null ? msgBase : '$msgBase；$cleanupWarning';
      _resetBlockedCooldownState();
      await _log.info('WebDAV backup success: $msg, isAuto=$isAuto');
      return msg;
    } catch (e) {
      _markBlockedCooldownIfNeeded(e);
      await _log.error(
          'WebDAV backup failed, isAuto=$isAuto', _formatDioError(e));
      rethrow;
    } finally {
      _webdavSyncInProgress = false;
    }
  }

  Future<String> backupUsageOnly({
    required String url,
    required String username,
    required String password,
    required String settingsWebuiSecretKey,
    required String defaultWebuiPassword,
    required bool isCoreRunning,
  }) async {
    if (_webdavSyncInProgress) {
      const msg = '已有备份/还原任务正在执行，已跳过';
      await _log.info('WebDAV usage-only backup skipped: in-progress');
      return msg;
    }

    final cooldownMessage = _currentCooldownMessage();
    if (cooldownMessage != null) {
      await _log.info('WebDAV usage-only backup skipped: $cooldownMessage');
      return cooldownMessage;
    }

    final normalizedUrl = normalizeUrl(url);
    _webdavSyncInProgress = true;
    try {
      final usageJsonPath = await _resolveLocalUsageJsonPath();
      await _exportUsageJsonSnapshot(
        isCoreRunning: isCoreRunning,
        localUsageJsonPath: usageJsonPath,
        settingsWebuiSecretKey: settingsWebuiSecretKey,
        defaultWebuiPassword: defaultWebuiPassword,
        trigger: 'webdav-backup-usage-only',
      );
      final versionId = newBackupVersionId();
      final versionRoot = '${CoreDefaults.webdavUsageSyncDirName}/$versionId';
      final remoteArchivePath =
          '$versionRoot/${CoreDefaults.webdavUsageArchiveName}';
      await _log.info(
        'WebDAV usage-only backup start: url=$normalizedUrl version=$versionId usage=$usageJsonPath',
      );

      final client = _createWebdavClient(
        url: normalizedUrl,
        username: username,
        password: password,
        debug: false,
      );

      final archivePath = await buildUsageOnlyArchive(
        localUsageJsonPath: usageJsonPath,
      );
      try {
        await _writeUsageArchiveToWebdav(
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

      final cleanupWarning = await _cleanupOldWebdavUsageSyncVersions(
        url: normalizedUrl,
        username: username,
        password: password,
      );
      final msgBase =
          '已备份 usage 压缩包版本 $versionId（${CoreDefaults.webdavUsageArchiveName}，最多保留 ${CoreDefaults.webdavUsageSyncMaxVersions} 个）';
      final msg = cleanupWarning == null ? msgBase : '$msgBase；$cleanupWarning';
      _resetBlockedCooldownState();
      await _log.info('WebDAV usage-only backup success: $msg');
      return msg;
    } catch (e) {
      _markBlockedCooldownIfNeeded(e);
      await _log.error('WebDAV usage-only backup failed', _formatDioError(e));
      rethrow;
    } finally {
      _webdavSyncInProgress = false;
    }
  }

  Future<List<WebdavBackupVersion>> listVersions({
    required String url,
    required String username,
    required String password,
  }) async {
    final inputUrl = url.trim();
    if (inputUrl.isEmpty) {
      return const <WebdavBackupVersion>[];
    }

    final normalizedUrl = normalizeUrl(inputUrl);
    final listing = await _listVersionDirectories(
      url: normalizedUrl,
      username: username,
      password: password,
    );
    return listing.versions
        .map((id) => WebdavBackupVersion(
              id: id,
              displayLabel: formatBackupVersionLabel(id),
            ))
        .toList(growable: false);
  }

  Future<String?> latestUsageVersionId({
    required String url,
    required String username,
    required String password,
  }) async {
    final inputUrl = url.trim();
    if (inputUrl.isEmpty) {
      return null;
    }

    final cooldownMessage = _currentCooldownMessage();
    if (cooldownMessage != null) {
      await _log.info('WebDAV latest usage version skipped: $cooldownMessage');
      return null;
    }

    final normalizedUrl = normalizeUrl(inputUrl);
    final listing = await _listUsageVersionDirectories(
      url: normalizedUrl,
      username: username,
      password: password,
    );
    if (listing.versions.isEmpty) {
      return null;
    }
    return listing.versions.first;
  }

  Future<bool> restoreUsage({
    required String url,
    required String username,
    required String password,
    required String versionId,
    required String settingsWebuiSecretKey,
    required String defaultWebuiPassword,
  }) async {
    if (_webdavSyncInProgress) {
      await _log.info('WebDAV restore usage skipped: in-progress');
      return false;
    }

    final cooldownMessage = _currentCooldownMessage();
    if (cooldownMessage != null) {
      await _log.info('WebDAV restore usage skipped: $cooldownMessage');
      return false;
    }

    final normalizedUrl = normalizeUrl(url);
    final selectedVersionId = versionId.trim();
    if (selectedVersionId.isEmpty) {
      return false;
    }

    final remoteArchiveCandidates =
        buildRestoreUsageRemoteArchiveCandidates(selectedVersionId);

    _webdavSyncInProgress = true;
    try {
      final cfg = await _sandboxConfig.ensureSandboxConfig();
      final usageJsonPath = await _resolveLocalUsageJsonPath();
      final localArchivePath =
          p.join(cfg.parent.path, 'webdav_restore_backup_usage.zip');

      final client = _createWebdavClient(
        url: normalizedUrl,
        username: username,
        password: password,
        debug: false,
      );

      await _readUsageArchiveFromWebdav(
        client: client,
        localArchivePath: localArchivePath,
        remoteCandidates: remoteArchiveCandidates,
      );

      try {
        extractUsageFromBackupArchive(
          localArchivePath: localArchivePath,
          localUsageJsonPath: usageJsonPath,
        );
      } finally {
        final archiveFile = File(localArchivePath);
        if (archiveFile.existsSync()) {
          archiveFile.deleteSync();
        }
      }

      final port = await _sandboxConfig.readPort();
      final secretKey = await _resolveManagementKeyForUsage(
        settingsWebuiSecretKey: settingsWebuiSecretKey,
        defaultWebuiPassword: defaultWebuiPassword,
      );
      await _importUsageJsonWithRetry(
        localUsageJsonPath: usageJsonPath,
        port: port,
        secretKey: secretKey,
        trigger: 'latest-usage-restore',
      );
      _resetBlockedCooldownState();
      await _log
          .info('WebDAV restore usage success: version=$selectedVersionId');
      return true;
    } catch (e) {
      _markBlockedCooldownIfNeeded(e);
      await _log.error('WebDAV restore usage failed', _formatDioError(e));
      return false;
    } finally {
      _webdavSyncInProgress = false;
    }
  }

  Future<WebdavRestoreConfigResult> restoreConfig({
    required String url,
    required String username,
    required String password,
    required String versionId,
    required String settingsWebuiSecretKey,
    required String defaultWebuiPassword,
  }) async {
    if (_webdavSyncInProgress) {
      throw Exception('已有备份/还原任务正在执行，已跳过');
    }

    final normalizedUrl = normalizeUrl(url);
    final selectedVersionId = versionId.trim();
    if (selectedVersionId.isEmpty) {
      throw Exception('请选择要还原的备份版本');
    }

    final remoteArchivePath =
        '${CoreDefaults.webdavBackupVersionsDirName}/$selectedVersionId/${CoreDefaults.webdavBackupArchiveName}';

    _webdavSyncInProgress = true;
    final cfg = await _sandboxConfig.ensureSandboxConfig();
    final authDir = await _sandboxConfig.readAuthDir();
    final authRoot = _paths.resolveAuthDir(authDir);
    final usageJsonPath = await _resolveLocalUsageJsonPath();
    final localArchivePath =
        p.join(cfg.parent.path, 'webdav_restore_backup.zip');

    await _log.info(
      'WebDAV restore start: url=$normalizedUrl version=$selectedVersionId local=${cfg.path} restoreTo=${authRoot.path} usage=$usageJsonPath archive=$localArchivePath',
    );

    try {
      final client = _createWebdavClient(
        url: normalizedUrl,
        username: username,
        password: password,
        debug: false,
      );

      await _readBackupArchiveFromWebdav(
        client: client,
        localArchivePath: localArchivePath,
        remoteArchivePath: remoteArchivePath,
      );

      int restoredJsonCount = 0;
      try {
        restoredJsonCount = extractBackupArchive(
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
      final restoredPort = await _sandboxConfig.readPort();
      final restoredSecretKey = await _resolveManagementKeyForUsage(
        settingsWebuiSecretKey: settingsWebuiSecretKey,
        defaultWebuiPassword: defaultWebuiPassword,
      );
      await _importUsageJsonWithRetry(
        localUsageJsonPath: usageJsonPath,
        port: restoredPort,
        secretKey: restoredSecretKey,
        trigger: 'manual-config-restore',
      );
      await _log.info(
        'WebDAV restore success: version=$selectedVersionId archive=${CoreDefaults.webdavBackupArchiveName} auth-json($restoredJsonCount)',
      );
      final msg =
          '已解压还原版本 $selectedVersionId（${CoreDefaults.webdavBackupArchiveName}，auth-json $restoredJsonCount 个），并重启核心';
      return WebdavRestoreConfigResult(
        message: msg,
        restoredPort: restoredPort,
        restoredSecretKey: restoredSecretKey,
      );
    } catch (e) {
      await _log.error('WebDAV restore failed', _formatDioError(e));
      rethrow;
    } finally {
      _webdavSyncInProgress = false;
    }
  }

  String newBackupVersionId() {
    final now = DateTime.now().toUtc();
    String pad2(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${pad2(now.month)}${pad2(now.day)}T${pad2(now.hour)}${pad2(now.minute)}${pad2(now.second)}Z';
  }

  DateTime? parseBackupVersionTime(String versionId) {
    final match = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$')
        .firstMatch(versionId);
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

  String formatBackupVersionLabel(String versionId) {
    final time = parseBackupVersionTime(versionId);
    if (time == null) {
      return versionId;
    }
    final local = time.toLocal();
    String pad2(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${pad2(local.month)}-${pad2(local.day)} ${pad2(local.hour)}:${pad2(local.minute)}:${pad2(local.second)}';
  }

  List<String> buildRemotePathCandidates(String remotePath) {
    final normalized =
        remotePath.startsWith('/') ? remotePath.substring(1) : remotePath;
    return <String>[normalized, '/$normalized'];
  }

  List<String> buildRestoreUsageRemoteArchiveCandidates(String versionId) {
    final versionRoot = '${CoreDefaults.webdavUsageSyncDirName}/$versionId';
    final usageOnlyPath = '$versionRoot/${CoreDefaults.webdavUsageArchiveName}';
    return <String>[
      ...buildRemotePathCandidates(usageOnlyPath),
    ];
  }

  Future<String> buildUsageOnlyArchive({
    required String localUsageJsonPath,
  }) async {
    final usageFile = File(localUsageJsonPath);
    if (!usageFile.existsSync()) {
      throw Exception('usage.json 不存在: $localUsageJsonPath');
    }

    final tmpDir =
        await Directory.systemTemp.createTemp('cpaclient_webdav_usage_backup_');
    final archivePath =
        p.join(tmpDir.path, CoreDefaults.webdavUsageArchiveName);
    final stageDir = await Directory.systemTemp
        .createTemp('cpaclient_webdav_usage_backup_stage_');

    try {
      usageFile.copySync(p.join(stageDir.path, 'usage.json'));
      _writeZipFromDirectory(
        sourceDir: stageDir,
        archivePath: archivePath,
        action: '创建 usage 备份压缩包',
      );
      return archivePath;
    } finally {
      if (stageDir.existsSync()) {
        stageDir.deleteSync(recursive: true);
      }
    }
  }

  Future<String> buildBackupArchive({
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

    final tmpDir =
        await Directory.systemTemp.createTemp('cpaclient_webdav_backup_');
    final archivePath =
        p.join(tmpDir.path, CoreDefaults.webdavBackupArchiveName);
    final stageDir =
        await Directory.systemTemp.createTemp('cpaclient_webdav_backup_stage_');

    try {
      configFile.copySync(p.join(stageDir.path, 'config.yaml'));
      usageFile.copySync(p.join(stageDir.path, 'usage.json'));

      final stagedAuthDir =
          Directory(p.join(stageDir.path, CoreDefaults.webdavAuthJsonDirName));
      for (final jsonFile in localAuthJsonFiles) {
        if (!stagedAuthDir.existsSync()) {
          stagedAuthDir.createSync(recursive: true);
        }
        final name = p.basename(jsonFile.path);
        jsonFile.copySync(p.join(stagedAuthDir.path, name));
      }

      _writeZipFromDirectory(
        sourceDir: stageDir,
        archivePath: archivePath,
        action: '创建完整备份压缩包',
      );
      return archivePath;
    } finally {
      if (stageDir.existsSync()) {
        stageDir.deleteSync(recursive: true);
      }
    }
  }

  void extractUsageFromBackupArchive({
    required String localArchivePath,
    required String localUsageJsonPath,
  }) {
    final archiveFile = File(localArchivePath);
    if (!archiveFile.existsSync()) {
      throw Exception('备份压缩包不存在: $localArchivePath');
    }

    final tmpDir =
        Directory.systemTemp.createTempSync('cpaclient_webdav_restore_usage_');
    try {
      _extractZipToDirectory(
        archivePath: localArchivePath,
        outputDir: tmpDir,
        action: '解压 usage 备份压缩包',
      );

      final extractedUsage = _findExtractedFileByName(tmpDir, 'usage.json');
      if (extractedUsage == null || !extractedUsage.existsSync()) {
        throw Exception('压缩包缺少 usage.json');
      }
      extractedUsage.copySync(localUsageJsonPath);
    } finally {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    }
  }

  int extractBackupArchive({
    required String localArchivePath,
    required String localConfigPath,
    required String localUsageJsonPath,
    required Directory localAuthDir,
  }) {
    final archiveFile = File(localArchivePath);
    if (!archiveFile.existsSync()) {
      throw Exception('备份压缩包不存在: $localArchivePath');
    }

    final tmpDir =
        Directory.systemTemp.createTempSync('cpaclient_webdav_restore_');
    try {
      _extractZipToDirectory(
        archivePath: localArchivePath,
        outputDir: tmpDir,
        action: '解压完整备份压缩包',
      );

      final extractedConfig = _findExtractedFileByName(tmpDir, 'config.yaml');
      final extractedUsage = _findExtractedFileByName(tmpDir, 'usage.json');
      if (extractedConfig == null || !extractedConfig.existsSync()) {
        final entries = _readZipEntryNames(localArchivePath);
        if (extractedUsage != null && extractedUsage.existsSync()) {
          throw Exception(
              '该备份仅包含 usage.json，缺少 config.yaml，无法执行配置还原；entries=${entries.join(',')}');
        }
        throw Exception('压缩包缺少 config.yaml；entries=${entries.join(',')}');
      }
      if (extractedUsage == null || !extractedUsage.existsSync()) {
        throw Exception('压缩包缺少 usage.json');
      }

      extractedConfig.copySync(localConfigPath);
      extractedUsage.copySync(localUsageJsonPath);

      if (!localAuthDir.existsSync()) {
        localAuthDir.createSync(recursive: true);
      }

      var restoredAuth = 0;
      final extractedAuthDir =
          Directory(p.join(tmpDir.path, CoreDefaults.webdavAuthJsonDirName));
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

  Future<String> _resolveLocalUsageJsonPath() async {
    final usageFile = await _paths.usageJsonFile();
    return usageFile.path;
  }

  File? _findExtractedFileByName(Directory root, String fileName) {
    final direct = File(p.join(root.path, fileName));
    if (direct.existsSync()) {
      return direct;
    }
    final normalizedName = fileName.toLowerCase();
    final files = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList(growable: false);
    for (final file in files) {
      final normalizedPath = file.path.replaceAll('\\', '/');
      if (p.basename(normalizedPath).toLowerCase() == normalizedName) {
        return file;
      }
    }
    return null;
  }

  Future<void> _exportUsageJsonSnapshot({
    required bool isCoreRunning,
    required String localUsageJsonPath,
    required String settingsWebuiSecretKey,
    required String defaultWebuiPassword,
    required String trigger,
  }) async {
    if (!isCoreRunning) {
      throw Exception(
          'Local usage export skipped: core not running, trigger=$trigger');
    }

    final port = await _sandboxConfig.readPort();
    final secretKey = await _resolveManagementKeyForUsage(
      settingsWebuiSecretKey: settingsWebuiSecretKey,
      defaultWebuiPassword: defaultWebuiPassword,
    );
    await _exportUsageJson(
      localUsageJsonPath: localUsageJsonPath,
      port: port,
      secretKey: secretKey,
    );
    await _log.info(
        'Local usage export success: trigger=$trigger output=$localUsageJsonPath');
  }

  Future<String> _resolveManagementKeyForUsage({
    required String settingsWebuiSecretKey,
    required String defaultWebuiPassword,
  }) {
    return _managementAccess.resolveUsageSecretKey(
      settingsWebuiSecretKey: settingsWebuiSecretKey,
      defaultSecretKey: defaultWebuiPassword,
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
    await _log.info('Usage export start: uri=$uri output=$localUsageJsonPath');
    try {
      await _usageNetwork.downloadUsageJson(
        uri: uri,
        secretKey: key,
        outputPath: localUsageJsonPath,
      );
      await _log
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
    await _log.info('Usage import start: uri=$uri input=$localUsageJsonPath');
    try {
      final payload = await usageFile.readAsString();
      await _usageNetwork.importUsageJson(
        uri: uri,
        secretKey: key,
        payload: payload,
      );
      await _log
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
        await _log.info(
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
        await _log.error(
          'Usage import attempt failed: trigger=$trigger attempt=$attempt',
          e,
        );
        if (attempt == maxAttempts) {
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        currentPort = await _sandboxConfig.readPort();
      }
    }

    throw Exception('导入 usage.json 失败（重试 $maxAttempts 次）: $lastError');
  }

  Future<void> _restartCoreAfterRestore() async {
    await _log.info('WebDAV restore restarting core begin');
    await _process.stop();
    await _process.start();
    await _log.info('WebDAV restore restarting core completed');
  }

  void _writeZipFromDirectory({
    required Directory sourceDir,
    required String archivePath,
    required String action,
  }) {
    try {
      final archiveFile = File(archivePath);
      if (!archiveFile.parent.existsSync()) {
        archiveFile.parent.createSync(recursive: true);
      }

      final archive = Archive();
      final entities =
          sourceDir.listSync(recursive: true, followLinks: false).whereType<File>();
      for (final file in entities) {
        final relativePath = p.relative(file.path, from: sourceDir.path);
        final bytes = file.readAsBytesSync();
        archive.addFile(ArchiveFile(relativePath, bytes.length, bytes));
      }

      final encoded = ZipEncoder().encode(archive);
      archiveFile.writeAsBytesSync(encoded, flush: true);
    } catch (e) {
      throw Exception('$action失败: $e');
    }
  }

  void _validateBackupArchiveContents(String archivePath) {
    final entries = _readZipEntryNames(archivePath).map((e) => e.toLowerCase());
    final hasConfig = entries.any((name) => name.endsWith('/config.yaml') || name == 'config.yaml');
    final hasUsage = entries.any((name) => name.endsWith('/usage.json') || name == 'usage.json');
    if (!hasConfig || !hasUsage) {
      throw Exception(
          '备份压缩包内容不完整: config.yaml=$hasConfig usage.json=$hasUsage entries=${_readZipEntryNames(archivePath).join(',')}');
    }
  }

  List<String> _readZipEntryNames(String archivePath) {
    final bytes = File(archivePath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    return archive
        .map((entry) => entry.name.replaceAll('\\', '/'))
        .toList(growable: false);
  }

  void _extractZipToDirectory({
    required String archivePath,
    required Directory outputDir,
    required String action,
  }) {
    try {
      if (!outputDir.existsSync()) {
        outputDir.createSync(recursive: true);
      }
      final bytes = File(archivePath).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive) {
        final normalizedName = entry.name.replaceAll('\\', '/');
        final outputPath = p.normalize(p.join(outputDir.path, normalizedName));
        if (!p.isWithin(outputDir.path, outputPath) &&
            outputPath != outputDir.path) {
          continue;
        }
        if (entry.isFile) {
          final outFile = File(outputPath);
          outFile.parent.createSync(recursive: true);
          final content = entry.content as List<int>;
          outFile.writeAsBytesSync(content, flush: true);
        } else {
          Directory(outputPath).createSync(recursive: true);
        }
      }
    } catch (e) {
      throw Exception('$action失败: $e');
    }
  }

  Future<_WebdavVersionListingResult> _listVersionDirectories({
    required String url,
    required String username,
    required String password,
  }) async {
    final client = _createWebdavClient(
      url: url,
      username: username,
      password: password,
      debug: false,
    );
    final root = CoreDefaults.webdavBackupVersionsDirName;

    try {
      final entries = await client.readDir(root);
      final versions = <String>[];
      for (final entry in entries.where((entry) => entry.isDir == true)) {
        final name = p.basename((entry.path ?? '').replaceAll('\\', '/'));
        if (parseBackupVersionTime(name) == null) {
          continue;
        }
        final remoteArchivePath =
            '$root/$name/${CoreDefaults.webdavBackupArchiveName}';
        if (await _remoteFileExists(
            client: client, remotePath: remoteArchivePath)) {
          versions.add(name);
        }
      }
      final sorted = versions.toSet().toList(growable: false)
        ..sort((String a, String b) => b.compareTo(a));
      return _WebdavVersionListingResult(root: root, versions: sorted);
    } catch (e) {
      if (_isRemoteNotFound(e)) {
        return _WebdavVersionListingResult(
            root: root, versions: const <String>[]);
      }
      rethrow;
    }
  }

  Future<_WebdavVersionListingResult> _listUsageVersionDirectories({
    required String url,
    required String username,
    required String password,
  }) async {
    final client = _createWebdavClient(
      url: url,
      username: username,
      password: password,
      debug: false,
    );
    final root = CoreDefaults.webdavUsageSyncDirName;

    try {
      final entries = await client.readDir(root);
      final allVersionIds = <String>[];
      for (final entry in entries.where((entry) => entry.isDir == true)) {
        final name = p.basename((entry.path ?? '').replaceAll('\\', '/'));
        if (parseBackupVersionTime(name) != null) {
          allVersionIds.add(name);
        }
      }
      final sortedCandidates = allVersionIds.toSet().toList(growable: false)
        ..sort((String a, String b) => b.compareTo(a));

      final versions = <String>[];
      for (final name in sortedCandidates.take(_usageVersionProbeLimit)) {
        final remoteArchivePath =
            '$root/$name/${CoreDefaults.webdavUsageArchiveName}';
        if (await _remoteFileExists(
            client: client, remotePath: remoteArchivePath)) {
          versions.add(name);
          break;
        }
      }
      _resetBlockedCooldownState();
      return _WebdavVersionListingResult(root: root, versions: versions);
    } catch (e) {
      _markBlockedCooldownIfNeeded(e);
      if (_isRemoteNotFound(e)) {
        return _WebdavVersionListingResult(
            root: root, versions: const <String>[]);
      }
      rethrow;
    }
  }

  Future<_WebdavVersionListingResult> _listUsageVersionDirectoriesForCleanup({
    required String url,
    required String username,
    required String password,
  }) async {
    final client = _createWebdavClient(
      url: url,
      username: username,
      password: password,
      debug: false,
    );
    final root = CoreDefaults.webdavUsageSyncDirName;

    try {
      final entries = await client.readDir(root);
      final versions = <String>[];
      for (final entry in entries.where((entry) => entry.isDir == true)) {
        final name = p.basename((entry.path ?? '').replaceAll('\\', '/'));
        if (parseBackupVersionTime(name) != null) {
          versions.add(name);
        }
      }
      final sorted = versions.toSet().toList(growable: false)
        ..sort((String a, String b) => b.compareTo(a));
      return _WebdavVersionListingResult(root: root, versions: sorted);
    } catch (e) {
      _markBlockedCooldownIfNeeded(e);
      if (_isRemoteNotFound(e)) {
        return _WebdavVersionListingResult(
            root: root, versions: const <String>[]);
      }
      rethrow;
    }
  }

  Future<String?> _cleanupOldWebdavBackups({
    required String url,
    required String username,
    required String password,
  }) async {
    try {
      final listing = await _listVersionDirectories(
        url: url,
        username: username,
        password: password,
      );
      if (listing.versions.length <= CoreDefaults.webdavBackupMaxVersions) {
        return null;
      }
      final toDelete =
          listing.versions.skip(CoreDefaults.webdavBackupMaxVersions);
      final client = _createWebdavClient(
        url: url,
        username: username,
        password: password,
        debug: false,
      );
      for (final version in toDelete) {
        await client.removeAll('${listing.root}/$version');
      }
      return null;
    } catch (e) {
      await _log.error('WebDAV backup cleanup failed', _formatDioError(e));
      return '清理旧版本失败（不影响本次备份）';
    }
  }

  Future<String?> _cleanupOldWebdavUsageSyncVersions({
    required String url,
    required String username,
    required String password,
  }) async {
    try {
      final listing = await _listUsageVersionDirectoriesForCleanup(
        url: url,
        username: username,
        password: password,
      );
      if (listing.versions.length <= CoreDefaults.webdavUsageSyncMaxVersions) {
        return null;
      }
      final toDelete =
          listing.versions.skip(CoreDefaults.webdavUsageSyncMaxVersions);
      final client = _createWebdavClient(
        url: url,
        username: username,
        password: password,
        debug: false,
      );
      for (final version in toDelete) {
        await client.removeAll('${listing.root}/$version');
      }
      return null;
    } catch (e) {
      await _log.error('WebDAV usage sync cleanup failed', _formatDioError(e));
      return '清理旧 usage 版本失败（不影响本次备份）';
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

  Future<void> _writeBackupArchiveToWebdav({
    required dynamic client,
    required String localArchivePath,
    required String remoteArchivePath,
  }) async {
    await _writeFileStrict(
      client: client,
      localFilePath: localArchivePath,
      remotePath: remoteArchivePath,
      logPrefix: 'WebDAV backup archive',
    );
  }

  Future<void> _readBackupArchiveFromWebdav({
    required dynamic client,
    required String localArchivePath,
    required String remoteArchivePath,
  }) async {
    await _readFileStrict(
      client: client,
      localFilePath: localArchivePath,
      remotePath: remoteArchivePath,
      logPrefix: 'WebDAV restore archive',
    );
  }

  Future<void> _writeUsageArchiveToWebdav({
    required dynamic client,
    required String localArchivePath,
    required String remoteArchivePath,
  }) async {
    await _writeFileWithCandidates(
      client: client,
      localFilePath: localArchivePath,
      remoteCandidates: buildRemotePathCandidates(remoteArchivePath),
      logPrefix: 'WebDAV usage-only backup archive',
    );
  }

  Future<void> _readUsageArchiveFromWebdav({
    required dynamic client,
    required String localArchivePath,
    required List<String> remoteCandidates,
  }) async {
    await _readFileWithCandidates(
      client: client,
      localFilePath: localArchivePath,
      remoteCandidates: remoteCandidates,
      logPrefix: 'WebDAV restore usage archive',
    );
  }

  Future<void> _writeFileStrict({
    required dynamic client,
    required String localFilePath,
    required String remotePath,
    required String logPrefix,
  }) async {
    final localFile = File(localFilePath);
    if (!localFile.existsSync()) {
      throw Exception('本地文件不存在: $localFilePath');
    }
    await _log.info('$logPrefix strict path: $remotePath');
    await client.writeFromFile(localFilePath, remotePath);
    await _log.info('$logPrefix strict path success: $remotePath');
  }

  Future<void> _readFileStrict({
    required dynamic client,
    required String localFilePath,
    required String remotePath,
    required String logPrefix,
  }) async {
    await _log.info('$logPrefix strict path: $remotePath');
    await client.read2File(remotePath, localFilePath);
    await _log.info('$logPrefix strict path success: $remotePath');
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
        await _log.info('$logPrefix try path: $remotePath');
        await client.writeFromFile(localFilePath, remotePath);
        await _log.info('$logPrefix path success: $remotePath');
        return;
      } catch (e) {
        lastError = e;
        await _log.error(
            '$logPrefix path failed: $remotePath', _formatDioError(e));
      }
    }
    throw Exception('上传文件失败: ${_formatDioError(lastError ?? 'unknown error')}');
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
        await _log.info('$logPrefix try path: $remotePath');
        await client.read2File(remotePath, localFilePath);
        await _log.info('$logPrefix path success: $remotePath');
        return;
      } catch (e) {
        lastError = e;
        await _log.error(
            '$logPrefix path failed: $remotePath', _formatDioError(e));
      }
    }
    throw Exception('下载文件失败: ${_formatDioError(lastError ?? 'unknown error')}');
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

  bool _isBlockedTemporarilyError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final body = error.response?.data?.toString() ?? '';
      if (status == 503 && body.contains('BlockedTemporarily')) {
        return true;
      }
    }
    final text = error.toString();
    return text.contains('BlockedTemporarily') && text.contains('503');
  }

  void _markBlockedCooldownIfNeeded(Object error) {
    if (!_isBlockedTemporarilyError(error)) {
      return;
    }
    if (_webdavBlockedCooldownMinutes <= 0) {
      _webdavBlockedCooldownMinutes = 10;
    } else if (_webdavBlockedCooldownMinutes < 20) {
      _webdavBlockedCooldownMinutes = 20;
    } else {
      _webdavBlockedCooldownMinutes = 30;
    }
    final until = DateTime.now()
        .toUtc()
        .add(Duration(minutes: _webdavBlockedCooldownMinutes));
    _webdavBlockedUntilUtc = until;
  }

  void _resetBlockedCooldownState() {
    _webdavBlockedUntilUtc = null;
    _webdavBlockedCooldownMinutes = 0;
  }

  String? _currentCooldownMessage() {
    final until = _webdavBlockedUntilUtc;
    if (until == null) {
      return null;
    }
    final now = DateTime.now().toUtc();
    if (!now.isBefore(until)) {
      _webdavBlockedUntilUtc = null;
      return null;
    }
    final remainSeconds = until.difference(now).inSeconds;
    return 'WebDAV 服务端限流中，请约 ${remainSeconds}s 后重试';
  }

  @visibleForTesting
  String? latestUsageVersionIdFromCandidatesForTest(List<String> versionIds) {
    final sorted = versionIds
        .where((id) => parseBackupVersionTime(id) != null)
        .toSet()
        .toList(growable: false)
      ..sort((String a, String b) => b.compareTo(a));
    if (sorted.isEmpty) {
      return null;
    }
    return sorted.first;
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
    client.setHeaders(
        <String, dynamic>{'content-type': 'application/octet-stream'});
    return client;
  }

  String formatDioError(Object error) => _formatDioError(error);

  @visibleForTesting
  String formatDioErrorForTest(Object error) => _formatDioError(error);

  String _formatDioError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final method = error.requestOptions.method;
      final uri = error.requestOptions.uri;
      final data = error.response?.data;
      final body = data == null ? 'null' : data.toString();
      final inner = error.error;
      final innerText = inner == null ? 'null' : '${inner.runtimeType}: $inner';
      final stack = error.stackTrace.toString().split('\n').take(3).join(' | ');
      return 'DioException(type=${error.type}, status=$status, method=$method, uri=$uri, message=${error.message}, inner=$innerText, body=$body, stack=$stack)';
    }
    return error.toString();
  }
}
