import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/inputs/uten_dropdown_scroll_scope.dart';
import '../../components/feedback/uten_motion.dart';
import '../../components/layout/uten_app_bar.dart';
import '../../components/layout/uten_content_container.dart';
import '../../core/router/page_navigation_session.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/ui/uten_notify.dart';
import '../../core/ui/opportunistic_dialog_coordinator.dart';
import 'client_release.dart';
import 'client_release_access.dart';
import 'software_downloads_controller.dart';
import 'software_downloads_presentation.dart';

class SoftwareDownloadsPage extends ConsumerStatefulWidget {
  const SoftwareDownloadsPage({super.key});
  @override
  ConsumerState<SoftwareDownloadsPage> createState() => _DownloadsState();
}

class _DownloadsState extends ConsumerState<SoftwareDownloadsPage> {
  SoftwareDownloadPlatform _platform = SoftwareDownloadPlatform.windows;
  SoftwareWindowsVersion? _windowsVersion;
  String _runtimeFamily = ClientRuntimeFamily.flutter;
  String? _architecture;
  bool _manualSelection = false;
  final _navigation = PageNavigationSession();
  DialogOpportunity? _resultOpportunity;

  SoftwareDownloadTarget get _target => SoftwareDownloadTarget(
    platform: _platform,
    runtimeFamily: _runtimeFamily,
    architecture: _architecture ?? 'unknown',
    windowsVersion: _windowsVersion,
  );

  @override
  void initState() {
    super.initState();
    _platform =
        ref.read(softwareDevicePlatformProvider) ??
        SoftwareDownloadPlatform.windows;
    _runtimeFamily = _platform == SoftwareDownloadPlatform.windows
        ? ref.read(softwareWindowsRuntimeFamilyProvider)
        : ClientRuntimeFamily.flutter;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(softwareDownloadsControllerProvider).load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation.attach(context);
  }

  @override
  void dispose() {
    _navigation.dispose();
    _resultOpportunity?.interrupt();
    super.dispose();
  }

  void _useHost(SoftwareHostInfo host) {
    if (_manualSelection) return;
    final suggestion = host.suggestedTarget;
    setState(() {
      _platform = host.platform ?? _platform;
      _architecture = suggestion?.architecture;
      _runtimeFamily =
          suggestion?.runtimeFamily ??
          (_platform == SoftwareDownloadPlatform.windows
              ? host.windowsRuntimeFamily ?? ClientRuntimeFamily.flutter
              : ClientRuntimeFamily.flutter);
      _windowsVersion = suggestion?.windowsVersion;
    });
  }

  void _choosePlatform(SoftwareDownloadPlatform platform) {
    setState(() {
      _manualSelection = true;
      _platform = platform;
      _windowsVersion = null;
      _runtimeFamily = ClientRuntimeFamily.flutter;
      _architecture = null;
    });
  }

  Future<void> _publish(SoftwareDownloadsController controller) async {
    if (ref.read(clientReleasePublisherProvider) == null) return;
    final destination = Uri(
      path: RouteName.clientReleasePublish,
      queryParameters: {
        'platform': _platform.name,
        'runtimeFamily': _runtimeFamily,
        'architecture': ?_architecture,
        'packageKind': 'installer',
      },
    );
    await _navigation.push<void>(destination.toString());
    if (mounted &&
        identical(controller, ref.read(softwareDownloadsControllerProvider))) {
      await controller.load();
    }
  }

