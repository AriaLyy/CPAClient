import 'package:cpaclient/core/services/app_log_service.dart';
import 'package:cpaclient/core/services/core_process_manager.dart';
import 'package:cpaclient/core/services/sandbox_config_service.dart';
import 'package:cpaclient/core/services/startup_service.dart';

class CoreControlService {
  CoreControlService({
    required StartupService startup,
    required CoreProcessManager process,
    required SandboxConfigService sandboxConfig,
    required AppLogService log,
  })  : _startup = startup,
        _process = process,
        _sandboxConfig = sandboxConfig,
        _log = log;

  final StartupService _startup;
  final CoreProcessManager _process;
  final SandboxConfigService _sandboxConfig;
  final AppLogService _log;

  Future<int> updateCore({
    required String version,
    required String githubToken,
  }) async {
    await _log.info('Core update requested: version=$version');
    await _startup.updateCore(version: version, githubToken: githubToken);
    final port = await _sandboxConfig.readPort();
    await _log.info('Core update success: version=$version');
    return port;
  }

  Future<int> restartCore() async {
    await _log.info('Core restart requested');
    await _process.stop();
    await _process.start();
    final port = await _sandboxConfig.readPort();
    await _log.info('Core restart success');
    return port;
  }

  Future<void> stopCore() async {
    await _process.stop();
  }
}
