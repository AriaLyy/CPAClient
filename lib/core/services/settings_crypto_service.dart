import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SettingsCryptoService {
  SettingsCryptoService({AesGcm? aesGcm})
      : _aesGcm = aesGcm ?? AesGcm.with256bits();

  final AesGcm _aesGcm;

  Future<Map<String, dynamic>> encryptJson({
    required Map<String, dynamic> data,
    required SecretKey key,
  }) async {
    final nonce = _aesGcm.newNonce();
    final plainBytes = utf8.encode(jsonEncode(data));
    final box = await _aesGcm.encrypt(plainBytes, secretKey: key, nonce: nonce);
    final combined =
        Uint8List.fromList(<int>[...box.cipherText, ...box.mac.bytes]);

    return {
      'encVersion': 1,
      'alg': 'AES-256-GCM',
      'nonceB64': base64Encode(box.nonce),
      'ciphertextB64': base64Encode(combined),
    };
  }

  Future<Map<String, dynamic>> decryptJson({
    required Map<String, dynamic> envelope,
    required SecretKey key,
  }) async {
    final nonce = base64Decode((envelope['nonceB64'] as String?) ?? '');
    final combined = base64Decode((envelope['ciphertextB64'] as String?) ?? '');
    if (combined.length < 16) {
      throw const FormatException('Invalid encrypted payload');
    }

    final cipherText = combined.sublist(0, combined.length - 16);
    final macBytes = combined.sublist(combined.length - 16);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
    final clearBytes = await _aesGcm.decrypt(box, secretKey: key);
    final decoded = jsonDecode(utf8.decode(clearBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid decrypted payload');
    }
    return decoded;
  }
}