  Future<void> _download(
    SoftwareDownloadsController controller,
    ClientRelease release,
  ) async {
    if (controller.downloadingId != null || _resultOpportunity != null) return;
    bool current() =>
        mounted &&
        identical(controller, ref.read(softwareDownloadsControllerProvider));
    await controller.download(release, target: _target);
    if (controller.storeOpened) return;
    if (!mounted ||
        !current() ||
        controller.savedPath == null && controller.downloadError == null) {
      return;
    }
    final opportunity = ref
        .read(opportunisticDialogCoordinatorProvider)
        .tryAcquire();
    if (opportunity == null) {
      return; // Existing authentication/business dialogs take priority.
    }
    _resultOpportunity = opportunity;
    var retry = false;
    try {
      final saved = controller.savedPath;
      if (saved != null) {
        await UtenNotify.alert(
          context,
          title: '安装程序已下载',
          message: release.platform == 'android'
              ? '安装程序已校验并保存。请在 Android 设备上打开 APK，按系统提示完成安装。'
              : release.runtimeFamily == ClientRuntimeFamily.wpfLegacy
              ? '安装程序已校验${kIsWeb ? '并交给浏览器下载' : '并保存到：\n$saved'}。请在 Windows 7 SP1 / 8.1 电脑上打开安装；使用范围及后续更新方式请查看该版本的发布说明。'
              : kIsWeb
              ? '安装程序已校验并交给浏览器下载。请从浏览器下载列表找到 Setup.exe，在 Windows 电脑上打开并完成首次安装。以后可在软件内直接更新。'
              : '已校验并保存到：\n$saved\n\n在 Windows 电脑上双击 Setup.exe 完成首次安装。以后在软件内点击“立即更新”，自动使用原安装位置。',
          confirmLabel: '知道了',
          confirmAsClose: true,
          icon: Icons.check_circle_outline_rounded,
          interruptSignal: opportunity,
        );
      } else {
        retry =
            await UtenNotify.alert(
              context,
              title: '下载未完成',
              message: '请检查网络与本机可用空间后重试。未通过校验的文件不会作为安装程序保存。',
              confirmLabel: '重试下载',
              cancelLabel: '关闭',
              cancelAsClose: true,
              icon: Icons.error_outline_rounded,
              interruptSignal: opportunity,
            ) ==
            true;
      }
    } finally {
      opportunity.dispose();
      if (identical(_resultOpportunity, opportunity)) _resultOpportunity = null;
    }
    if (retry && current() && !opportunity.interrupted) {
      await _download(controller, release);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(softwareDownloadsControllerProvider);
    final host = ref.watch(softwareHostInfoProvider);
    final canPublish = ref.watch(clientReleasePublisherProvider) != null;
    ref.listen(softwareHostInfoProvider, (_, next) {
      final info = next.asData?.value;
      if (info != null && mounted) _useHost(info);
    });
    ref.listen(softwareDownloadsControllerProvider, (_, next) {
      _resultOpportunity?.interrupt();
      _manualSelection = false;
      _architecture = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            identical(next, ref.read(softwareDownloadsControllerProvider))) {
          next.load();
        }
      });
    });
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: UtenAppBar(
        title: '软件下载',
        info:
            '先核对目标设备的系统与架构。自动识别只提供建议，识别不足或为其他设备下载时请手动选择。\n\n'
            'Windows 10 / 11 使用常规版，Windows 7 SP1 / 8.1 使用对应兼容版；兼容版的使用范围、前置条件及更新方式以该版本发布说明为准。\n\n'
            'Windows 下载 Setup.exe 后双击安装；Android 下载 APK 后按系统提示安装。iOS 和 macOS 通过已发布的官方应用商店链接安装和更新。\n\n'
            '安装包由公司授权人员发布，下载完成后自动核对大小与 SHA-256。请使用本人账号登录。',
        showBackButton: true,
        showPagePermissionAction: false,
        actions: [
          if (canPublish)
            UtenButton(
              key: const ValueKey('software-downloads-publish'),
              type: UtenButtonType.secondary,
              size: UtenButtonSize.small,
              icon: Icons.publish_rounded,
              onPressed: () => _publish(controller),
              child: const Text('发布与管理'),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final target = _target;
          final release = selectSoftwareInstaller(
            controller.releases,
            target: target,
          );
          final packageTarget = release == null
              ? target
              : SoftwareDownloadTarget(
                  platform: target.platform,
                  runtimeFamily: release.runtimeFamily,
                  architecture: release.architecture,
                  windowsVersion: target.windowsVersion,
                );
          final busy = controller.downloadingId != null;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: UtenContentContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '为这台设备选择合适的版本',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _HostStrip(
                    host: host,
                    manual: _manualSelection,
                    onReset: busy
                        ? null
                        : () {
                            final info = host.asData?.value;
                            if (info != null) {
                              _manualSelection = false;
                              _useHost(info);
                            }
                          },
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final platform in SoftwareDownloadPlatform.values)
                        ChoiceChip(
                          showCheckmark: false,
                          key: ValueKey('software-select-${platform.name}'),
                          avatar: Icon(platform.icon, size: 18),
                          label: Text(platform.label),
                          selected: _platform == platform,
                          onSelected: busy
                              ? null
                              : (_) => _choosePlatform(platform),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    key: ValueKey('software-platform-${_platform.name}'),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLowest,
                      borderRadius: UtenRadius.cardAll,
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: LayoutBuilder(
                      builder: (context, bounds) {
                        final wide =
                            bounds.maxWidth >= 900 &&
                            MediaQuery.textScalerOf(context).scale(16) <= 24;
                        final content = Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              softwareProductName(
                                Localizations.localeOf(context),
                              ),
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _architecture == null
                                  ? '${_platform == SoftwareDownloadPlatform.windows ? windowsRuntimeLabel(_runtimeFamily) : _platform.label} · 请选择架构'
                                  : target.displayLabel,
                              key: const ValueKey(
                                'software-download-target-label',
                              ),
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '下载目标可以与当前设备不同。请选择实际安装电脑或手机的系统与架构。',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 24),
                            _TargetFields(
                              target: target,
                              architecture: _architecture,
                              enabled: !busy,
                              onVersion: (version, family) => setState(() {
                                _manualSelection = true;
                                _windowsVersion = version;
                                _runtimeFamily = family;
                                if (!_target.isSupported) _architecture = null;
                              }),
                              onArchitecture: (arch) => setState(() {
                                _manualSelection = true;
                                _architecture = arch;
                              }),
                            ),
                            const SizedBox(height: 24),
                            if (release != null) ...[
                              Wrap(
                                spacing: 16,
                                runSpacing: 8,
                                children: [
                                  Text(
                                    '版本 ${release.version}',
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  Text(
                                    '构建 ${release.buildNumber}',
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                  if (release.architecture !=
                                      target.architecture)
                                    Text(
                                      '通用包 · 适用 ${softwareArchitectureLabel(target.architecture)}',
                                    ),
                                  if (release.installMode != 'store')
                                    Text(
                                      '${(release.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                                    ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: UtenButton(
                                  key: ValueKey(
                                    'software-downloads-${_platform.name}',
                                  ),
                                  size: UtenButtonSize.large,
                                  icon: release.installMode == 'store'
                                      ? Icons.open_in_new_rounded
                                      : Icons.download_rounded,
                                  isLoading: busy,
                                  onPressed: busy
                                      ? null
                                      : () => _download(controller, release),
                                  child: Text(
                                    busy
                                        ? '正在处理 ${(controller.progress * 100).floor()}%'
                                        : release.installMode == 'store'
                                        ? '前往 ${_platform.label} 应用商店'
                                        : '下载 ${packageTarget.displayLabel}',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              SelectableText(
                                release.installMode == 'store'
                                    ? '通过官方应用商店安装和更新'
                                    : softwareDownloadFilename(
                                        release,
                                        target: target,
                                      ),
                                style: theme.textTheme.bodySmall,
                              ),
                            ] else ...[
                              Text(
                                controller.loading
                                    ? '正在获取可下载版本'
                                    : _architecture == null
                                    ? '选择架构后查看对应安装包'
                                    : controller.loadError != null
                                    ? '暂时无法读取版本'
                                    : '此版本暂未发布',
                                style: theme.textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                controller.loadError != null
                                    ? '请检查连接后刷新版本。'
                                    : _architecture == null
                                    ? '系统识别不足时，请根据目标设备手动选择，不会自动替换为其他架构。'
                                    : '当前目标：${target.displayLabel}。公司发布对应版本后即可下载。',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                            _DownloadStatus(controller: controller),
                            if (controller.storeOpened)
                              const Padding(
                                padding: EdgeInsets.only(top: 12),
                                child: Text('已打开官方应用商店'),
                              ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: controller.loading || busy
                                    ? null
                                    : controller.load,
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  size: 18,
                                ),
                                label: const Text('刷新版本'),
                              ),
                            ),
                            if (release != null && controller.loadError != null)
                              Text(
                                '版本列表刷新失败，当前显示上次读取的结果。',
                                style: TextStyle(color: colors.error),
                              ),
                            if (release?.releaseNotes.isNotEmpty == true) ...[
                              const Divider(height: 32),
                              Text('本次更新', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 8),
                              Text(
                                release!.releaseNotes,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  height: 1.7,
                                ),
                              ),
                            ],
                          ],
                        );
                        return wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 5, child: content),
                                  const SizedBox(width: 40),
                                  const Expanded(
                                    flex: 3,
                                    child: Padding(
                                      padding: EdgeInsets.only(top: 24),
                                      child: _DesktopArtwork(),
                                    ),
                                  ),
                                ],
                              )
                            : content;
                      },
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text('其他设备与平台', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  for (final platform in SoftwareDownloadPlatform.values.where(
                    (value) => value != _platform,
                  ))
                    _PlatformRow(
                      platform: platform,
                      releases: controller.releases,
                      onChoose: busy ? null : () => _choosePlatform(platform),
                    ),
                  const SizedBox(height: 24),
                  _InstallHelp(target: target),
                  const SizedBox(height: 24),
                  Text(
                    '安装包由公司授权人员发布，下载后自动核对文件大小与完整性。请使用本人账号登录。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HostStrip extends StatelessWidget {
  const _HostStrip({
    required this.host,
    required this.manual,
    required this.onReset,
  });
  final AsyncValue<SoftwareHostInfo> host;
  final bool manual;
  final VoidCallback? onReset;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = host.asData?.value;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.devices_rounded, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                host.isLoading
                    ? '正在识别当前设备…'
                    : info == null
                    ? '暂未识别系统，请手动选择下载目标'
                    : '当前设备：${info.osLabel} · ${softwareArchitectureLabel(info.architecture ?? 'unknown')}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (info?.certaintyExplanation.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    info!.certaintyExplanation,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (manual)
                TextButton(onPressed: onReset, child: const Text('重新使用设备识别结果')),
            ],
          ),
        ),
      ],
    );
  }
}

