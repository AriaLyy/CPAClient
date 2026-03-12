class CoreDefaults {
  CoreDefaults._();

  static const String defaultVersion = '6.8.47';
  static const String releaseApi =
      'https://api.github.com/repos/router-for-me/CLIProxyAPI/releases';
  static const String aboutUrl = 'https://github.com/AriaLyy/CPAClient';
  static const String githubTokenUrl =
      'https://github.com/settings/personal-access-tokens/new';

  static const String sandboxDirName = 'sandbox';
  static const String binDirName = 'bin';
  static const String configDirName = 'config';
  static const String tmpDirName = 'tmp';

  static const String sandboxConfigFileName = 'config.yaml';
  static const String sandboxSettingsName = 'app_settings.json';
  static const String sandboxLogFileName = 'app.log';

  static const String defaultAuthDir = '~/.cli-proxy-api';
  static const String webdavAuthJsonDirName = 'auth-json';
  static const String webdavAuthJsonIndexName = 'index.json';
  static const String webdavBackupVersionsDirName = 'backups';
  static const String webdavUsageSyncDirName = 'sync';
  static const String webdavBackupArchiveName = 'backup.zip';
  static const String webdavUsageArchiveName = 'usage.zip';
  static const int webdavBackupMaxVersions = 20;
  static const int webdavUsageSyncMaxVersions = 100;
}
