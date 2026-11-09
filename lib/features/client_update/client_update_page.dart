import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../components/buttons/uten_back_button.dart';
import '../../components/feedback/uten_progress_dialog.dart';
import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_motion.dart';
import '../../core/constants/app_info.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../../core/web_update/web_update_safety.dart';
import 'client_update_controller.dart';
import 'client_auto_update_preferences.dart';
import '../../shared/platform_branding/platform_branding_provider.dart';

Future<void> openClientUpdatePage(
  BuildContext context,
  ClientUpdateController controller,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  late final MaterialPageRoute<void> route;
  route = MaterialPageRoute<void>(
    settings: const RouteSettings(name: RouteName.clientUpdate),
    builder: (_) => ClientUpdatePage(
      controller: controller,
      onClose: () {
        if (navigator.mounted && route.isCurrent) navigator.pop();
      },
    ),
  );
  void ownerChanged() {
    if (navigator.mounted && route.isActive) navigator.removeRoute(route);
  }

  controller.addOwnerDisposedListener(ownerChanged);
  try {
    await navigator.push(route);
  } finally {
    controller.removeOwnerDisposedListener(ownerChanged);
  }
}

/// The page owns one check per visit; all callers share this lifecycle.
class ClientUpdatePage extends ConsumerStatefulWidget {
  const ClientUpdatePage({super.key, required this.controller, this.onClose});
  final ClientUpdateController controller;
  final VoidCallback? onClose;
  @override
  ConsumerState<ClientUpdatePage> createState() => _ClientUpdatePageState();
}

class _ClientUpdatePageState extends ConsumerState<ClientUpdatePage> {
  bool _entering = true;
  @override
  void initState() {
    super.initState();
    _scheduleVisitCheck();
  }

