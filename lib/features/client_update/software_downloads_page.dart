import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/brand/uten_brand_mascot.dart';
import '../../components/inputs/uten_dropdown_scroll_scope.dart';
import '../../components/feedback/uten_motion.dart';
import '../../components/layout/uten_app_bar.dart';
import '../../components/layout/uten_content_container.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/ui/uten_notify.dart';
import '../../core/ui/opportunistic_dialog_coordinator.dart';
import 'client_release.dart';
import 'client_release_access.dart';
import 'client_release_publish_dialog.dart';
import 'software_downloads_controller.dart';
import 'software_downloads_presentation.dart';

class SoftwareDownloadsPage extends ConsumerStatefulWidget {
  const SoftwareDownloadsPage({super.key});

  @override
  ConsumerState<SoftwareDownloadsPage> createState() => _DownloadsState();
}

class _DownloadsState extends ConsumerState<SoftwareDownloadsPage> {
  String _architecture = 'x64';
  DialogOpportunity? _resultOpportunity;

  @override
  void dispose() {
    _resultOpportunity?.interrupt();
    super.dispose();
  }

  Future<void> _download(
    SoftwareDownloadsController controller,
    ClientRelease release,
  ) async {
    if (controller.downloadingId != null || _resultOpportunity != null) return;
    bool current() =>
        mounted &&
        identical(controller, ref.read(softwareDownloadsControllerProvider));
    await controller.download(release);
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
          message: kIsWeb
              ? '安装程序已校验并交给浏览器下载。请从浏览器下载列表找到 Setup.exe，在 Windows 电脑上打开并完成首次安装。以后可在软件内直接更新。'
              : '已校验并保存到：\n$saved\n\n在 Windows 电脑上双击 Setup.exe 完成首次安装。以后在软件内点击“立即更新”，自动使用原安装位置。',
          confirmLabel: '知道了',
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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(softwareDownloadsControllerProvider).load();
    });
  }

  Future<void> _publish(SoftwareDownloadsController controller) async {
    if (ref.read(clientReleasePublisherProvider) == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          const ClientReleasePublishDialog(packageKind: 'installer'),
    );
    if (mounted &&
        identical(controller, ref.read(softwareDownloadsControllerProvider))) {
      await controller.load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(softwareDownloadsControllerProvider);
    final canPublish = ref.watch(clientReleasePublisherProvider) != null;
    final currentPlatform = ref.watch(softwareDevicePlatformProvider);
    ref.listen(softwareDownloadsControllerProvider, (_, next) {
      _resultOpportunity?.interrupt();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            identical(next, ref.read(softwareDownloadsControllerProvider))) {
          next.load();
        }
      });
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: '软件下载',
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
              child: const Text('发布 Windows 版本'),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final release =
              controller.releases
                  .where((item) => item.architecture == _architecture)
                  .firstOrNull ??
              controller.releases.firstOrNull;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s24),
            child: UtenContentContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (currentPlatform != null &&
                      currentPlatform != SoftwareDownloadPlatform.windows) ...[
                    _CurrentUnavailablePlatform(platform: currentPlatform),
                    const SizedBox(height: UtenSpacing.s24),
                  ],
                  _WindowsPanel(
                    key: const ValueKey('software-platform-windows'),
                    controller: controller,
                    release: release,
                    currentDevice:
                        currentPlatform == SoftwareDownloadPlatform.windows,
                    onArchitectureChanged: (value) =>
                        setState(() => _architecture = value),
                    onDownload: (release) =>
                        unawaited(_download(controller, release)),
                  ),
                  const SizedBox(height: UtenSpacing.s24),
                  const _InstallationGuide(),
                  const SizedBox(height: UtenSpacing.s32),
                  _OtherPlatforms(excluded: currentPlatform),
                  const SizedBox(height: UtenSpacing.s24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.verified_user_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Expanded(
                        child: Text(
                          '安装包由公司授权人员发布，下载完成后自动校验完整性。请使用本人账号登录。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
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

class _CurrentUnavailablePlatform extends StatelessWidget {
  const _CurrentUnavailablePlatform({required this.platform});
  final SoftwareDownloadPlatform platform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: ValueKey('software-platform-${platform.name}'),
      padding: const EdgeInsets.all(UtenSpacing.s24),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: UtenRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(platform.icon, size: 28, color: colors.primary),
              Text(platform.label, style: theme.textTheme.titleMedium),
              Text(
                '当前设备',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            softwareProductName(Localizations.localeOf(context)),
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text('暂时无法下载', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _WindowsPanel extends StatelessWidget {
  const _WindowsPanel({
    super.key,
    required this.controller,
    required this.release,
    required this.onArchitectureChanged,
    required this.currentDevice,
    required this.onDownload,
  });
  final SoftwareDownloadsController controller;
  final ClientRelease? release;
  final ValueChanged<String> onArchitectureChanged;
  final bool currentDevice;
  final ValueChanged<ClientRelease> onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final downloading = controller.downloadingId != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: UtenRadius.cardAll,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final roomy =
              bounds.maxWidth >= 800 &&
              MediaQuery.textScalerOf(context).scale(16) <= 24;
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(Icons.window_rounded, size: 24, color: colors.primary),
                  Text('Windows', style: theme.textTheme.titleMedium),
                  if (currentDevice) ...[
                    const SizedBox(width: UtenSpacing.s12),
                    Text(
                      '当前设备',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.primary,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: UtenSpacing.s24),
              Text(
                softwareProductName(Localizations.localeOf(context)),
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '将优腾完整客户端保存到电脑，\n用熟悉的账号继续办公。',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.7,
                ),
              ),
              const SizedBox(height: UtenSpacing.s24),
              if (release != null) ...[
                Wrap(
                  spacing: UtenSpacing.s16,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '版本 ${release!.version}',
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      '${(release!.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (controller.releases.length > 1)
                      UtenDropdownScrollScope(
                        nativeDropdown: true,
                        child: SizedBox(
                          width: (bounds.maxWidth - UtenSpacing.s24 * 2)
                              .clamp(0.0, 260.0)
                              .toDouble(),
                          child: DropdownButton<String>(
                            isExpanded: true,
                            key: const ValueKey(
                              'software-downloads-architecture',
                            ),
                            value: release!.architecture,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final item in controller.releases)
                                DropdownMenuItem(
                                  value: item.architecture,
                                  child: Text(
                                    _architectureLabel(item.architecture),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: downloading
                                ? null
                                : (value) {
                                    if (value != null) {
                                      onArchitectureChanged(value);
                                    }
                                  },
                          ),
                        ),
                      )
                    else
                      Text(
                        _architectureLabel(release!.architecture),
                        style: theme.textTheme.bodyMedium,
                      ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s24),
                UtenButton(
                  key: const ValueKey('software-downloads-windows'),
                  size: UtenButtonSize.large,
                  icon: Icons.download_rounded,
                  isLoading: downloading,
                  onPressed: downloading ? null : () => onDownload(release!),
                  child: Text(
                    downloading
                        ? '正在下载 ${(controller.progress * 100).floor()}%'
                        : '下载 Windows 安装程序',
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  'Setup.exe · 双击安装，后续更新自动使用原安装位置',
                  style: theme.textTheme.bodySmall,
                ),
              ] else if (controller.loading) ...[
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(height: UtenSpacing.s12),
                const Text('正在获取可下载版本'),
              ] else ...[
                Text(
                  controller.loadError != null ? '暂时无法读取版本' : 'Windows 版本正在准备',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  controller.loadError != null
                      ? '请检查连接后重新获取。'
                      : '正式版本发布后，即可在这里下载完整客户端。',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              _DownloadStatus(controller: controller),
              const SizedBox(height: UtenSpacing.s12),
              TextButton.icon(
                onPressed: controller.loading || downloading
                    ? null
                    : controller.load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('刷新版本'),
              ),
              if (release != null && controller.loadError != null)
                Text(
                  '版本列表刷新失败，当前显示上次读取的结果。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                ),
              if (release?.releaseNotes.isNotEmpty == true) ...[
                const Divider(height: UtenSpacing.s32),
                Text('本次更新', style: theme.textTheme.titleSmall),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  release!.releaseNotes,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
                ),
              ],
            ],
          );
          return Padding(
            padding: EdgeInsets.all(roomy ? UtenSpacing.s32 : UtenSpacing.s24),
            child: roomy
                ? Row(
                    children: [
                      Expanded(flex: 5, child: details),
                      const SizedBox(width: UtenSpacing.s32),
                      const Expanded(flex: 3, child: _DesktopArtwork()),
                    ],
                  )
                : details,
          );
        },
      ),
    );
  }

  String _architectureLabel(String architecture) => switch (architecture) {
    'x64' => '64 位 · Intel / AMD',
    'arm64' => 'ARM 64 位',
    'x86' => '32 位',
    _ => architecture,
  };
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
                    const UtenBrandMascot.size(64),
                    const SizedBox(height: UtenSpacing.s16),
                    Text(
                      softwareProductName(Localizations.localeOf(context)),
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
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

class _InstallationGuide extends StatelessWidget {
  const _InstallationGuide();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const steps = [
      ('下载安装程序', '根据电脑架构选择 Windows 版本，等待下载与校验完成。'),
      ('双击完成安装', '打开 Setup.exe，按提示完成首次安装。'),
      ('登录并保持更新', '使用本人账号登录。以后点击“立即更新”，自动下载、替换并重启，无需重新选择路径。'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('从下载到开始工作', style: theme.textTheme.titleLarge),
        const SizedBox(height: UtenSpacing.s16),
        LayoutBuilder(
          builder: (context, bounds) {
            final columns =
                bounds.maxWidth >= 840 &&
                MediaQuery.textScalerOf(context).scale(16) <= 24;
            final children = [
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s16,
                    right: UtenSpacing.s16,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: theme.colorScheme.surfaceContainerHigh,
                        child: Text(
                          '${i + 1}',
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              steps[i].$1,
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: UtenSpacing.s8),
                            Text(
                              steps[i].$2,
                              style: theme.textTheme.bodySmall?.copyWith(
                                height: 1.7,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ];
            return columns
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final child in children) Expanded(child: child),
                    ],
                  )
                : Column(children: children);
          },
        ),
      ],
    );
  }
}

class _OtherPlatforms extends StatelessWidget {
  const _OtherPlatforms({this.excluded});
  final SoftwareDownloadPlatform? excluded;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final platforms = SoftwareDownloadPlatform.values
        .where(
          (platform) =>
              platform != SoftwareDownloadPlatform.windows &&
              platform != excluded,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('其他平台', style: theme.textTheme.titleLarge),
        const SizedBox(height: UtenSpacing.s16),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: colors.outlineVariant),
            borderRadius: UtenRadius.cardAll,
          ),
          child: LayoutBuilder(
            builder: (context, bounds) {
              final horizontal =
                  bounds.maxWidth >= 720 &&
                  MediaQuery.textScalerOf(context).scale(16) <= 24;
              final tiles = [
                for (final platform in platforms)
                  Padding(
                    key: ValueKey('software-platform-${platform.name}'),
                    padding: const EdgeInsets.all(UtenSpacing.s20),
                    child: Row(
                      children: [
                        Icon(
                          platform.icon,
                          color: colors.onSurfaceVariant,
                          size: 26,
                        ),
                        const SizedBox(width: UtenSpacing.s16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                platform.label,
                                style: theme.textTheme.titleMedium,
                              ),
                              const SizedBox(height: UtenSpacing.s4),
                              Text('暂时无法下载', style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.lock_outline_rounded,
                          color: colors.onSurfaceVariant,
                          size: 16,
                        ),
                      ],
                    ),
                  ),
              ];
              return horizontal
                  ? Row(
                      children: [
                        for (final tile in tiles) Expanded(child: tile),
                      ],
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < tiles.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          tiles[i],
                        ],
                      ],
                    );
            },
          ),
        ),
      ],
    );
  }
}
