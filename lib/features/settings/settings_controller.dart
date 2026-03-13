import 'dart:async';
import 'dart:convert';
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

enum _UsageSyncAction { upload, download, noop }

enum _StartupUsageImportAction { local, download }

class _LocalUsageState {
  const _LocalUsageState({
    required this.hash,
    required this.mtimeMs,
  });

  final String hash;
  final int mtimeMs;
}

class _UsageSyncMeta {
  const _UsageSyncMeta({
    required this.lastLocalHash,
    required this.lastLocalMtimeMs,
    required this.lastRemoteVersionId,
    required this.lastUploadAtMs,
    required this.updatedAt,
  });

  final String lastLocalHash;
  final int lastLocalMtimeMs;
  final String lastRemoteVersionId;
  final int lastUploadAtMs;
  final String updatedAt;

  factory _UsageSyncMeta.empty() {
    return const _UsageSyncMeta(
      lastLocalHash: '',
      lastLocalMtimeMs: 0,
      lastRemoteVersionId: '',
      lastUploadAtMs: 0,
      updatedAt: '',
    );
  }

  _UsageSyncMeta copyWith({
    String? lastLocalHash,
    int? lastLocalMtimeMs,
    String? lastRemoteVersionId,
    int? lastUploadAtMs,
    String? updatedAt,
  }) {
    return _UsageSyncMeta(
      lastLocalHash: lastLocalHash ?? this.lastLocalHash,
      lastLocalMtimeMs: lastLocalMtimeMs ?? this.lastLocalMtimeMs,
      lastRemoteVersionId: lastRemoteVersionId ?? this.lastRemoteVersionId,
      lastUploadAtMs: lastUploadAtMs ?? this.lastUploadAtMs,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'lastLocalHash': lastLocalHash,
      'lastLocalMtimeMs': lastLocalMtimeMs,
      'lastRemoteVersionId': lastRemoteVersionId,
      'lastUploadAtMs': lastUploadAtMs,
      'updatedAt': updatedAt,
    };
  }

