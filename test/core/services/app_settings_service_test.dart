import 'dart:convert';
import 'dart:io';

import 'package:cpaclient/core/models/app_settings.dart';
import 'package:cpaclient/core/services/app_settings_service.dart';
import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:cpaclient/core/services/settings_crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSandboxPathService extends SandboxPathService {
  _FakeSandboxPathService(this._file);

  final File _file;

  @override
  Future<File> settingsFile() async => _file;
}

void main() {
  group('AppSettingsService', () {
    late Directory tempDir;
    late File settingsFile;
    late AppSettingsService service;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('cpaclient-settings-test-');
      settingsFile = File('${tempDir.path}/app_settings.json');
      service = AppSettingsService(
        _FakeSandboxPathService(settingsFile),
        crypto: SettingsCryptoService(),
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('save writes encrypted secrets without plaintext', () async {
      final settings = AppSettings.defaults().copyWith(
        coreVersion: '6.8.47',
        themeMode: 'dark',
        githubToken: 'ghp_secret_123',
        webdavUrl: 'https://dav.example.com/CpaClient',
        webdavUsername: 'alice',
        webdavPassword: 'pwd-123',
      );

      await service.save(settings);

      final raw = await settingsFile.readAsString();
      expect(raw.contains('ghp_secret_123'), isFalse);
      expect(raw.contains('https://dav.example.com/CpaClient'), isFalse);
      expect(raw.contains('alice'), isFalse);
      expect(raw.contains('pwd-123'), isFalse);

      final map = jsonDecode(raw) as Map<String, dynamic>;
      expect(map['schemaVersion'], 3);
      expect(map['coreVersion'], '6.8.47');
      expect(map['themeMode'], 'dark');
      expect(map['secrets'], isA<Map<String, dynamic>>());
    });

    test('load migrates legacy plaintext to encrypted schema', () async {
      final legacy = <String, dynamic>{
        'coreVersion': '6.8.47',
        'themeMode': 'system',
        'githubToken': 'legacy-token',
        'webdavUrl': 'https://dav.legacy.com/CpaClient',
        'webdavUsername': 'legacy-user',
        'webdavPassword': 'legacy-pass',
      };
      await settingsFile.writeAsString(jsonEncode(legacy));

      final loaded = await service.load();
      expect(loaded.githubToken, 'legacy-token');
      expect(loaded.webdavUrl, 'https://dav.legacy.com/CpaClient');
      expect(loaded.webdavUsername, 'legacy-user');
      expect(loaded.webdavPassword, 'legacy-pass');

      final migratedRaw = await settingsFile.readAsString();
      final migrated = jsonDecode(migratedRaw) as Map<String, dynamic>;
      expect(migrated['schemaVersion'], 3);
      expect(migrated.containsKey('githubToken'), isFalse);
      expect(migrated.containsKey('webdavUrl'), isFalse);
      expect(migrated.containsKey('webdavUsername'), isFalse);
      expect(migrated.containsKey('webdavPassword'), isFalse);
      expect(migratedRaw.contains('legacy-token'), isFalse);
      expect(migratedRaw.contains('legacy-pass'), isFalse);
    });

    test('load decrypts encrypted schema and restores values', () async {
      final saved = AppSettings.defaults().copyWith(
        githubToken: 'token-xyz',
        webdavUrl: 'https://dav.test.com/CpaClient',
        webdavUsername: 'bob',
        webdavPassword: 'secret-pass',
      );
      await service.save(saved);

      final loaded = await service.load();
      expect(loaded.githubToken, 'token-xyz');
      expect(loaded.webdavUrl, 'https://dav.test.com/CpaClient');
      expect(loaded.webdavUsername, 'bob');
      expect(loaded.webdavPassword, 'secret-pass');
    });
  });
}
