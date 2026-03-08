import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:cpaclient/core/services/app_settings_service.dart';
import 'package:cpaclient/core/services/archive_extractor_service.dart';
import 'package:cpaclient/core/services/core_asset_resolver.dart';
import 'package:cpaclient/core/services/core_downloader_service.dart';
import 'package:cpaclient/core/services/core_process_manager.dart';
import 'package:cpaclient/core/services/github_release_service.dart';
import 'package:cpaclient/core/services/sandbox_config_service.dart';
import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:cpaclient/core/services/secure_key_store_service.dart';
import 'package:cpaclient/core/services/settings_crypto_service.dart';
import 'package:cpaclient/core/services/startup_service.dart';

class AppServices {
  AppServices._();

  static final SandboxPathService paths = SandboxPathService();
  static final AppLogService log = AppLogService(paths);
  static final SecureKeyStoreService secureKeyStore = SecureKeyStoreService();
  static final SettingsCryptoService settingsCrypto = SettingsCryptoService();
  static final AppSettingsService settings = AppSettingsService(
    paths,
    keyStore: secureKeyStore,
    crypto: settingsCrypto,
  );
  static final SandboxConfigService sandboxConfig = SandboxConfigService(paths);
  static final CoreAssetResolver assetResolver = CoreAssetResolver();
  static final GithubReleaseService githubRelease = GithubReleaseService(log);
  static final CoreDownloaderService downloader = CoreDownloaderService(log);
  static final ArchiveExtractorService extractor = ArchiveExtractorService();
  static final CoreProcessManager process = CoreProcessManager(paths, log);

  static final StartupService startup = StartupService(
    paths: paths,
    settings: settings,
    sandboxConfig: sandboxConfig,
    assetResolver: assetResolver,
    githubRelease: githubRelease,
    downloader: downloader,
    extractor: extractor,
    process: process,
    log: log,
  );
}