class _TargetFields extends StatelessWidget {
  const _TargetFields({
    required this.target,
    required this.architecture,
    required this.enabled,
    required this.onVersion,
    required this.onArchitecture,
  });
  final SoftwareDownloadTarget target;
  final String? architecture;
  final bool enabled;
  final void Function(SoftwareWindowsVersion?, String) onVersion;
  final ValueChanged<String> onArchitecture;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final columns =
          bounds.maxWidth >= 560 &&
          MediaQuery.textScalerOf(context).scale(16) <= 24;
      final fields = <Widget>[
        if (target.platform == SoftwareDownloadPlatform.windows)
          UtenDropdownScrollScope(
            nativeDropdown: true,
            child: DropdownButtonFormField<String>(
              key: ValueKey(
                'software-downloads-runtime-${target.windowsVersion?.name ?? target.runtimeFamily}',
              ),
              initialValue: target.windowsVersion?.name ?? target.runtimeFamily,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '目标系统'),
              items: [
                for (final family in [
                  ClientRuntimeFamily.flutter,
                  ClientRuntimeFamily.wpfLegacy,
                ])
                  DropdownMenuItem(
                    value: family,
                    child: Text(windowsRuntimeLabel(family)),
                  ),
                for (final version in SoftwareWindowsVersion.values)
                  DropdownMenuItem(
                    value: version.name,
                    child: Text(version.label),
                  ),
              ],
              onChanged: !enabled
                  ? null
                  : (value) {
                      if (value == null) return;
                      final version = SoftwareWindowsVersion.values
                          .where((v) => v.name == value)
                          .firstOrNull;
                      onVersion(version, version?.runtimeFamily ?? value);
                    },
            ),
          ),
        UtenDropdownScrollScope(
          key: const ValueKey('software-downloads-architecture'),
          nativeDropdown: true,
          child: DropdownButtonFormField<String>(
            key: ValueKey('software-arch-${target.key}'),
            initialValue: architecture,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '目标架构'),
            hint: const Text('请选择架构'),
            items: [
              for (final arch
                  in softwareDownloadArchitectures(
                    target.platform,
                    runtimeFamily: target.runtimeFamily,
                  ).where(
                    (a) =>
                        !(target.windowsVersion ==
                                SoftwareWindowsVersion.windows11 &&
                            a == 'x86'),
                  ))
                DropdownMenuItem(
                  value: arch,
                  child: Text(softwareArchitectureLabel(arch)),
                ),
            ],
            onChanged: !enabled
                ? null
                : (value) {
                    if (value != null) onArchitecture(value);
                  },
          ),
        ),
      ];
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final field in fields)
            SizedBox(
              width: columns ? (bounds.maxWidth - 12) / 2 : bounds.maxWidth,
              child: field,
            ),
        ],
      );
    },
  );
}

