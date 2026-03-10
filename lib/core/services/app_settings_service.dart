import 'dart:convert';

import 'package:cpaclient/core/models/app_settings.dart';
import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:cpaclient/core/services/secure_key_store_service.dart';
import 'package:cpaclient/core/services/settings_crypto_service.dart';

class AppSettingsService {
  AppSettingsService(
    this._paths, {
    SettingsCryptoService? crypto,
  }) : _crypto = crypto ?? SettingsCryptoService();

  static const int _schemaVersion = 3;
  static const String _keyId = 'app_settings_key_v1';

  final SandboxPathService _paths;
  final SettingsCryptoService _crypto;

  Future<AppSettings> load() async {
    final file = await _paths.settingsFile();
    if (!file.existsSync()) {
      final defaults = AppSettings.defaults();
      await save(defaults);
      return defaults;
    }

    final text = await file.readAsString();
    final map = jsonDecode(text) as Map<String, dynamic>;

    if (_isEncryptedSchema(map)) {
      return _loadEncrypted(map);
    }

    final legacy = AppSettings.fromJson(map);
    if (_containsLegacySensitiveFields(map)) {
      await save(legacy);
    }
    return legacy;
  }

  Future<void> save(AppSettings settings) async {
    final file = await _paths.settingsFile();
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }

    final encrypted = await _crypto.encryptJson(
      data: {
        'githubToken': settings.githubToken,
        'webdavUrl': settings.webdavUrl,
        'webdavUsername': settings.webdavUsername,
        'webdavPassword': settings.webdavPassword,
        'webuiSecretKey': settings.webuiSecretKey,
      },
    );

    final payload = <String, dynamic>{
      'schemaVersion': _schemaVersion,
      'coreVersion': settings.coreVersion,
      'themeMode': settings.themeMode,
      'keepGithubToken': settings.keepGithubToken,
      'webdavAutoBackupEnabled': settings.webdavAutoBackupEnabled,
      'webdavAutoBackupIntervalMinutes':
          settings.webdavAutoBackupIntervalMinutes,
      'windowCloseAction': settings.windowCloseAction,
      'secrets': encrypted,
    };

    await file.writeAsString(jsonEncode(payload));
  }

  Future<AppSettings> _loadEncrypted(Map<String, dynamic> map) async {
    final coreVersion =
        (map['coreVersion'] as String?) ?? AppSettings.defaults().coreVersion;
    final themeMode =
        (map['themeMode'] as String?) ?? AppSettings.defaults().themeMode;
    final windowCloseAction = AppSettings.normalizeWindowCloseAction(
      map['windowCloseAction'] as String?,
    );
    final secrets = map['secrets'];
    if (secrets is! Map<String, dynamic>) {
      return AppSettings.defaults().copyWith(
        coreVersion: coreVersion,
        themeMode: themeMode,
        windowCloseAction: windowCloseAction,
      );
    }

    try {
      final decrypted = await _crypto.decryptJson(envelope: secrets);
      return AppSettings(
        coreVersion: coreVersion,
        themeMode: themeMode,
        githubToken: (decrypted['githubToken'] as String?) ?? '',
        webdavUrl: (decrypted['webdavUrl'] as String?) ?? '',
        webdavUsername: (decrypted['webdavUsername'] as String?) ?? '',
        webdavPassword: (decrypted['webdavPassword'] as String?) ?? '',
        webuiSecretKey: (decrypted['webuiSecretKey'] as String?) ?? '',
        keepGithubToken: (map['keepGithubToken'] as bool?) ?? true,
        webdavAutoBackupEnabled:
            (map['webdavAutoBackupEnabled'] as bool?) ?? false,
        webdavAutoBackupIntervalMinutes:
            (map['webdavAutoBackupIntervalMinutes'] as int?) ?? 60,
        windowCloseAction: windowCloseAction,
      );
    } catch (_) {}

    try {
      final keyRef = (secrets['keyRef'] as String?) ?? _keyId;
      final key =
          await SecureKeyStoreService(paths: _paths).readOrCreateKey(keyRef);
      final decrypted =
          await _crypto.decryptLegacyAes(envelope: secrets, key: key);
      final migrated = AppSettings(
        coreVersion: coreVersion,
        themeMode: themeMode,
        githubToken: (decrypted['githubToken'] as String?) ?? '',
        webdavUrl: (decrypted['webdavUrl'] as String?) ?? '',
        webdavUsername: (decrypted['webdavUsername'] as String?) ?? '',
        webdavPassword: (decrypted['webdavPassword'] as String?) ?? '',
        webuiSecretKey: (decrypted['webuiSecretKey'] as String?) ?? '',
        keepGithubToken: (map['keepGithubToken'] as bool?) ?? true,
        webdavAutoBackupEnabled:
            (map['webdavAutoBackupEnabled'] as bool?) ?? false,
        webdavAutoBackupIntervalMinutes:
            (map['webdavAutoBackupIntervalMinutes'] as int?) ?? 60,
        windowCloseAction: windowCloseAction,
      );
      await save(migrated);
      return migrated;
    } catch (_) {
      return AppSettings.defaults().copyWith(
        coreVersion: coreVersion,
        themeMode: themeMode,
        windowCloseAction: windowCloseAction,
      );
    }
  }

  bool _isEncryptedSchema(Map<String, dynamic> map) {
    final version = map['schemaVersion'];
    return (version == 2 || version == _schemaVersion) &&
        map['secrets'] is Map<String, dynamic>;
  }

  bool _containsLegacySensitiveFields(Map<String, dynamic> map) {
    return map.containsKey('githubToken') ||
        map.containsKey('webdavUrl') ||
        map.containsKey('webdavUsername') ||
        map.containsKey('webdavPassword') ||
        map.containsKey('webuiSecretKey');
  }
}
