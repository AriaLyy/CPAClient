import 'dart:io';

import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:cpaclient/core/services/app_settings_service.dart';
import 'package:cpaclient/core/services/archive_extractor_service.dart';
import 'package:cpaclient/core/services/core_asset_resolver.dart';
import 'package:cpaclient/core/services/core_downloader_service.dart';
import 'package:cpaclient/core/services/core_process_manager.dart';
import 'package:cpaclient/core/services/github_release_service.dart';
import 'package:cpaclient/core/services/sandbox_config_service.dart';
import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:path/path.dart' as p;

class StartupService {
  StartupService({
    required SandboxPathService paths,
    required AppSettingsService settings,
    required SandboxConfigService sandboxConfig,
    required CoreAssetResolver assetResolver,
    required GithubReleaseService githubRelease,
    required CoreDownloaderService downloader,
    required ArchiveExtractorService extractor,
    required CoreProcessManager process,
    required AppLogService log,
  })  : _paths = paths,
        _settings = settings,
        _sandboxConfig = sandboxConfig,
        _assetResolver = assetResolver,
        _githubRelease = githubRelease,
        _downloader = downloader,
        _extractor = extractor,
        _process = process,
        _log = log;

  final SandboxPathService _paths;
  final AppSettingsService _settings;
  final SandboxConfigService _sandboxConfig;
  final CoreAssetResolver _assetResolver;
  final GithubReleaseService _githubRelease;
  final CoreDownloaderService _downloader;
  final ArchiveExtractorService _extractor;
  final CoreProcessManager _process;
  final AppLogService _log;

  Future<void> ensureReady() async {
    await _log.info('Startup ensureReady begin');
    await _sandboxConfig.ensureSandboxConfig();
    final appSettings = await _settings.load();
    await _log.info('Startup settings loaded: coreVersion=${appSettings.coreVersion}');
    await ensureCoreBinary(
      version: appSettings.coreVersion,
      githubToken: appSettings.githubToken,
    );
    await _process.start();
    await _log.info('Startup ensureReady completed');
  }

  Future<void> ensureCoreBinary({
    required String version,
    required String githubToken,
    bool force = false,
  }) async {
    final executable = File(await _paths.coreExecutablePath());
    if (executable.existsSync() && !force) {
      await _log.info('Core binary exists, skip download: ${executable.path}');
      return;
    }

    if (githubToken.trim().isEmpty) {
      await _log.error('Core binary prepare blocked: github token is empty');
      throw Exception('请先在设置页填写 GitHub Token');
    }

    await _log.info('Core binary prepare: version=$version force=$force');
    final assetName = _assetResolver.resolveAssetName(version: version);
    await _log.info('Core asset resolved: $assetName');
    final asset = await _githubRelease.findAssetByName(
      assetName,
      githubToken: githubToken,
    );

    final tmpDir = await _paths.tmpDir();
    final archiveFile = File(p.join(tmpDir.path, asset.name));
    await _log.info('Core archive target: ${archiveFile.path}');
    await _downloader.downloadToFile(url: asset.downloadUrl, target: archiveFile);

    final binDir = await _paths.binDir();
    if (force && binDir.existsSync()) {
      await _log.info('Core force update: cleaning ${binDir.path}');
      for (final entity in binDir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          entity.deleteSync();
        }
      }
    }

    await _extractor.extractToDirectory(archiveFile: archiveFile, outputDir: binDir);
    await _extractor.ensureExecutablePresent(
      binDir: binDir,
      executableName: _assetResolver.executableName(),
    );
    await _log.info('Core binary prepared at ${binDir.path}');
  }

  Future<void> updateCore({
    required String version,
    required String githubToken,
  }) async {
    await _log.info('Core update begin: version=$version');
    await _process.stop();
    await ensureCoreBinary(
      version: version,
      githubToken: githubToken,
      force: true,
    );
    await _process.start();
    await _log.info('Core update completed');
  }

  Future<void> shutdown() async {
    await _log.info('Startup shutdown begin');
    await _process.stop();
    await _log.info('Startup shutdown completed');
  }
}