  static _UsageSyncMeta? tryParse(String raw) {
    try {
      final jsonObj = jsonDecode(raw);
      if (jsonObj is! Map<String, dynamic>) {
        return null;
      }
      return _UsageSyncMeta(
        lastLocalHash: (jsonObj['lastLocalHash'] ?? '').toString(),
        lastLocalMtimeMs: (jsonObj['lastLocalMtimeMs'] is int)
            ? jsonObj['lastLocalMtimeMs'] as int
            : int.tryParse((jsonObj['lastLocalMtimeMs'] ?? '0').toString()) ??
                0,
        lastRemoteVersionId: (jsonObj['lastRemoteVersionId'] ?? '').toString(),
        lastUploadAtMs: (jsonObj['lastUploadAtMs'] is int)
            ? jsonObj['lastUploadAtMs'] as int
            : int.tryParse((jsonObj['lastUploadAtMs'] ?? '0').toString()) ?? 0,
        updatedAt: (jsonObj['updatedAt'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

class SettingsController extends ChangeNotifier {
  SettingsController();

  static const Duration _localUsageExportInterval = Duration(minutes: 1);
  static const Duration _usageUploadInterval = Duration(minutes: 3);
  static const Duration _syncOperationGuardDuration = Duration(seconds: 20);
  static const Duration _postCoreReadyUsageImportDelay = Duration(seconds: 10);
  static const String _defaultWebuiPassword = '123456';
  static const int webdavAutoBackupOnStartupOnly = -1;
  static const List<int> webdavAutoBackupIntervals = <int>[
    5,
    10,
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
  DateTime? _syncOperationGuardUntilUtc;
  Future<void> _usageSyncQueue = Future<void>.value();

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
    _setSyncOperationGuard();
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
      args: const ['--cpaclient-autostart'],
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
    Future<void>? startupUsageImport;
    if (startupReady) {
      lastStatus = '';
      startupUsageImport = _runUsageSyncTask('startup-import', () async {
        await _importLocalUsageAfterDelay(trigger: 'startup');
      });
    }
    if (startupUsageImport == null) {
      _restartLocalUsageExportTimer();
    } else {
      unawaited(
        startupUsageImport.then((_) {
          _restartLocalUsageExportTimer();
        }).catchError((Object e) async {
          await AppServices.log.error('Startup usage sync failed', e);
          _restartLocalUsageExportTimer();
        }),
      );
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
      unawaited(_runUsageSyncTick('timer-1m'));
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

  Future<void> _importLocalUsageAfterDelay({
    required String trigger,
    Duration delay = _postCoreReadyUsageImportDelay,
  }) async {
    await AppServices.log.info(
      'Local usage import delayed: trigger=$trigger wait=${delay.inSeconds}s',
    );
    await Future<void>.delayed(delay);
    if (trigger == 'startup') {
      await _importUsageOnStartupByFreshness(trigger: trigger);
      return;
    }
    await _importLocalUsageIfExists(trigger: trigger);
  }

  Future<T> _runUsageSyncTask<T>(
    String name,
    Future<T> Function() task,
  ) {
    final completer = Completer<T>();
    _usageSyncQueue = _usageSyncQueue.catchError((_) {}).then((_) async {
      await AppServices.log.info('Usage sync begin: $name');
      try {
        final result = await task();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        await AppServices.log.info('Usage sync end: $name');
      }
    });
    return completer.future;
  }

  Future<void> _runUsageSyncTick(String trigger) {
    return _runUsageSyncTask('usage-tick-$trigger', () async {
      await _exportLocalUsageSnapshot(trigger: trigger);
      if (_isSyncOperationGuardActive()) {
        await AppServices.log
            .info('Usage sync tick skipped: guard active trigger=$trigger');
        return;
      }
      final localState = await _readLocalUsageState();
      if (localState == null) {
        await AppServices.log.info(
            'Usage sync tick skipped: local usage missing trigger=$trigger');
        return;
      }
      final meta = await _readUsageSyncMeta();
      final remoteVersionId = await _resolveLatestRemoteUsageVersionId();
      final action = _decideUsageSyncAction(
        localState: localState,
        remoteVersionId: remoteVersionId,
        meta: meta,
      );
      await AppServices.log.info(
        'Usage sync tick decision: trigger=$trigger action=$action localHash=${localState.hash} localMtimeMs=${localState.mtimeMs} remoteVersion=$remoteVersionId lastHash=${meta.lastLocalHash} lastRemote=${meta.lastRemoteVersionId}',
      );

      switch (action) {
        case _UsageSyncAction.upload:
          if (!_canRunUsageUploadNow(meta.lastUploadAtMs)) {
            await AppServices.log.info(
                'Usage sync upload skipped: 3m interval guard trigger=$trigger');
            return;
          }
          final uploaded = await _runUsageOnlyUpload(trigger: trigger);
          if (!uploaded) {
            return;
          }
          final uploadedVersionId =
              await _resolveLatestRemoteUsageVersionId() ?? remoteVersionId;
          await _writeUsageSyncMeta(
            _UsageSyncMeta(
              lastLocalHash: localState.hash,
              lastLocalMtimeMs: localState.mtimeMs,
              lastRemoteVersionId: uploadedVersionId ?? '',
              lastUploadAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
              updatedAt: DateTime.now().toUtc().toIso8601String(),
            ),
          );
          return;
        case _UsageSyncAction.download:
          final targetVersion = remoteVersionId;
          if (targetVersion == null || targetVersion.isEmpty) {
            await AppServices.log.info(
                'Usage sync download skipped: remote version missing trigger=$trigger');
            return;
          }
          final restored = await _runUsageOnlyDownload(
            trigger: trigger,
            versionId: targetVersion,
          );
          if (!restored) {
            return;
          }
          final postDownloadLocal = await _readLocalUsageState();
          if (postDownloadLocal == null) {
            return;
          }
          await _writeUsageSyncMeta(
            _UsageSyncMeta(
              lastLocalHash: postDownloadLocal.hash,
              lastLocalMtimeMs: postDownloadLocal.mtimeMs,
              lastRemoteVersionId: targetVersion,
              lastUploadAtMs: meta.lastUploadAtMs,
              updatedAt: DateTime.now().toUtc().toIso8601String(),
            ),
          );
          return;
        case _UsageSyncAction.noop:
          await _writeUsageSyncMeta(
            meta.copyWith(
              lastLocalHash: localState.hash,
              lastLocalMtimeMs: localState.mtimeMs,
              lastRemoteVersionId: remoteVersionId ?? meta.lastRemoteVersionId,
              updatedAt: DateTime.now().toUtc().toIso8601String(),
            ),
          );
          return;
      }
    });
  }

  Future<void> _importUsageOnStartupByFreshness(
      {required String trigger}) async {
    final localState = await _readLocalUsageState();
    final remoteVersionId = await _resolveLatestRemoteUsageVersionId();
    final localMtimeMs = localState?.mtimeMs;
    final remoteTimeMs = _parseVersionIdMillis(remoteVersionId);
    final action = _decideStartupUsageImportAction(
      localMtimeMs: localMtimeMs,
      remoteVersionId: remoteVersionId,
    );

    await AppServices.log.info(
      'Startup usage import decision: trigger=$trigger localMtimeMs=$localMtimeMs remoteVersionId=$remoteVersionId remoteTimeMs=$remoteTimeMs action=$action',
    );

    if (action == _StartupUsageImportAction.download) {
      final targetVersion = remoteVersionId;
      if (targetVersion != null && targetVersion.isNotEmpty) {
        final restored = await _runUsageOnlyDownload(
          trigger: trigger,
          versionId: targetVersion,
        );
        if (restored) {
          await AppServices.log.info(
            'Startup usage import action completed: trigger=$trigger action=download',
          );
          return;
        }
      }
      await AppServices.log.info(
        'Startup usage import fallback: trigger=$trigger action=fallback-local',
      );
      await _importLocalUsageIfExists(trigger: '$trigger-fallback');
      return;
    }

    await AppServices.log.info(
      'Startup usage import action completed: trigger=$trigger action=local',
    );
    await _importLocalUsageIfExists(trigger: trigger);
  }

  _StartupUsageImportAction _decideStartupUsageImportAction({
    required int? localMtimeMs,
    required String? remoteVersionId,
  }) {
    final hasLocal = localMtimeMs != null;
    final hasRemote = remoteVersionId != null && remoteVersionId.isNotEmpty;

    if (!hasLocal) {
      return hasRemote
          ? _StartupUsageImportAction.download
          : _StartupUsageImportAction.local;
    }
    if (!hasRemote) {
      return _StartupUsageImportAction.local;
    }

    final remoteTimeMs = _parseVersionIdMillis(remoteVersionId);
    if (remoteTimeMs > localMtimeMs) {
      return _StartupUsageImportAction.download;
    }
    return _StartupUsageImportAction.local;
  }

  _UsageSyncAction _decideUsageSyncAction({
    required _LocalUsageState localState,
    required String? remoteVersionId,
    required _UsageSyncMeta meta,
  }) {
    final localChanged = localState.hash != meta.lastLocalHash;
    final remoteChanged = (remoteVersionId ?? '') != meta.lastRemoteVersionId;

    if (!localChanged && !remoteChanged) {
      return _UsageSyncAction.noop;
    }
    if (localChanged && !remoteChanged) {
      return _UsageSyncAction.upload;
    }
    if (!localChanged && remoteChanged) {
      return _UsageSyncAction.download;
    }

    final localTime = localState.mtimeMs;
    final remoteTime = _parseVersionIdMillis(remoteVersionId);
    if (localTime >= remoteTime) {
      return _UsageSyncAction.upload;
    }
    return _UsageSyncAction.download;
  }

  int _parseVersionIdMillis(String? versionId) {
    if (versionId == null || versionId.isEmpty) {
      return 0;
    }
    final parsed = AppServices.webdav.parseBackupVersionTime(versionId);
    if (parsed == null) {
      return 0;
    }
    return parsed.millisecondsSinceEpoch;
  }

  Future<bool> _runUsageOnlyUpload({required String trigger}) async {
    final url = settings.webdavUrl.trim();
    if (url.isEmpty) {
      await AppServices.log
          .info('Usage sync upload skipped: empty WebDAV url trigger=$trigger');
      return false;
    }
    final message = await AppServices.webdav.backupUsageOnly(
      url: url,
      username: settings.webdavUsername,
      password: settings.webdavPassword,
      settingsWebuiSecretKey: settings.webuiSecretKey,
      defaultWebuiPassword: _defaultWebuiPassword,
      isCoreRunning: AppServices.process.isRunning,
    );
    return message.contains('已备份 usage 压缩包版本');
  }

  Future<bool> _runUsageOnlyDownload({
    required String trigger,
    required String versionId,
  }) async {
    final url = settings.webdavUrl.trim();
    if (url.isEmpty) {
      await AppServices.log.info(
          'Usage sync download skipped: empty WebDAV url trigger=$trigger');
      return false;
    }
    return AppServices.webdav.restoreUsage(
      url: url,
      username: settings.webdavUsername,
      password: settings.webdavPassword,
      versionId: versionId,
      settingsWebuiSecretKey: settings.webuiSecretKey,
      defaultWebuiPassword: _defaultWebuiPassword,
    );
  }

  Future<String?> _resolveLatestRemoteUsageVersionId() async {
    final url = settings.webdavUrl.trim();
    if (url.isEmpty) {
      return null;
    }
    try {
      return await AppServices.webdav.latestUsageVersionId(
        url: url,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
      );
    } catch (e) {
      await AppServices.log.error('Load latest usage version failed', e);
      return null;
    }
  }

  Future<_LocalUsageState?> _readLocalUsageState() async {
    final usageFile = await AppServices.paths.usageJsonFile();
    if (!usageFile.existsSync()) {
      return null;
    }
    final bytes = await usageFile.readAsBytes();
    final hash = _hashUsageBytes(bytes);
    final stat = await usageFile.stat();
    return _LocalUsageState(
      hash: hash,
      mtimeMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  String _hashUsageBytes(List<int> bytes) {
    var hash = 2166136261;
    for (final value in bytes) {
      hash ^= value;
      hash = (hash * 16777619) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<_UsageSyncMeta> _readUsageSyncMeta() async {
    final metaFile = await AppServices.paths.usageSyncMetaFile();
    if (!metaFile.existsSync()) {
      return _UsageSyncMeta.empty();
    }
    try {
      final raw = await metaFile.readAsString();
      final parsed = _UsageSyncMeta.tryParse(raw);
      if (parsed == null) {
        await AppServices.log
            .info('Usage sync meta corrupted, fallback to empty state');
        return _UsageSyncMeta.empty();
      }
      return parsed;
    } catch (e) {
      await AppServices.log.error('Read usage sync meta failed', e);
      return _UsageSyncMeta.empty();
    }
  }

  Future<void> _writeUsageSyncMeta(_UsageSyncMeta value) async {
    final metaFile = await AppServices.paths.usageSyncMetaFile();
    await metaFile.writeAsString(
      jsonEncode(value.toJson()),
      flush: true,
    );
  }

  @visibleForTesting
  String decideStartupUsageImportActionForTest({
    required int? localMtimeMs,
    required String? remoteVersionId,
  }) {
    return _decideStartupUsageImportAction(
      localMtimeMs: localMtimeMs,
      remoteVersionId: remoteVersionId,
    ).name;
  }

  @visibleForTesting
  String decideUsageSyncActionForTest({
    required String localHash,
    required int localMtimeMs,
    required String? remoteVersionId,
    required String lastLocalHash,
    required int lastLocalMtimeMs,
    required String lastRemoteVersionId,
  }) {
    final action = _decideUsageSyncAction(
      localState: _LocalUsageState(hash: localHash, mtimeMs: localMtimeMs),
      remoteVersionId: remoteVersionId,
      meta: _UsageSyncMeta(
        lastLocalHash: lastLocalHash,
        lastLocalMtimeMs: lastLocalMtimeMs,
        lastRemoteVersionId: lastRemoteVersionId,
        lastUploadAtMs: 0,
        updatedAt: '',
      ),
    );
    return action.name;
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
    final guard = _syncOperationGuardMessage();
    if (guard != null) {
      return guard;
    }
    return _performWebdavBackup(isAuto: false);
  }

  Future<String> backupUsageToWebdav() async {
    final guard = _syncOperationGuardMessage();
    if (guard != null) {
      return guard;
    }
    final url = settings.webdavUrl.trim();
    if (url.isEmpty) {
      const msg = '请先填写 WebDAV 地址';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
    _setWebdavStatus(WebdavStatusLevel.running, '正在备份 usage...');
    try {
      final msg = await AppServices.webdav.backupUsageOnly(
        url: url,
        username: settings.webdavUsername,
        password: settings.webdavPassword,
        settingsWebuiSecretKey: settings.webuiSecretKey,
        defaultWebuiPassword: _defaultWebuiPassword,
        isCoreRunning: AppServices.process.isRunning,
      );
      _setWebdavStatus(WebdavStatusLevel.success, msg);
      return msg;
    } catch (e) {
      final logPath = await AppServices.log.logFilePath();
      final msg = 'WebDAV usage 备份失败: $e\n日志: $logPath';
      _setWebdavStatus(WebdavStatusLevel.failure, msg);
      return msg;
    }
  }

  Future<String> _performWebdavBackup({required bool isAuto}) async {
    final guard = _syncOperationGuardMessage();
    if (guard != null) {
      await AppServices.log
          .info('WebDAV backup skipped: guard active isAuto=$isAuto');
      return guard;
    }
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
      if (!isAuto) {
        _setWebdavStatus(WebdavStatusLevel.failure, msg);
      }
      return msg;
    }
  }

  Future<String> restoreConfigFromWebdav({required String versionId}) async {
    final guard = _syncOperationGuardMessage();
    if (guard != null) {
      return guard;
    }
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
    return AppServices.webdav.formatDioError(error);
  }

  void _setSyncOperationGuard() {
    _syncOperationGuardUntilUtc =
        DateTime.now().toUtc().add(_syncOperationGuardDuration);
  }

  bool _isSyncOperationGuardActive() {
    final until = _syncOperationGuardUntilUtc;
    if (until == null) {
      return false;
    }
    final now = DateTime.now().toUtc();
    if (!now.isBefore(until)) {
      _syncOperationGuardUntilUtc = null;
      return false;
    }
    return true;
  }

  String? _syncOperationGuardMessage() {
    final until = _syncOperationGuardUntilUtc;
    if (until == null) {
      return null;
    }
    final now = DateTime.now().toUtc();
    if (!now.isBefore(until)) {
      _syncOperationGuardUntilUtc = null;
      return null;
    }
    final remain = until.difference(now).inSeconds;
    return '核心刚启动/重启，请 ${remain}s 后再执行同步、备份或还原';
  }

  bool _canRunUsageUploadNow(int lastUploadAtMs) {
    if (lastUploadAtMs <= 0) {
      return true;
    }
    final elapsedMs =
        DateTime.now().toUtc().millisecondsSinceEpoch - lastUploadAtMs;
    return elapsedMs >= _usageUploadInterval.inMilliseconds;
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
      await _runUsageSyncTask('core-update', () async {
        await _exportLocalUsageSnapshot(trigger: 'core-update-pre');
        currentPort = await AppServices.coreControl.updateCore(
          version: settings.coreVersion,
          githubToken: settings.githubToken,
        );
        _setSyncOperationGuard();
        notifyListeners();
        await _importLocalUsageAfterDelay(trigger: 'core-update');
      });
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
      await _runUsageSyncTask('manual-restart', () async {
        await _exportLocalUsageSnapshot(trigger: 'manual-restart-pre');
        currentPort = await AppServices.coreControl.restartCore();
        _setSyncOperationGuard();
        notifyListeners();
        await _importLocalUsageAfterDelay(trigger: 'manual-restart');
      });
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

  Future<String> saveWindowCloseAction(String action) async {
    final normalized = AppSettings.normalizeWindowCloseAction(action);
    settings = settings.copyWith(windowCloseAction: normalized);
    await AppServices.settings.save(settings);
    notifyListeners();
    return normalized == AppSettings.windowCloseActionExitApp
        ? '关闭窗口时将直接退出应用'
        : '关闭窗口时将最小化到托盘';
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
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
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
