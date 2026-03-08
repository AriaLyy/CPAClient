import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SettingsKeyStore {
  Future<SecretKey> readOrCreateKey(String keyId);
}

class SecureKeyStoreService implements SettingsKeyStore {
  SecureKeyStoreService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<SecretKey> readOrCreateKey(String keyId) async {
    final existing = await _storage.read(key: keyId);
    if (existing != null && existing.isNotEmpty) {
      return SecretKey(base64Decode(existing));
    }

    final random = Random.secure();
    final keyBytes =
        Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
    await _storage.write(key: keyId, value: base64Encode(keyBytes));
    return SecretKey(keyBytes);
  }
}
