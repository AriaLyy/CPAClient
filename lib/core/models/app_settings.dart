class AppSettings {
  const AppSettings({
    required this.coreVersion,
    required this.githubToken,
    required this.themeMode,
    required this.webdavUrl,
    required this.webdavUsername,
    required this.webdavPassword,
    required this.webuiSecretKey,
    required this.keepGithubToken,
    required this.webdavAutoBackupEnabled,
    required this.webdavAutoBackupIntervalMinutes,
  });

  factory AppSettings.defaults() {
    return const AppSettings(
      coreVersion: '6.8.47',
      githubToken: '',
      themeMode: 'system',
      webdavUrl: 'https://dav.jianguoyun.com/dav',
      webdavUsername: '',
      webdavPassword: '',
      webuiSecretKey: '',
      keepGithubToken: true,
      webdavAutoBackupEnabled: false,
      webdavAutoBackupIntervalMinutes: 60,
    );
  }

  final String coreVersion;
  final String githubToken;
  final String themeMode;
  final String webdavUrl;
  final String webdavUsername;
  final String webdavPassword;
  final String webuiSecretKey;
  final bool keepGithubToken;
  final bool webdavAutoBackupEnabled;
  final int webdavAutoBackupIntervalMinutes;

  AppSettings copyWith({
    String? coreVersion,
    String? githubToken,
    String? themeMode,
    String? webdavUrl,
    String? webdavUsername,
    String? webdavPassword,
    String? webuiSecretKey,
    bool? keepGithubToken,
    bool? webdavAutoBackupEnabled,
    int? webdavAutoBackupIntervalMinutes,
  }) {
    return AppSettings(
      coreVersion: coreVersion ?? this.coreVersion,
      githubToken: githubToken ?? this.githubToken,
      themeMode: themeMode ?? this.themeMode,
      webdavUrl: webdavUrl ?? this.webdavUrl,
      webdavUsername: webdavUsername ?? this.webdavUsername,
      webdavPassword: webdavPassword ?? this.webdavPassword,
      webuiSecretKey: webuiSecretKey ?? this.webuiSecretKey,
      keepGithubToken: keepGithubToken ?? this.keepGithubToken,
      webdavAutoBackupEnabled: webdavAutoBackupEnabled ?? this.webdavAutoBackupEnabled,
      webdavAutoBackupIntervalMinutes:
          webdavAutoBackupIntervalMinutes ?? this.webdavAutoBackupIntervalMinutes,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'coreVersion': coreVersion,
      'githubToken': githubToken,
      'themeMode': themeMode,
      'webdavUrl': webdavUrl,
      'webdavUsername': webdavUsername,
      'webdavPassword': webdavPassword,
      'webuiSecretKey': webuiSecretKey,
      'keepGithubToken': keepGithubToken,
      'webdavAutoBackupEnabled': webdavAutoBackupEnabled,
      'webdavAutoBackupIntervalMinutes': webdavAutoBackupIntervalMinutes,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      coreVersion: (json['coreVersion'] as String?) ?? '6.8.47',
      githubToken: (json['githubToken'] as String?) ?? '',
      themeMode: (json['themeMode'] as String?) ?? 'system',
      webdavUrl: (json['webdavUrl'] as String?) ?? 'https://dav.jianguoyun.com/dav',
      webdavUsername: (json['webdavUsername'] as String?) ?? '',
      webdavPassword: (json['webdavPassword'] as String?) ?? '',
      webuiSecretKey: (json['webuiSecretKey'] as String?) ?? '',
      keepGithubToken: (json['keepGithubToken'] as bool?) ?? true,
      webdavAutoBackupEnabled: (json['webdavAutoBackupEnabled'] as bool?) ?? false,
      webdavAutoBackupIntervalMinutes: (json['webdavAutoBackupIntervalMinutes'] as int?) ?? 60,
    );
  }
}
