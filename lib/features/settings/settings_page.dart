import 'dart:async';
import 'dart:io';

import 'package:cpaclient/core/services/app_services.dart';
import 'package:cpaclient/features/settings/settings_controller.dart';
import 'package:cpaclient/features/tray/tray_service.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.onThemeModeChanged});

  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsController _controller = SettingsController();
  TrayService? _trayService;
  bool _updatingCore = false;
  bool _backingUpWebdav = false;
  bool _restoringWebdav = false;

  final TextEditingController _githubTokenCtl = TextEditingController();
  final TextEditingController _webuiPasswordCtl = TextEditingController();
  final TextEditingController _webdavUrlCtl = TextEditingController();
  final TextEditingController _webdavUserCtl = TextEditingController();
  final TextEditingController _webdavPwdCtl = TextEditingController();

  final FocusNode _githubTokenFocus = FocusNode();
  final FocusNode _webuiPasswordFocus = FocusNode();
  final FocusNode _webdavUrlFocus = FocusNode();
  final FocusNode _webdavUserFocus = FocusNode();
  final FocusNode _webdavPwdFocus = FocusNode();

  static const double _pagePadding = 18;
  static const double _sectionGap = 14;
  static const double _itemGap = 14;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.load().whenComplete(() async {
      if (!mounted) {
        return;
      }
      _reloadWebdavDraftFromSettings();
      if (_controller.needsGithubToken) {
        await _showGithubTokenDialog();
      }
    });
    _initTray();
  }

  Future<void> _initTray() async {
    final tray = TrayService(
      sandboxConfig: AppServices.sandboxConfig,
      onOpenSettings: () async => _focusWindow(),
      onExit: _exitApp,
      log: AppServices.log,
    );
    await tray.init();
    _trayService = tray;
  }

  Future<void> _focusWindow() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitApp() async {
    await _controller.disposeController();
    exit(0);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    unawaited(_controller.disposeController());
    unawaited(_trayService?.dispose());
    _trayService = null;
    _controller.dispose();
    _githubTokenCtl.dispose();
    _webuiPasswordCtl.dispose();
    _webdavUrlCtl.dispose();
    _webdavUserCtl.dispose();
    _webdavPwdCtl.dispose();
    _githubTokenFocus.dispose();
    _webuiPasswordFocus.dispose();
    _webdavUrlFocus.dispose();
    _webdavUserFocus.dispose();
    _webdavPwdFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) {
      return;
    }
    if (_isEditingAnyField) {
      setState(() {});
      return;
    }
    _syncText(_githubTokenCtl, _controller.settings.githubToken);
    _syncText(_webuiPasswordCtl, _controller.webuiPassword);
    setState(() {});
  }

  void _reloadWebdavDraftFromSettings() {
    _syncText(_webdavUrlCtl, _displayWebdavUrl(_controller.settings.webdavUrl));
    _syncText(_webdavUserCtl, _controller.settings.webdavUsername);
    _syncText(_webdavPwdCtl, _controller.settings.webdavPassword);
  }

  bool get _isEditingAnyField {
    return _githubTokenFocus.hasFocus ||
        _webuiPasswordFocus.hasFocus ||
        _webdavUrlFocus.hasFocus ||
        _webdavUserFocus.hasFocus ||
        _webdavPwdFocus.hasFocus;
  }

  String _displayWebdavUrl(String value) {
    const suffix = '/CpaClient';
    if (value.endsWith(suffix)) {
      return value.substring(0, value.length - suffix.length);
    }
    return value;
  }

  void _syncText(TextEditingController controller, String value) {
    if (controller.text != value) {
      controller.text = value;
    }
  }

  Future<void> _run(Future<String> Function() action) async {
    final msg = await action();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _runUpdateCore() async {
    if (_updatingCore) {
      return;
    }
    setState(() {
      _updatingCore = true;
    });
    try {
      await _run(_controller.updateCore);
    } finally {
      if (mounted) {
        setState(() {
          _updatingCore = false;
        });
      }
    }
  }

  Future<void> _runBackupWebdav() async {
    if (_backingUpWebdav) {
      return;
    }
    setState(() {
      _backingUpWebdav = true;
    });
    try {
      await _run(_controller.backupConfigToWebdav);
    } finally {
      if (mounted) {
        setState(() {
          _backingUpWebdav = false;
        });
      }
    }
  }

  Future<void> _runRestoreWebdav() async {
    if (_restoringWebdav) {
      return;
    }
    setState(() {
      _restoringWebdav = true;
    });
    try {
      await _run(_controller.restoreConfigFromWebdav);
    } finally {
      if (mounted) {
        setState(() {
          _restoringWebdav = false;
        });
      }
    }
  }

  Future<void> _showGithubTokenDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('需要 GitHub Token'),
          content: const Text('首次下载核心必须配置 GitHub Token，避免限流导致 403。'),
          actions: [
            TextButton(
              onPressed: () async {
                await _run(_controller.openGithubTokenPage);
              },
              child: const Text('去 GitHub 获取'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
              },
              child: const Text('我知道了'),
            ),
          ],
        );
      },
    );
  }

  InputDecoration _inputDecoration({required String label, String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      isDense: true,
    );
  }

  Color _coreStatusAccentColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _controller.isCoreRunning ? scheme.primary : scheme.error;
  }

  String _coreStatusLabel() {
    return _controller.isCoreRunning ? '运行中' : '未运行';
  }

  Color _webdavStatusAccentColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (_controller.webdavStatusLevel) {
      WebdavStatusLevel.success => scheme.primary,
      WebdavStatusLevel.failure => scheme.error,
      WebdavStatusLevel.running => scheme.secondary,
      WebdavStatusLevel.idle => scheme.outline,
    };
  }

  String _webdavStatusLabel() {
    return switch (_controller.webdavStatusLevel) {
      WebdavStatusLevel.success => '成功',
      WebdavStatusLevel.failure => '失败',
      WebdavStatusLevel.running => '进行中',
      WebdavStatusLevel.idle => '未测试',
    };
  }

  IconData _webdavStatusIcon() {
    return switch (_controller.webdavStatusLevel) {
      WebdavStatusLevel.success => Icons.check_circle,
      WebdavStatusLevel.failure => Icons.error,
      WebdavStatusLevel.running => Icons.sync,
      WebdavStatusLevel.idle => Icons.info,
    };
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 16, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: _itemGap),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildCoreSection({required List<String> versions, required String selectedVersion}) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return _sectionCard(
      icon: Icons.layers,
      title: '核心运行',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(
                  _controller.isCoreRunning ? Icons.check_circle : Icons.error_outline,
                  color: _coreStatusAccentColor(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '核心状态：${_coreStatusLabel()}',
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '端口 ${_controller.currentPort}',
                        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: _itemGap),
          DropdownButtonFormField<String>(
            value: selectedVersion,
            decoration: _inputDecoration(label: '核心版本'),
            items: versions
                .map((v) => DropdownMenuItem<String>(value: v, child: Text(v)))
                .toList(growable: false),
            onChanged: (value) {
              if (value == null) {
                return;
              }
              unawaited(_run(() => _controller.updateVersion(value)));
            },
          ),
          const SizedBox(height: _itemGap),
          Text(
            '运行操作',
            style: textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _updatingCore ? null : _runUpdateCore,
                icon: _updatingCore
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.system_update),
                label: Text(_updatingCore ? '更新中...' : '更新核心'),
              ),
              FilledButton.tonal(
                onPressed: _updatingCore ? null : _runUpdateCore,
                child: const Text('重启核心'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _run(_controller.openWebUi),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('打开 WebUI'),
              ),
            ],
          ),
          const SizedBox(height: _itemGap),
          Text(
            '核心配置快捷入口',
            style: textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _run(_controller.openConfigFile),
                icon: const Icon(Icons.description_outlined),
                label: const Text('打开 config.yaml'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _run(_controller.openConfigDirectory),
                icon: const Icon(Icons.folder_open),
                label: const Text('打开配置目录'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _run(_controller.openSandboxDirectory),
                icon: const Icon(Icons.source_outlined),
                label: const Text('打开 sandbox 目录'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSecuritySection() {
    return _sectionCard(
      icon: Icons.security,
      title: '安全访问',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _githubTokenCtl,
            focusNode: _githubTokenFocus,
            obscureText: true,
            decoration: _inputDecoration(label: 'GitHub Token', hint: 'ghp_xxx / github_pat_xxx'),
          ),
          const SizedBox(height: _itemGap),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => _run(() => _controller.saveGithubToken(_githubTokenCtl.text)),
                child: const Text('保存 Token'),
              ),
              FilledButton.tonal(
                onPressed: () => _run(_controller.openGithubTokenPage),
                child: const Text('去 GitHub 获取'),
              ),
            ],
          ),
          const SizedBox(height: _itemGap),
          TextField(
            controller: _webuiPasswordCtl,
            focusNode: _webuiPasswordFocus,
            obscureText: true,
            decoration: _inputDecoration(label: 'WebUI 密码', hint: '同步到 remote-management.secret-key'),
          ),
          const SizedBox(height: _itemGap),
          FilledButton(
            onPressed: () => _run(() => _controller.saveWebuiPassword(_webuiPasswordCtl.text)),
            child: const Text('保存 WebUI 密码'),
          ),
        ],
      ),
    );
  }

  Widget _buildPreferencesSection() {
    return _sectionCard(
      icon: Icons.tune,
      title: '应用偏好',
      child: Column(
        children: [
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _controller.launchAtStartupEnabled,
            title: const Text('开机启动'),
            onChanged: (value) => _run(() => _controller.setLaunchAtStartup(value)),
          ),
          const SizedBox(height: _itemGap),
          DropdownButtonFormField<ThemeMode>(
            value: _controller.themeMode,
            decoration: _inputDecoration(label: '主题'),
            items: const [
              DropdownMenuItem(value: ThemeMode.system, child: Text('随系统')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('日间')),
              DropdownMenuItem(value: ThemeMode.dark, child: Text('夜间')),
            ],
            onChanged: (value) {
              if (value == null) {
                return;
              }
              unawaited(_run(() async {
                final msg = await _controller.saveThemeMode(value);
                widget.onThemeModeChanged(value);
                return msg;
              }));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildWebdavSection() {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return _sectionCard(
      icon: Icons.cloud_sync,
      title: 'WebDAV 同步',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(_webdavStatusIcon(), color: _webdavStatusAccentColor(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '同步状态：${_webdavStatusLabel()}',
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        _controller.webdavStatusText,
                        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: _itemGap),
          TextField(
            controller: _webdavUrlCtl,
            focusNode: _webdavUrlFocus,
            decoration: _inputDecoration(label: '地址', hint: 'https://example.com/webdav'),
          ),
          const SizedBox(height: _itemGap),
          TextField(
            controller: _webdavUserCtl,
            focusNode: _webdavUserFocus,
            decoration: _inputDecoration(label: '用户名'),
          ),
          const SizedBox(height: _itemGap),
          TextField(
            controller: _webdavPwdCtl,
            focusNode: _webdavPwdFocus,
            obscureText: true,
            decoration: _inputDecoration(label: '密码'),
          ),
          const SizedBox(height: _itemGap),
          Text(
            '连接与同步操作',
            style: textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _run(() async {
                  final msg = await _controller.saveWebdavForm(
                    url: _webdavUrlCtl.text,
                    username: _webdavUserCtl.text,
                    password: _webdavPwdCtl.text,
                  );
                  await _controller.reloadWebdavSettings();
                  _reloadWebdavDraftFromSettings();
                  return msg;
                }),
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存设置'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _run(() => _controller.testWebdavConnection(
                      url: _webdavUrlCtl.text,
                      username: _webdavUserCtl.text,
                      password: _webdavPwdCtl.text,
                    )),
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('测试连接'),
              ),
              FilledButton.tonalIcon(
                onPressed: _backingUpWebdav ? null : _runBackupWebdav,
                icon: _backingUpWebdav
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file),
                label: const Text('备份配置'),
              ),
              FilledButton.tonalIcon(
                onPressed: _restoringWebdav ? null : _runRestoreWebdav,
                icon: _restoringWebdav
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.settings_backup_restore),
                label: const Text('还原配置'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSection() {
    return Card(
      child: ListTile(
        dense: true,
        title: const Text('关于'),
        subtitle: const Text('https://github.com/AriaLyy/CPAClient'),
        trailing: const Icon(Icons.open_in_new),
        onTap: () => _run(_controller.openAbout),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final versions = _controller.recentVersions.isEmpty
        ? <String>[_controller.settings.coreVersion]
        : _controller.recentVersions;
    final selectedVersion = versions.contains(_controller.settings.coreVersion)
        ? _controller.settings.coreVersion
        : versions.first;

    return Scaffold(
      appBar: AppBar(title: const Text('CPAClient 设置')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 860;
          final sections = <Widget>[
            _buildCoreSection(versions: versions, selectedVersion: selectedVersion),
            _buildSecuritySection(),
            _buildPreferencesSection(),
            _buildWebdavSection(),
            _buildAboutSection(),
          ];

          if (isNarrow) {
            return ListView.separated(
              padding: const EdgeInsets.all(_pagePadding),
              itemBuilder: (_, index) => sections[index],
              separatorBuilder: (_, __) => const SizedBox(height: _sectionGap),
              itemCount: sections.length,
            );
          }

          final isWide = constraints.maxWidth >= 1180;
          if (!isWide) {
            return ListView.separated(
              padding: const EdgeInsets.all(_pagePadding),
              itemBuilder: (_, index) => sections[index],
              separatorBuilder: (_, __) => const SizedBox(height: _sectionGap),
              itemCount: sections.length,
            );
          }

          return ListView(
            padding: const EdgeInsets.all(_pagePadding),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildCoreSection(versions: versions, selectedVersion: selectedVersion)),
                  const SizedBox(width: _sectionGap),
                  Expanded(child: _buildPreferencesSection()),
                ],
              ),
              const SizedBox(height: _sectionGap),
              _buildSecuritySection(),
              const SizedBox(height: _sectionGap),
              _buildWebdavSection(),
              const SizedBox(height: _sectionGap),
              _buildAboutSection(),
            ],
          );
        },
      ),
    );
  }
}
