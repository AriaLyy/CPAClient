import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

abstract class SettingsKeyStore {
  Future<SecretKey> readOrCreateKey(String keyId);
}

class SecureKeyStoreService implements SettingsKeyStore {
  SecureKeyStoreService({SandboxPathService? paths})
      : _paths = paths ?? SandboxPathService();

  static const String _keyFileName = '.settings_keys.json';

  final SandboxPathService _paths;

  @override
  Future<SecretKey> readOrCreateKey(String keyId) async {
    final store = await _readStore();
    final existing = store[keyId];
    if (existing != null && existing.isNotEmpty) {
      try {
        return SecretKey(base64Decode(existing));
      } on FormatException {
        // Continue to regenerate the key if stored data is corrupted.
      }
    }

    final random = Random.secure();
    final keyBytes =
        Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
    store[keyId] = base64Encode(keyBytes);
    await _writeStore(store);
    return SecretKey(keyBytes);
  }

  Future<File> _keyFile() async {
    final root = await _paths.sandboxRoot();
    return File(p.join(root.path, _keyFileName));
  }

  Future<Map<String, String>> _readStore() async {
    final file = await _keyFile();
    if (!file.existsSync()) {
      return <String, String>{};
    }

    final text = await file.readAsString();
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      return <String, String>{};
    }

    final result = <String, String>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is String) {
        result[entry.key] = value;
      }
    }
    return result;
  }

  Future<void> _writeStore(Map<String, String> store) async {
    final file = await _keyFile();
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsString(jsonEncode(store));
  }
}
