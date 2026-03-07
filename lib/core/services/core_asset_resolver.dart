import 'dart:io';

class CoreAssetResolver {
  String resolveAssetName({required String version}) {
    final os = _targetOs();
    final arch = _targetArch();
    final ext = Platform.isWindows ? 'zip' : 'tar.gz';
    return 'CLIProxyAPI_${version}_${os}_$arch.$ext';
  }

  String executableName() {
    return Platform.isWindows ? 'cli-proxy-api.exe' : 'cli-proxy-api';
  }

  String _targetOs() {
    if (Platform.isWindows) {
      return 'windows';
    }
    if (Platform.isMacOS) {
      return 'darwin';
    }
    if (Platform.isLinux) {
      return 'linux';
    }
    throw UnsupportedError('Unsupported OS: ${Platform.operatingSystem}');
  }

  String _targetArch() {
    final abi = Platform.version.toLowerCase();
    if (abi.contains('arm64') || abi.contains('aarch64')) {
      return 'arm64';
    }
    return 'amd64';
  }
}