class _PlatformRow extends StatelessWidget {
  const _PlatformRow({
    required this.platform,
    required this.releases,
    required this.onChoose,
  });
  final SoftwareDownloadPlatform platform;
  final List<ClientRelease> releases;
  final VoidCallback? onChoose;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = releases.any(
      (r) => r.platform == platform.name && isSoftwareDownloadRelease(r),
    );
    return Container(
      key: ValueKey('software-platform-${platform.name}'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(platform.icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(platform.label, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  available ? '已发布版本，请选择系统架构' : '暂未发布可下载版本',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onChoose, child: const Text('查看版本')),
        ],
      ),
    );
  }
}

class _InstallHelp extends StatelessWidget {
  const _InstallHelp({required this.target});
  final SoftwareDownloadTarget target;
  @override
  Widget build(BuildContext context) {
    final windows = target.platform == SoftwareDownloadPlatform.windows;
    final description = windows
        ? target.runtimeFamily == ClientRuntimeFamily.wpfLegacy
              ? '兼容版适用于 Windows 7 SP1 / 8.1。打开所选架构的 Setup.exe 完成安装，功能范围以对应发布说明为准。'
              : '打开 Setup.exe 完成首次安装。以后在软件内更新，会自动使用原安装位置。'
        : target.platform == SoftwareDownloadPlatform.android
        ? 'APK 请在 Android 设备上按系统提示安装；应用商店版本通过官方商店安装和更新。'
        : '请通过已发布版本的官方应用商店入口安装。尚未发布的平台会显示具体状态。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('安装与后续更新', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Text(
          description,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.7),
        ),
      ],
    );
  }
}

