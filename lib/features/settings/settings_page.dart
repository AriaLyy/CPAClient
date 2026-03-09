import 'dart:async';
import 'dart:io';

import 'package:cpaclient/core/services/app_services.dart';
import 'package:cpaclient/features/settings/settings_controller.dart';
import 'package:cpaclient/features/tray/tray_service.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

enum _SettingsSection { core, security, preferences, webdav, about }

enum _CoreShortcutAction { configFile, configDirectory, sandboxDirectory }

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.onThemeModeChanged});

  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsController _controller = SettingsController();
  TrayService? _trayService;
  _SettingsSection _activeSection = _SettingsSection.core;
  bool _updatingCore = false;
  bool _restartingCore = false;
  bool _stoppingCore = false;
  bool _backingUpWebdav = false;
  bool _restoringWebdav = false;
  bool _showGithubToken = false;
  bool _showWebuiPassword = false;
  bool _showWebdavPassword = false;
  _SettingsSection? _hoveredSection;
  _SettingsSection? _focusedSection;
  final ScrollController _desktopScrollController = ScrollController();
  bool _syncingDesktopScroll = false;
  late final Map<_SettingsSection, GlobalKey> _desktopSectionKeys = {
    for (final section in _SettingsSection.values) section: GlobalKey(),
  };

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

  static const double _sectionGap = 24;
  static const double _itemGap = 16;
  static const double _desktopContentMaxWidth = 760;
  static const double _desktopSidebarWidth = 180;
  static const double _uiIconSize = 16;
  static const double _controlMinHeight = 40;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _desktopScrollController.addListener(_syncActiveSectionFromScroll);
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
      onStopCore: _runStopCore,
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
    _desktopScrollController.removeListener(_syncActiveSectionFromScroll);
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
    _desktopScrollController.dispose();
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
    _reloadWebdavDraftFromSettings();
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
    if (_updatingCore || _restartingCore) {
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

  Future<void> _runRestartCore() async {
    if (_restartingCore || _updatingCore) {
      return;
    }
    setState(() {
      _restartingCore = true;
    });
    try {
      await _run(_controller.restartCore);
    } finally {
      if (mounted) {
        setState(() {
          _restartingCore = false;
        });
      }
    }
  }

  Future<void> _runStopCore() async {
    if (_stoppingCore) {
      return;
    }
    setState(() {
      _stoppingCore = true;
    });
    try {
      await _run(_controller.stopCore);
    } finally {
      if (mounted) {
        setState(() {
          _stoppingCore = false;
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

  Future<void> _handleCoreShortcutAction(_CoreShortcutAction action) async {
    switch (action) {
      case _CoreShortcutAction.configFile:
        await _run(_controller.openConfigFile);
      case _CoreShortcutAction.configDirectory:
        await _run(_controller.openConfigDirectory);
      case _CoreShortcutAction.sandboxDirectory:
        await _run(_controller.openSandboxDirectory);
    }
  }

  String? _webdavUrlErrorText(String value) {
    final input = value.trim();
    if (input.isEmpty) {
      return '请输入 WebDAV 地址';
    }
    if (!input.startsWith('https://')) {
      return '地址需以 https:// 开头';
    }
    if (input.endsWith('/')) {
      return '地址不能以 / 结尾';
    }
    return null;
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
              style: _textControlStyle(),
              onPressed: () async {
                await _run(_controller.openGithubTokenPage);
              },
              child: const Text('去 GitHub 获取'),
            ),
            FilledButton(
              style: _filledControlStyle(),
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

  InputDecoration _inputDecoration({
    required String label,
    String? hint,
    String? helper,
    String? error,
    Widget? suffixIcon,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      errorText: error,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        borderSide:
            BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      isDense: true,
    );
  }

  Color _coreStatusDotColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _controller.isCoreRunning ? Colors.green : scheme.error;
  }

  Color _webdavStatusDotColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (_controller.webdavStatusLevel) {
      WebdavStatusLevel.success => Colors.green,
      WebdavStatusLevel.failure => scheme.error,
      WebdavStatusLevel.running => scheme.primary,
      WebdavStatusLevel.idle => scheme.onSurfaceVariant,
    };
  }

  String _webdavStatusLabel() {
    return switch (_controller.webdavStatusLevel) {
      WebdavStatusLevel.success => '连接成功',
      WebdavStatusLevel.failure => '连接失败',
      WebdavStatusLevel.running => '处理中',
      WebdavStatusLevel.idle => '未测试',
    };
  }

  String _sectionTitle(_SettingsSection section) {
    return switch (section) {
      _SettingsSection.core => '核心运行',
      _SettingsSection.security => '安全访问',
      _SettingsSection.preferences => '应用偏好',
      _SettingsSection.webdav => 'WebDav',
      _SettingsSection.about => '关于',
    };
  }

  IconData _sectionIcon(_SettingsSection section) {
    return switch (section) {
      _SettingsSection.core => Icons.memory_rounded,
      _SettingsSection.security => Icons.security_rounded,
      _SettingsSection.preferences => Icons.tune_rounded,
      _SettingsSection.webdav => Icons.cloud_sync_rounded,
      _SettingsSection.about => Icons.info_outline_rounded,
    };
  }

  Color? _sectionIndicatorColor(
      _SettingsSection section, BuildContext context) {
    return switch (section) {
      _SettingsSection.core => _coreStatusDotColor(context),
      _SettingsSection.webdav => _webdavStatusDotColor(context),
      _ => null,
    };
  }

  Widget _statusPill({
    required String label,
    required Color color,
    IconData? icon,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: _uiIconSize, color: color)
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Text(
            label,
            style: textTheme.labelSmall
                ?.copyWith(fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }

  Widget _metricRow({required String label, required String value}) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style:
                textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  ButtonStyle _filledControlStyle() {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.styleFrom(
      minimumSize: const Size(0, _controlMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      disabledBackgroundColor:
          scheme.surfaceContainerHighest.withValues(alpha: 0.75),
      disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.45),
    ).copyWith(
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return scheme.onPrimary.withValues(alpha: 0.18);
        }
        if (states.contains(WidgetState.hovered)) {
          return scheme.onPrimary.withValues(alpha: 0.1);
        }
        if (states.contains(WidgetState.focused)) {
          return scheme.onPrimary.withValues(alpha: 0.14);
        }
        return null;
      }),
    );
  }

  ButtonStyle _tonalControlStyle() {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.styleFrom(
      minimumSize: const Size(0, _controlMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      disabledBackgroundColor:
          scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.45),
    ).copyWith(
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return scheme.primary.withValues(alpha: 0.18);
        }
        if (states.contains(WidgetState.hovered)) {
          return scheme.primary.withValues(alpha: 0.1);
        }
        if (states.contains(WidgetState.focused)) {
          return scheme.primary.withValues(alpha: 0.14);
        }
        return null;
      }),
    );
  }

  ButtonStyle _textControlStyle() {
    final scheme = Theme.of(context).colorScheme;
    return TextButton.styleFrom(
      minimumSize: const Size(0, _controlMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ).copyWith(
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return scheme.primary.withValues(alpha: 0.14);
        }
        if (states.contains(WidgetState.hovered)) {
          return scheme.primary.withValues(alpha: 0.08);
        }
        if (states.contains(WidgetState.focused)) {
          return scheme.primary.withValues(alpha: 0.1);
        }
        return null;
      }),
    );
  }

  Widget _menuTrigger({required String label}) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      constraints: const BoxConstraints(minHeight: _controlMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.7)),
        color: scheme.surfaceContainerHigh,
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.more_horiz_rounded,
              size: _uiIconSize, color: scheme.onSurface),
          const SizedBox(width: 8),
          Text(
            label,
            style: textTheme.labelMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
    Color? statusDotColor,
    Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 15, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (statusDotColor != null)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusDotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }

  Widget _sectionGroup({
    required IconData icon,
    required String title,
    required String description,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: _uiIconSize, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                title,
                style:
                    textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style:
                textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _buildOverviewBanner({required bool compact}) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '设置概览',
              style: textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            _metricRow(label: '核心版本', value: _controller.settings.coreVersion),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statusPill(
                  label: compact
                      ? (_controller.isCoreRunning ? 'Core 运行中' : 'Core 已停止')
                      : (_controller.isCoreRunning ? 'Core 运行' : 'Core 停止'),
                  color: _coreStatusDotColor(context),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => unawaited(_run(_controller.openWebUi)),
                  child: _statusPill(
                    label: compact ? '打开 WebUI' : 'WebUI',
                    color: scheme.primary,
                    icon: Icons.open_in_browser,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _syncActiveSectionFromScroll() {
    if (_syncingDesktopScroll ||
        !_desktopScrollController.hasClients ||
        !mounted) {
      return;
    }
    _SettingsSection? candidate;
    var bestDistance = double.infinity;
    const anchorY = 140.0;

    for (final section in _SettingsSection.values) {
      final context = _desktopSectionKeys[section]?.currentContext;
      final render = context?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) {
        continue;
      }
      final dy = render.localToGlobal(Offset.zero).dy;
      final distance = (dy - anchorY).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        candidate = section;
      }
    }

    if (candidate != null && candidate != _activeSection) {
      setState(() {
        _activeSection = candidate!;
      });
    }
  }

  Future<void> _scrollToDesktopSection(_SettingsSection section) async {
    setState(() {
      _activeSection = section;
    });
    final targetContext = _desktopSectionKeys[section]?.currentContext;
    if (targetContext == null) {
      return;
    }
    _syncingDesktopScroll = true;
    await Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: 0.04,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _syncingDesktopScroll = false;
  }

  Widget _buildNavigationPanel() {
    final sections = _SettingsSection.values;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
              child: Text(
                '设置导航',
                style: textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final section in sections) ...[
              Builder(
                builder: (context) {
                  final selected = _activeSection == section;
                  final hovered = _hoveredSection == section;
                  final focused = _focusedSection == section;
                  final bgColor = selected
                      ? scheme.primary.withValues(alpha: 0.12)
                      : hovered
                          ? scheme.surfaceContainerHigh.withValues(alpha: 0.8)
                          : focused
                              ? scheme.surfaceContainerHigh
                                  .withValues(alpha: 0.7)
                              : Colors.transparent;
                  final borderColor = selected
                      ? scheme.primary.withValues(alpha: 0.26)
                      : hovered || focused
                          ? scheme.outlineVariant.withValues(alpha: 0.6)
                          : Colors.transparent;
                  final titleColor =
                      selected ? scheme.primary : scheme.onSurface;

                  return MouseRegion(
                    onEnter: (_) {
                      setState(() {
                        _hoveredSection = section;
                      });
                    },
                    onExit: (_) {
                      if (_hoveredSection == section) {
                        setState(() {
                          _hoveredSection = null;
                        });
                      }
                    },
                    child: Focus(
                      onFocusChange: (hasFocus) {
                        setState(() {
                          if (hasFocus) {
                            _focusedSection = section;
                          } else if (_focusedSection == section) {
                            _focusedSection = null;
                          }
                        });
                      },
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          if (selected) {
                            return;
                          }
                          unawaited(_scrollToDesktopSection(section));
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOutCubic,
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                          decoration: BoxDecoration(
                            color: bgColor,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: borderColor),
                          ),
                          child: Row(
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                width: 3,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: selected
                                      ? scheme.primary
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                _sectionIcon(section),
                                size: _uiIconSize,
                                color: titleColor,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _sectionTitle(section),
                                  style: textTheme.labelLarge?.copyWith(
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                    color: titleColor,
                                  ),
                                ),
                              ),
                              if (_sectionIndicatorColor(section, context) !=
                                  null)
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _sectionIndicatorColor(
                                        section, context),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (section != sections.last) const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCoreSection(
      {required List<String> versions, required String selectedVersion}) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final statusMessage = _controller.lastStatus.trim();
    final latestVersion = versions.first;
    final hasNewVersion = latestVersion != selectedVersion;
    return _sectionCard(
      icon: Icons.memory_rounded,
      title: '核心运行',
      subtitle: '版本选择、进程控制与配置入口',
      statusDotColor: _coreStatusDotColor(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Column(
              children: [
                _metricRow(
                  label: '运行状态',
                  value: _controller.isCoreRunning ? '运行中' : '已停止',
                ),
                const SizedBox(height: 8),
                _metricRow(label: '当前端口', value: '${_controller.currentPort}'),
                const SizedBox(height: 8),
                _metricRow(label: '当前版本', value: selectedVersion),
                if (statusMessage.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '状态消息',
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusMessage,
                    style: textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: _itemGap),
          DropdownButtonFormField<String>(
            value: selectedVersion,
            decoration: _inputDecoration(
              label: '核心版本',
              helper: hasNewVersion
                  ? '检测到新版本 $latestVersion，可点击「更新核心」升级'
                  : '当前已是最近版本',
            ),
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
                style: _filledControlStyle(),
                onPressed: _updatingCore ? null : _runUpdateCore,
                icon: _updatingCore
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.system_update, size: _uiIconSize),
                label: Text(_updatingCore ? '更新中...' : '更新核心'),
              ),
              FilledButton.tonalIcon(
                style: _tonalControlStyle(),
                onPressed: _restartingCore ? null : _runRestartCore,
                icon: _restartingCore
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.restart_alt, size: _uiIconSize),
                label: const Text('重启核心'),
              ),
              FilledButton.tonalIcon(
                style: _tonalControlStyle(),
                onPressed: _stoppingCore ? null : _runStopCore,
                icon: _stoppingCore
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.stop_circle_outlined, size: _uiIconSize),
                label: const Text('停止核心'),
              ),
              FilledButton.tonalIcon(
                style: _tonalControlStyle(),
                onPressed: () => _run(_controller.openWebUi),
                icon: Icon(Icons.open_in_browser, size: _uiIconSize),
                label: const Text('打开 WebUI'),
              ),
            ],
          ),
          const SizedBox(height: _itemGap),
          Text(
            '配置快捷入口',
            style: textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          PopupMenuButton<_CoreShortcutAction>(
            tooltip: '打开相关文件',
            onSelected: (action) =>
                unawaited(_handleCoreShortcutAction(action)),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _CoreShortcutAction.configFile,
                child: ListTile(
                  leading: Icon(Icons.description_outlined, size: _uiIconSize),
                  title: const Text('打开 config.yaml'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              PopupMenuItem(
                value: _CoreShortcutAction.configDirectory,
                child: ListTile(
                  leading: Icon(Icons.folder_open, size: _uiIconSize),
                  title: const Text('打开配置目录'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              PopupMenuItem(
                value: _CoreShortcutAction.sandboxDirectory,
                child: ListTile(
                  leading: Icon(Icons.source_outlined, size: _uiIconSize),
                  title: const Text('打开 sandbox 目录'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            ],
            child: _menuTrigger(label: '打开相关文件'),
          ),
        ],
      ),
    );
  }

  Widget _buildSecuritySection() {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return _sectionCard(
      icon: Icons.security_rounded,
      title: '安全访问',
      subtitle: '管理 GitHub Token 与 WebUI 密钥',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionGroup(
            icon: Icons.key_rounded,
            title: 'GitHub Token',
            description: '用于拉取 GitHub Release。可选择本地加密保存或仅临时使用。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _githubTokenCtl,
                  focusNode: _githubTokenFocus,
                  obscureText: !_showGithubToken,
                  decoration: _inputDecoration(
                    label: 'GitHub Token',
                    hint: 'ghp_xxx / github_pat_xxx',
                    helper: 'Token 需具备 repo 权限，用于获取核心版本列表',
                    suffixIcon: IconButton(
                      tooltip: _showGithubToken ? '隐藏 Token' : '显示 Token',
                      onPressed: () {
                        setState(() {
                          _showGithubToken = !_showGithubToken;
                        });
                      },
                      icon: Icon(
                        _showGithubToken
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: _uiIconSize,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _controller.settings.keepGithubToken,
                  title: const Text('本地保持 Token'),
                  subtitle: const Text('关闭后将不在本地保留 Token'),
                  onChanged: (value) =>
                      _run(() => _controller.saveKeepGithubToken(value)),
                ),
                const SizedBox(height: _itemGap),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      style: _filledControlStyle(),
                      onPressed: () => _run(() =>
                          _controller.saveGithubToken(_githubTokenCtl.text)),
                      child: const Text('保存 Token'),
                    ),
                    TextButton.icon(
                      style: _textControlStyle(),
                      onPressed: () => _run(_controller.openGithubTokenPage),
                      icon: Icon(Icons.open_in_new, size: _uiIconSize),
                      label: const Text('去 GitHub 获取'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: _itemGap),
          _sectionGroup(
            icon: Icons.admin_panel_settings_rounded,
            title: 'WebUI 管理密钥',
            description: '该密钥用于管理接口鉴权，并同步写入 remote-management.secret-key。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _webuiPasswordCtl,
                  focusNode: _webuiPasswordFocus,
                  obscureText: !_showWebuiPassword,
                  decoration: _inputDecoration(
                    label: 'WebUI 密钥',
                    hint: '与 Core 管理密钥保持一致',
                    helper: '保存后会同步更新到 config.yaml 的 secret-key',
                    suffixIcon: IconButton(
                      tooltip: _showWebuiPassword ? '隐藏密钥' : '显示密钥',
                      onPressed: () {
                        setState(() {
                          _showWebuiPassword = !_showWebuiPassword;
                        });
                      },
                      icon: Icon(
                        _showWebuiPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: _uiIconSize,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: _itemGap),
                FilledButton(
                  style: _filledControlStyle(),
                  onPressed: () => _run(() =>
                      _controller.saveWebuiPassword(_webuiPasswordCtl.text)),
                  child: const Text('保存 WebUI 密钥'),
                ),
                const SizedBox(height: 6),
                Text(
                  '提示：请妥善保管该密钥，避免泄露。',
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreferencesSection() {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return _sectionCard(
      icon: Icons.tune_rounded,
      title: '应用偏好',
      subtitle: '系统启动策略与主题模式',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _controller.launchAtStartupEnabled,
            title: const Text('系统登录后自动启动 CPAClient'),
            subtitle: const Text('仅在桌面环境中生效'),
            onChanged: (value) =>
                _run(() => _controller.setLaunchAtStartup(value)),
          ),
          const SizedBox(height: _itemGap),
          DropdownButtonFormField<ThemeMode>(
            value: _controller.themeMode,
            decoration: _inputDecoration(label: '主题模式'),
            items: [
              DropdownMenuItem(
                value: ThemeMode.system,
                child: Row(
                  children: [
                    Icon(Icons.settings_brightness, size: _uiIconSize),
                    const SizedBox(width: 8),
                    const Text('随系统'),
                  ],
                ),
              ),
              DropdownMenuItem(
                value: ThemeMode.light,
                child: Row(
                  children: [
                    Icon(Icons.light_mode_outlined, size: _uiIconSize),
                    const SizedBox(width: 8),
                    const Text('日间'),
                  ],
                ),
              ),
              DropdownMenuItem(
                value: ThemeMode.dark,
                child: Row(
                  children: [
                    Icon(Icons.dark_mode_outlined, size: _uiIconSize),
                    const SizedBox(width: 8),
                    const Text('夜间'),
                  ],
                ),
              ),
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
          const SizedBox(height: 8),
          Text(
            '主题会即时生效，并同步保存到本地设置。',
            style:
                textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildWebdavSection() {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final intervalMinutes =
        _controller.settings.webdavAutoBackupIntervalMinutes;
    return _sectionCard(
      icon: Icons.cloud_sync_rounded,
      title: 'WebDAV 同步',
      subtitle: '远程备份、连接测试与一键还原',
      statusDotColor: _webdavStatusDotColor(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statusPill(
                  label: '状态: ${_webdavStatusLabel()}',
                  color: _webdavStatusDotColor(context),
                ),
                const SizedBox(height: 8),
                Text(
                  _controller.webdavStatusText,
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: _itemGap),
          TextField(
            controller: _webdavUrlCtl,
            focusNode: _webdavUrlFocus,
            decoration: _inputDecoration(
              label: '地址',
              hint: 'https://example.com/webdav',
              helper: '地址需以 https:// 开头，且不以 / 结尾',
              error: _webdavUrlErrorText(_webdavUrlCtl.text),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: _itemGap),
          TextField(
            controller: _webdavUserCtl,
            focusNode: _webdavUserFocus,
            decoration: _inputDecoration(
              label: '用户名',
              helper: '通常为 WebDAV 账号或邮箱',
            ),
          ),
          const SizedBox(height: _itemGap),
          TextField(
            controller: _webdavPwdCtl,
            focusNode: _webdavPwdFocus,
            obscureText: !_showWebdavPassword,
            decoration: _inputDecoration(
              label: '密码',
              suffixIcon: IconButton(
                tooltip: _showWebdavPassword ? '隐藏密码' : '显示密码',
                onPressed: () {
                  setState(() {
                    _showWebdavPassword = !_showWebdavPassword;
                  });
                },
                icon: Icon(
                  _showWebdavPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: _uiIconSize,
                ),
              ),
            ),
          ),
          const SizedBox(height: _itemGap),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _controller.settings.webdavAutoBackupEnabled,
            title: Text('自动备份（每 $intervalMinutes 分钟）'),
            subtitle: const Text('自动备份 config.yaml、auth-json 与 usage.json'),
            onChanged: (value) =>
                _run(() => _controller.saveWebdavAutoBackupEnabled(value)),
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
                style: _filledControlStyle(),
                onPressed: () => _run(() async {
                  final msg = await _controller.saveWebdavForm(
                    url: _webdavUrlCtl.text,
                    username: _webdavUserCtl.text,
                    password: _webdavPwdCtl.text,
                  );
                  _reloadWebdavDraftFromSettings();
                  return msg;
                }),
                icon: Icon(Icons.save_outlined, size: _uiIconSize),
                label: const Text('保存设置'),
              ),
              FilledButton.tonalIcon(
                style: _tonalControlStyle(),
                onPressed: () => _run(() => _controller.testWebdavConnection(
                      url: _webdavUrlCtl.text,
                      username: _webdavUserCtl.text,
                      password: _webdavPwdCtl.text,
                    )),
                icon: Icon(Icons.wifi_tethering, size: _uiIconSize),
                label: const Text('测试连接'),
              ),
              FilledButton.tonalIcon(
                style: _tonalControlStyle(),
                onPressed: _backingUpWebdav ? null : _runBackupWebdav,
                icon: _backingUpWebdav
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.cloud_upload_outlined, size: _uiIconSize),
                label: Text(_backingUpWebdav ? '备份中...' : '立即备份'),
              ),
              FilledButton.tonalIcon(
                style: _tonalControlStyle(),
                onPressed: _restoringWebdav ? null : _runRestoreWebdav,
                icon: _restoringWebdav
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.settings_backup_restore, size: _uiIconSize),
                label: Text(_restoringWebdav ? '还原中...' : '还原配置'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSection() {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return _sectionCard(
      icon: Icons.info_outline_rounded,
      title: '关于',
      subtitle: '项目入口与帮助链接',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '版本信息',
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                _metricRow(label: '应用版本', value: '未知'),
                const SizedBox(height: 6),
                _metricRow(
                    label: '核心版本', value: _controller.settings.coreVersion),
                const SizedBox(height: 10),
                Text(
                  '项目仓库',
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'https://github.com/AriaLyy/CPAClient',
                  style: textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          const SizedBox(height: _itemGap),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, _controlMinHeight),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _run(_controller.openAbout),
                icon: Icon(Icons.open_in_new, size: _uiIconSize),
                label: const Text('打开项目主页'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, _controlMinHeight),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _run(_controller.openSandboxDirectory),
                icon: Icon(Icons.folder_special_outlined, size: _uiIconSize),
                label: const Text('打开 sandbox 目录'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout({
    required List<String> versions,
    required String selectedVersion,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _desktopSidebarWidth,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildOverviewBanner(compact: false),
                  const SizedBox(height: 14),
                  _buildNavigationPanel(),
                ],
              ),
            ),
          ),
          const SizedBox(width: _sectionGap),
          Expanded(
            child: SingleChildScrollView(
              controller: _desktopScrollController,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: _desktopContentMaxWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KeyedSubtree(
                        key: _desktopSectionKeys[_SettingsSection.core],
                        child: _buildCoreSection(
                          versions: versions,
                          selectedVersion: selectedVersion,
                        ),
                      ),
                      const SizedBox(height: 12),
                      KeyedSubtree(
                        key: _desktopSectionKeys[_SettingsSection.security],
                        child: _buildSecuritySection(),
                      ),
                      const SizedBox(height: 12),
                      KeyedSubtree(
                        key: _desktopSectionKeys[_SettingsSection.preferences],
                        child: _buildPreferencesSection(),
                      ),
                      const SizedBox(height: 12),
                      KeyedSubtree(
                        key: _desktopSectionKeys[_SettingsSection.webdav],
                        child: _buildWebdavSection(),
                      ),
                      const SizedBox(height: 12),
                      KeyedSubtree(
                        key: _desktopSectionKeys[_SettingsSection.about],
                        child: _buildAboutSection(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
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
      body: _buildDesktopLayout(
        versions: versions,
        selectedVersion: selectedVersion,
      ),
    );
  }
}