  @override
  void didUpdateWidget(covariant ClientUpdatePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _entering = true;
      _scheduleVisitCheck();
    }
  }

  void _scheduleVisitCheck() {
    final owner = widget.controller;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !identical(widget.controller, owner) ||
          owner.isDisposed) {
        return;
      }
      if (!owner.busy) await owner.check();
      if (mounted && identical(widget.controller, owner)) {
        setState(() => _entering = false);
      }
    });
  }

  String _installWaitMessage(BuildContext context) {
    final snapshot = webUpdateSafety.snapshot;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    if (snapshot.dirty) {
      return chinese
          ? '更新已下载。请返回保存正在编辑的内容，再点击“立即更新”。'
          : 'The update is downloaded. Go back and save your work, then select Update now.';
    }
    if (snapshot.busy) {
      return chinese
          ? '更新已下载。请等待当前操作完成，再点击“立即更新”。'
          : 'The update is downloaded. Wait for the current operation to finish, then select Update now.';
    }
    if (!snapshot.ready || snapshot.blocked) {
      return chinese
          ? '更新已下载。请返回处理未完成的操作并关闭弹窗，再从设置页继续更新。'
          : 'The update is downloaded. Go back, resolve unfinished operations and close dialogs, then update from Settings.';
    }
    return chinese
        ? '更新已下载，可以点击“立即更新”继续安装。'
        : 'The update is downloaded. Select Update now to install it.';
  }

  Future<void> _update() async {
    final owner = widget.controller;
    await owner.update();
    if (!mounted || !identical(widget.controller, owner) || owner.isDisposed) {
      return;
    }
    if (owner.waitingForSafeInstall) {
      context.appWarning(_installWaitMessage(context));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, webUpdateSafety]),
    builder: (context, _) {
      final controller = widget.controller;
      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final branding = ref.watch(platformBrandingSnapshotProvider);
      final autoUpdate = ref.watch(clientAutoUpdateEnabledProvider);
      final colors = theme.colorScheme;
      final checking =
          _entering || controller.stage == ClientUpdateStage.checking;
      final failed = !checking && controller.error != null;
      final transferring = controller.transferBusy;
      final opened = controller.stage == ClientUpdateStage.installerOpened;
      final candidate = controller.release;
      final available = candidate != null && !checking;
      final installed = controller.installed;
      final supported =
          candidate?.installMode == 'store' ||
          installed?.supportsInPlaceUpdate == true;
      final unsupported =
          !checking &&
          installed != null &&
          !supported &&
          !{'ios', 'macos'}.contains(installed.platform);
      final chinese = Localizations.localeOf(context).languageCode == 'zh';
      final language = Localizations.localeOf(context).languageCode;
      final title = checking
          ? l10n.clientUpdateChecking
          : failed
          ? (candidate == null
                ? (chinese ? '暂时无法检查更新' : 'Could not check for updates')
                : (chinese ? '更新未完成' : 'Update could not finish'))
          : controller.stage == ClientUpdateStage.downloading
          ? l10n.clientUpdateDownloading
          : controller.stage == ClientUpdateStage.installing || opened
          ? l10n.clientUpdateInstalling
          : available
          ? switch (language) {
              'zh' => '有新的版本（${candidate.version}）',
              'ko' => '새 버전이 있습니다 (${candidate.version})',
              _ => 'A new version is available (${candidate.version})',
            }
          : unsupported
          ? (chinese
                ? '此安装版本暂不支持更新'
                : 'Updates are unavailable for this installation')
          : controller.hasSuccessfulCheck
          ? l10n.clientUpdateUpToDate
          : (chinese ? '准备检查新版本' : 'Ready to check for updates');
      final platformDetail = checking
          ? (chinese
                ? '正在与更新服务核对可用版本…'
                : 'Looking for an update for this device…')
          : failed
          ? _failureMessage(context)
          : unsupported
          ? l10n.clientUpdateUnsupported
          : available || transferring || opened
          ? candidate?.installMode == 'store'
                ? l10n.clientUpdateStoreHint
                : installed?.platform == 'android'
                ? l10n.clientUpdateAndroidHint
                : l10n.clientUpdateWindowsHint
          : (chinese
                ? '你的 UTEN 已准备好，继续安心工作。'
                : 'UTEN is ready. You are all set to continue working.');
      final detail = available && !transferring && !opened && !failed
          ? '${switch (language) {
              'zh' => '建议立即更新。',
              'ko' => '지금 업데이트하는 것을 권장합니다. ',
              _ => 'We recommend updating now. ',
            }}$platformDetail'
          : platformDetail;
      final canUpdate = available && supported;
      final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
        color: colors.onSurfaceVariant,
        height: 1.7,
      );
      final mainPanel = _UpdatePanel(
        key: const ValueKey('client-update-main-panel'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              header: true,
              child: Text(
                title,
                key: const ValueKey('client-update-status'),
                style: theme.textTheme.headlineLarge,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(detail, style: bodyStyle),
            const SizedBox(height: UtenSpacing.s32),
            LayoutBuilder(
              builder: (context, constraints) {
                final stack =
                    constraints.maxWidth < 380 ||
                    MediaQuery.textScalerOf(context).scale(16) > 22;
                final current = _VersionDetail(
                  label: l10n.clientUpdateCurrent,
                  version: installed?.currentVersion ?? AppInfo.version,
                  detail: installed == null
                      ? null
                      : (chinese ? '构建号 ' : 'Build ') +
                            installed.currentBuild.toString(),
                );
                final latest = _VersionDetail(
                  label: l10n.clientUpdateLatest,
                  version:
                      candidate?.version ??
                      (controller.hasSuccessfulCheck
                          ? installed?.currentVersion ?? AppInfo.version
                          : (chinese ? '尚未获取' : 'Not checked')),
                  highlighted: available,
                  detail: candidate == null
                      ? null
                      : [
                          (chinese ? '构建号 ' : 'Build ') +
                              candidate.buildNumber.toString(),
                          if (candidate.sizeBytes > 0)
                            '${(candidate.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                        ].join(' / '),
                );
                return Container(
                  key: const ValueKey('client-update-version-comparison'),
                  padding: const EdgeInsets.all(UtenSpacing.s20),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: UtenRadius.lgAll,
                  ),
                  child: stack
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            current,
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: UtenSpacing.s16,
                              ),
                              child: Divider(height: 1),
                            ),
                            latest,
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: current),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: UtenSpacing.s16,
                              ),
                              child: Icon(
                                Icons.arrow_forward_rounded,
                                size: 20,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            Expanded(child: latest),
                          ],
                        ),
                );
              },
            ),
            if (controller.waitingForSafeInstall) ...[
              const SizedBox(height: UtenSpacing.s20),
              _UpdateMessage(
                messageKey: const ValueKey('client-update-install-wait'),
                text: _installWaitMessage(context),
                icon: Icons.pause_circle_outline_rounded,
              ),
            ] else if (controller.hasStagedUpdate &&
                !transferring &&
                !opened &&
                !failed) ...[
              const SizedBox(height: UtenSpacing.s20),
              _UpdateMessage(
                messageKey: const ValueKey('client-update-package-ready'),
                text: chinese
                    ? '更新包已下载，点击“立即更新”即可安装。'
                    : 'The update is downloaded. Select Update now to install.',
                icon: Icons.check_circle_outline_rounded,
              ),
            ],
            if (transferring || opened) ...[
              const SizedBox(height: UtenSpacing.s24),
              Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      controller.stage == ClientUpdateStage.downloading
                          ? '${l10n.clientUpdateDownloading}  ${(controller.progress * 100).floor()}%'
                          : l10n.clientUpdateInstalling,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    LinearProgressIndicator(
                      value: controller.stage == ClientUpdateStage.downloading
                          ? controller.progress
                          : null,
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      controller.stage == ClientUpdateStage.downloading &&
                              !controller.blocksNavigation
                          ? (chinese
                                ? '正在后台下载，你可以继续工作。'
                                : 'Downloading in the background. You can keep working.')
                          : (chinese
                                ? '请保持软件打开，正在准备安装并重新启动。'
                                : 'Keep the app open while the update prepares to install and restart.'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s24),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (canUpdate)
                  UtenButton(
                    key: const ValueKey('client-update-now'),
                    icon: controller.hasStagedUpdate
                        ? Icons.restart_alt_rounded
                        : Icons.download_rounded,
                    size: UtenButtonSize.large,
                    isLoading: transferring,
                    onPressed: controller.busy || opened ? null : _update,
                    child: Text(
                      failed ? l10n.clientUpdateRetry : l10n.clientUpdateNow,
                    ),
                  ),
                if (!transferring && !opened)
                  UtenButton(
                    key: const ValueKey('client-update-check'),
                    type: canUpdate
                        ? UtenButtonType.ghost
                        : UtenButtonType.secondary,
                    icon: checking ? Icons.sync_rounded : Icons.refresh_rounded,
                    onPressed: checking ? null : () => controller.check(),
                    child: Text(l10n.clientUpdateCheck),
                  ),
              ],
            ),
            if (controller.lastCheckedAt != null && !checking && !failed) ...[
              const SizedBox(height: UtenSpacing.s16),
              Text(
                _lastCheckLabel(context, controller.lastCheckedAt!),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      );
      final supporting = Column(
        key: const ValueKey('client-update-supporting'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (available) ...[
            Padding(
              key: const ValueKey('client-update-notes'),
              padding: const EdgeInsets.only(bottom: UtenSpacing.s24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.clientUpdateNotes,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  SelectableText(
                    candidate.releaseNotes.trim().isNotEmpty
                        ? candidate.releaseNotes
                        : l10n.clientUpdateNoNotes,
                    style: bodyStyle,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: UtenSpacing.s24),
          ],
          Text(
            chinese ? '更新设置' : 'Update preferences',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: UtenSpacing.s12),
          CheckboxListTile.adaptive(
            key: const ValueKey('client-update-auto-idle'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              chinese ? '软件空闲时自动更新' : 'Update automatically when idle',
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Text(
                chinese
                    ? '自动下载新版本。保存工作并空闲 5 分钟后，显示 10 秒倒计时并安装；有未保存内容或操作待确认时继续等待。'
                    : 'Downloads new versions automatically. After work is saved and 5 idle minutes, a 10-second countdown appears before installation. Waits for unsaved work and unresolved operations.',
                style: bodyStyle,
              ),
            ),
            value: autoUpdate,
            onChanged: opened ? null : _setAutoUpdate,
          ),
          const SizedBox(height: UtenSpacing.s24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.shield_outlined,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  chinese
                      ? '更新会重新启动软件，保留本机设置和已保存的草稿。请先保存当前工作。'
                      : 'Updates restart the app and keep local settings and saved drafts. Save your work first.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      );
      return PopScope(
        canPop: !controller.blocksNavigation,
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: 72,
            title: Text(l10n.clientUpdateTitle),
            titleSpacing: UtenBackButton.titleGap,
            leadingWidth: UtenBackButton.slotWidth(context) + UtenSpacing.s24,
            leading: Padding(
              padding: const EdgeInsetsDirectional.only(start: UtenSpacing.s24),
              child: UtenBackButton(
                key: const ValueKey('client-update-back'),
                enabled: !controller.blocksNavigation,
                onPressed: () {
                  if (controller.blocksNavigation) return;
                  final close = widget.onClose;
                  if (close != null) {
                    close();
                  } else {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
            ),
          ),
          body: LayoutBuilder(
            builder: (context, viewport) {
              final compact = viewport.maxWidth < 600;
              final wide =
                  viewport.maxWidth >= 1080 &&
                  MediaQuery.textScalerOf(context).scale(16) <= 24;
              final inset = compact ? UtenSpacing.s16 : UtenSpacing.s40;
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  UtenSpacing.s32,
                  inset,
                  UtenSpacing.s40,
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    key: const ValueKey('client-update-workspace'),
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            UtenMotion(
                              duration: UtenAnim.slow * 3,
                              builder: (context, duration) => _UpdateMark(
                                key: const ValueKey('client-update-visual'),
                                spinning:
                                    checking ||
                                    controller.stage ==
                                        ClientUpdateStage.installing,
                                motion: duration != Duration.zero,
                                duration: duration,
                                failed: failed,
                                current:
                                    !available &&
                                    !unsupported &&
                                    controller.hasSuccessfulCheck &&
                                    !checking,
                                progress:
                                    controller.stage ==
                                        ClientUpdateStage.downloading
                                    ? controller.progress
                                    : null,
                              ),
                            ),
                            const SizedBox(width: UtenSpacing.s20),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    branding.platformName,
                                    style: theme.textTheme.headlineMedium,
                                  ),
                                  const SizedBox(height: UtenSpacing.s4),
                                  Text(
                                    branding.companyName,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  if (installed != null)
                                    Text(
                                      '${installed.platform == 'windows' ? 'Windows' : installed.platform} ${installed.architecture}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: UtenSpacing.s32),
                        if (wide)
                          Row(
                            key: const ValueKey('client-update-wide-layout'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 7, child: mainPanel),
                              const SizedBox(width: UtenSpacing.s40),
                              Expanded(
                                flex: 5,
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    top: UtenSpacing.s24,
                                  ),
                                  child: supporting,
                                ),
                              ),
                            ],
                          )
                        else ...[
                          mainPanel,
                          const SizedBox(height: UtenSpacing.s32),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: UtenSpacing.s8,
                            ),
                            child: supporting,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );

  Future<void> _setAutoUpdate(bool? value) async {
    if (value == null) return;
    try {
      await ref
          .read(clientAutoUpdateEnabledProvider.notifier)
          .setEnabled(value);
    } catch (_) {
      if (mounted) {
        final chinese = Localizations.localeOf(context).languageCode == 'zh';
        context.appWarning(
          chinese
              ? '自动更新设置未保存，请重试'
              : 'Could not save the update setting. Try again.',
        );
      }
    }
  }

  String _lastCheckLabel(BuildContext context, DateTime time) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final formatted = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(time),
      alwaysUse24HourFormat: true,
    );
    return chinese ? '上次检查 $formatted' : 'Last checked $formatted';
  }

  String _failureMessage(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final failure = widget.controller.error;
    if (failure is FormatException) {
      return chinese
          ? '更新包不完整或校验失败。点击“重试”重新下载。'
          : 'The update package is incomplete or could not be verified. Retry to download it again.';
    }
    if (failure is PlatformException) {
      return switch (failure.code) {
        'INSTALL_DIRECTORY_READ_ONLY' =>
          chinese
              ? '软件安装目录不可写。请联系管理员检查目录权限后重试。'
              : 'The installation folder is read-only. Ask your administrator to check its permissions, then retry.',
        'UPDATE_HASH_MISMATCH' ||
        'INVALID_UPDATE_SIZE' ||
        'UNSAFE_UPDATE_PATH' =>
          chinese
              ? '更新包校验失败。请重新检查更新后重试。'
              : 'The update package could not be verified. Check for updates and retry.',
        'UPDATE_START_FAILED' =>
          chinese
              ? '更新程序未能启动。请重试；若仍失败，可从设置中打开运行日志目录查看更新日志。'
              : 'The updater could not start. Retry, or open the diagnostic logs from Settings.',
        _ =>
          chinese
              ? '安装未完成，请重试。可从设置中打开运行日志目录查看原因。'
              : 'Installation did not finish. Retry or open the diagnostic logs from Settings.',
      };
    }
    return chinese
        ? '更新未完成。请检查网络连接后重试，当前软件可以继续使用。'
        : 'The update did not finish. Check your connection and retry. You can keep using the app.';
  }
}

class _UpdatePanel extends StatelessWidget {
  const _UpdatePanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(
      MediaQuery.sizeOf(context).width < 600
          ? UtenSpacing.s24
          : UtenSpacing.s32,
    ),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: UtenRadius.cardAll,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: child,
  );
}

class _VersionDetail extends StatelessWidget {
  const _VersionDetail({
    required this.label,
    required this.version,
    this.detail,
    this.highlighted = false,
  });
  final String label, version;
  final String? detail;
  final bool highlighted;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          version,
          style: theme.textTheme.headlineLarge?.copyWith(
            color: highlighted ? theme.colorScheme.primary : null,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          Text(detail!, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _UpdateMessage extends StatelessWidget {
  const _UpdateMessage({
    required this.messageKey,
    required this.text,
    required this.icon,
  });
  final Key messageKey;
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              text,
              key: messageKey,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdateMark extends StatefulWidget {
  const _UpdateMark({
    super.key,
    required this.spinning,
    required this.motion,
    required this.duration,
    required this.failed,
    required this.current,
    this.progress,
  });
  final bool spinning, motion, failed, current;
  final Duration duration;
  final double? progress;
  @override
  State<_UpdateMark> createState() => _UpdateMarkState();
}

class _UpdateMarkState extends State<_UpdateMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation;
  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(vsync: this, duration: UtenAnim.slow * 3);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _UpdateMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.spinning && widget.motion) {
      if (!_rotation.isAnimating) _rotation.repeat(period: widget.duration);
    } else {
      _rotation.stop();
      _rotation.value = 0;
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = widget.failed ? colors.error : colors.primary;
    return SizedBox(
      width: 80,
      height: 80,
      child: Stack(
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.06),
            ),
            child: const SizedBox(width: 80, height: 80),
          ),
          Positioned.fill(
            child: RotationTransition(
              turns: _rotation,
              // 2026-11-09 起圆环换全项目唯一组件 UtenProgressRing, 样式
              // 来源统一在组件文件维护。
              child: UtenProgressRing(
                accent: accent,
                track: colors.outlineVariant,
                progress: widget.progress ?? (widget.spinning ? 0.23 : 1),
              ),
            ),
          ),
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: UtenRadius.cardAll,
            ),
            child: Icon(
              Icons.system_update_alt_rounded,
              size: 28,
              color: colors.onPrimaryContainer,
            ),
          ),
          if (!widget.spinning && widget.progress == null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(UtenSpacing.s4),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Icon(
                  widget.failed
                      ? Icons.error_outline_rounded
                      : widget.current
                      ? Icons.check_rounded
                      : Icons.download_rounded,
                  size: 14,
                  color: accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
