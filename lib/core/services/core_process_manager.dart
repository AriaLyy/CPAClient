import 'dart:async';
import 'dart:io';

import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:cpaclient/core/services/sandbox_path_service.dart';
import 'package:path/path.dart' as p;

class CoreProcessManager {
  CoreProcessManager(this._paths, this._log);

  final SandboxPathService _paths;
  final AppLogService _log;
  Process? _process;

  bool get isRunning => _process != null;

  Future<void> start() async {
    final executable = await _paths.coreExecutablePath();
    final config = await _paths.sandboxConfigFile();

    if (_process != null) {
      await _log.info('Core process start requested while tracked process exists, stopping first');
      await stop();
    }

    await _killStaleCoreProcesses(executablePath: executable);

    if (!File(executable).existsSync()) {
      await _log.error('Core executable missing: $executable');
      throw Exception('Core executable not found: $executable');
    }
    await _log.info('Core process start: exec=$executable config=${config.path}');
    _process = await Process.start(
      executable,
      ['--config', config.path],
      runInShell: false,
    );
    unawaited(_process!.stdout.drain<void>());
    unawaited(_process!.stderr.drain<void>());
    _process!.exitCode.whenComplete(() async {
      await _log.info('Core process exited');
      _process = null;
    });
    await _log.info('Core process started');
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null) {
      await _log.info('Core process stop skipped: not running');
      return;
    }
    await _log.info('Core process stopping');
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (e) {
      await _log.error('Core process stop timeout/failure', e);
    }
    _process = null;
    await _log.info('Core process stopped');
  }

  Future<void> _killStaleCoreProcesses({required String executablePath}) async {
    final executableName = p.basename(executablePath);
    try {
      if (Platform.isWindows) {
        await _log.info('Core stale cleanup: taskkill /IM $executableName');
        await Process.run('taskkill', <String>['/F', '/IM', executableName, '/T']);
      } else {
        await _log.info('Core stale cleanup: pkill -f $executablePath');
        await Process.run('pkill', <String>['-f', executablePath]);
      }
    } catch (e) {
      await _log.error('Core stale cleanup failed', e);
    }
  }
}