class _DownloadStatus extends StatelessWidget {
  const _DownloadStatus({required this.controller});
  final SoftwareDownloadsController controller;

  @override
  Widget build(BuildContext context) =>
      UtenMotion(duration: UtenAnim.fast, builder: _build);

  Widget _build(BuildContext context, Duration duration) {
    final theme = Theme.of(context);
    final Widget feedback;
    if (controller.downloadingId != null) {
      feedback = Column(
        key: const ValueKey('software-download-progress'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: UtenSpacing.s16),
          Semantics(
            liveRegion: true,
            label: '下载进度 ${(controller.progress * 100).floor()}%',
            child: duration == Duration.zero
                ? LinearProgressIndicator(value: controller.progress)
                : TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: controller.progress),
                    duration: duration,
                    curve: UtenAnim.standard,
                    builder: (context, value, _) =>
                        LinearProgressIndicator(value: value),
                  ),
          ),
          TextButton(
            onPressed: controller.cancelDownload,
            child: const Text('取消下载'),
          ),
        ],
      );
    } else if (controller.downloadError != null) {
      feedback = Padding(
        key: const ValueKey('software-download-error'),
        padding: const EdgeInsets.only(top: UtenSpacing.s16),
        child: Text(
          '下载未完成，请检查网络后重试。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    } else if (controller.savedPath != null) {
      feedback = Padding(
        key: const ValueKey('software-download-saved'),
        padding: const EdgeInsets.only(top: UtenSpacing.s16),
        child: Semantics(
          liveRegion: true,
          child: Text(
            '已校验并保存：${controller.savedPath}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      );
    } else {
      feedback = const SizedBox.shrink(key: ValueKey('software-download-idle'));
    }
    if (duration == Duration.zero) return feedback;
    return AnimatedSize(
      duration: duration,
      curve: UtenAnim.standard,
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: UtenAnim.standard,
        switchOutCurve: UtenAnim.exit,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [
            for (final child in previous)
              ExcludeFocus(
                child: ExcludeSemantics(child: IgnorePointer(child: child)),
              ),
            ?current,
          ],
        ),
        child: feedback,
      ),
    );
  }
}

class _DesktopArtwork extends StatelessWidget {
  const _DesktopArtwork();
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: UtenRadius.cardAll,
              border: Border.all(color: colors.outlineVariant),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 200),
              child: Container(
                padding: const EdgeInsets.all(UtenSpacing.s24),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.window_rounded,
                      size: 42,
                      color: colors.onPrimaryContainer,
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    Text(
                      'UIMP',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      softwareProductName(Localizations.localeOf(context)),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Container(width: 48, height: 24, color: colors.outlineVariant),
          Container(
            width: 120,
            height: 6,
            decoration: BoxDecoration(
              color: colors.outlineVariant,
              borderRadius: UtenRadius.pillAll,
            ),
          ),
        ],
      ),
    );
  }
}
