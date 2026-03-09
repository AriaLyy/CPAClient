import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SettingsCryptoService {
  SettingsCryptoService({AesGcm? aesGcm})
      : _aesGcm = aesGcm ?? AesGcm.with256bits();

  final AesGcm _aesGcm;
  static const List<int> _simpleKeyBytes = <int>[
    0x43,
    0x50,
    0x41,
    0x5f,
    0x43,
    0x4c,
    0x49,
    0x45,
    0x4e,
    0x54,
    0x5f,
    0x53,
    0x45,
    0x54,
    0x54,
    0x49,
    0x4e,
    0x47,
    0x53,
    0x5f,
    0x4b,
    0x45,
    0x59,
    0x5f,
    0x56,
    0x31,
    0x5f,
    0x58,
    0x4f,
    0x52,
    0x21,
    0x3f,
  ];

  Future<Map<String, dynamic>> encryptJson({
    required Map<String, dynamic> data,
  }) async {
    final plainBytes = utf8.encode(jsonEncode(data));
    final cipherBytes = _xor(plainBytes);

    return {
      'encVersion': 2,
      'alg': 'XOR-BASE64',
      'ciphertextB64': base64Encode(cipherBytes),
    };
  }

  Future<Map<String, dynamic>> decryptJson({
    required Map<String, dynamic> envelope,
  }) async {
    final alg = (envelope['alg'] as String?) ?? '';
    if (alg != 'XOR-BASE64') {
      throw const FormatException('Unsupported encryption algorithm');
    }

    final cipherBytes =
        base64Decode((envelope['ciphertextB64'] as String?) ?? '');
    final clearBytes = _xor(cipherBytes);
    final decoded = jsonDecode(utf8.decode(clearBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid decrypted payload');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> decryptLegacyAes({
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

  Uint8List _xor(List<int> bytes) {
    return Uint8List.fromList(
      List<int>.generate(
        bytes.length,
        (index) =>
            bytes[index] ^ _simpleKeyBytes[index % _simpleKeyBytes.length],
      ),
    );
  }
}
