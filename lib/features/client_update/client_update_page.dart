import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../components/buttons/uten_back_button.dart';
import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_motion.dart';
import '../../core/constants/app_info.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_tokens.dart';
import 'client_update_controller.dart';

Future<void> openClientUpdatePage(
  BuildContext context,
  ClientUpdateController controller,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/settings/software-update'),
    builder: (_) => ClientUpdatePage(controller: controller),
  );
  void ownerChanged() {
    if (route.isActive) navigator.removeRoute(route);
  }

  controller.addOwnerDisposedListener(ownerChanged);
  try {
    await navigator.push(route);
  } finally {
    controller.removeOwnerDisposedListener(ownerChanged);
  }
}

/// The page owns one check per visit; all callers share this lifecycle.
class ClientUpdatePage extends StatefulWidget {
  const ClientUpdatePage({super.key, required this.controller});
  final ClientUpdateController controller;
  @override
  State<ClientUpdatePage> createState() => _ClientUpdatePageState();
}

class _ClientUpdatePageState extends State<ClientUpdatePage> {
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final checking =
          _entering || controller.stage == ClientUpdateStage.checking;
      final failed = !checking && controller.error != null;
      final transferring = controller.transferBusy;
      final opened = controller.stage == ClientUpdateStage.installerOpened;
      final candidate = controller.release;
      final available = candidate != null && !checking && !failed;
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
      final title = checking
          ? l10n.clientUpdateChecking
          : failed
          ? (chinese ? '暂时无法检查更新' : 'Could not check for updates')
          : controller.stage == ClientUpdateStage.downloading
          ? l10n.clientUpdateDownloading
          : controller.stage == ClientUpdateStage.installing || opened
          ? l10n.clientUpdateInstalling
          : available
          ? l10n.clientUpdateNewTitle
          : unsupported
          ? (chinese
                ? '此安装版本暂不支持更新'
                : 'Updates are unavailable for this installation')
          : controller.hasSuccessfulCheck
          ? l10n.clientUpdateUpToDate
          : (chinese ? '准备检查新版本' : 'Ready to check for updates');
      final detail = checking
          ? (chinese
                ? '正在与更新服务核对可用版本…'
                : 'Looking for an update for this device…')
          : failed
          ? (chinese
                ? '请检查网络连接后重试，当前软件可以继续使用。'
                : 'Check your connection and try again. You can keep using the app.')
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
      return PopScope(
        canPop: !transferring,
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: 72,
            title: Text(l10n.clientUpdateTitle),
            titleSpacing: UtenSpacing.s4,
            leadingWidth: UtenBackButton.slotWidth(context) + UtenSpacing.s40,
            leading: Padding(
              padding: const EdgeInsetsDirectional.only(
                start: UtenSpacing.s24,
                end: UtenSpacing.s16,
              ),
              child: UtenBackButton(
                key: const ValueKey('client-update-back'),
                onPressed: () {
                  if (!controller.transferBusy) {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
            ),
          ),
          body: LayoutBuilder(
            builder: (context, viewport) {
              final compact = viewport.maxWidth < 600;
              final inset = compact ? UtenSpacing.s16 : UtenSpacing.s32;
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  UtenSpacing.s24,
                  inset,
                  UtenSpacing.s32,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 760,
                      minHeight: math.max(
                        0,
                        viewport.maxHeight - UtenSpacing.s24 - UtenSpacing.s32,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerLowest,
                            borderRadius: UtenRadius.xxlAll,
                            border: Border.all(color: colors.outlineVariant),
                          ),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: compact
                                  ? UtenSpacing.s24
                                  : UtenSpacing.s40,
                              vertical: compact
                                  ? UtenSpacing.s32
                                  : UtenSpacing.s40,
                            ),
                            child: Column(
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
                                const SizedBox(height: UtenSpacing.s24),
                                Text(
                                  AppInfo.displayName,
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: UtenSpacing.s16),
                                Semantics(
                                  liveRegion: true,
                                  header: true,
                                  child: Text(
                                    title,
                                    key: const ValueKey('client-update-status'),
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                                Text(
                                  '${l10n.clientUpdateCurrent} ${installed?.currentVersion ?? AppInfo.version}',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                                if (available) ...[
                                  const SizedBox(height: UtenSpacing.s8),
                                  Text(
                                    '${l10n.clientUpdateLatest} ${candidate.version}',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      color: colors.primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (candidate.sizeBytes > 0) ...[
                                    const SizedBox(height: UtenSpacing.s4),
                                    Text(
                                      '${(candidate.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ],
                                const SizedBox(height: UtenSpacing.s16),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 540,
                                  ),
                                  child: Text(
                                    detail,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.onSurfaceVariant,
                                      height: 1.7,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s24),
                                if (available && supported)
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minWidth: 190,
                                    ),
                                    child: UtenButton(
                                      key: const ValueKey('client-update-now'),
                                      icon: Icons.download_rounded,
                                      size: UtenButtonSize.large,
                                      isLoading: transferring,
                                      onPressed: controller.busy || opened
                                          ? null
                                          : controller.update,
                                      child: Text(l10n.clientUpdateNow),
                                    ),
                                  ),
                                if (transferring) ...[
                                  const SizedBox(height: UtenSpacing.s16),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 420,
                                    ),
                                    child: LinearProgressIndicator(
                                      value:
                                          controller.stage ==
                                              ClientUpdateStage.downloading
                                          ? controller.progress
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: UtenSpacing.s8),
                                  Text(
                                    controller.stage ==
                                            ClientUpdateStage.downloading
                                        ? '${(controller.progress * 100).floor()}%'
                                        : l10n.clientUpdateInstalling,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                                if (!transferring && !opened) ...[
                                  if (available && supported)
                                    const SizedBox(height: UtenSpacing.s12),
                                  UtenButton(
                                    key: const ValueKey('client-update-check'),
                                    type: available
                                        ? UtenButtonType.ghost
                                        : UtenButtonType.secondary,
                                    icon: checking
                                        ? Icons.sync_rounded
                                        : Icons.refresh_rounded,
                                    onPressed: checking
                                        ? null
                                        : () => controller.check(),
                                    child: Text(l10n.clientUpdateCheck),
                                  ),
                                ],
                                if (controller.lastCheckedAt != null &&
                                    !checking &&
                                    !failed) ...[
                                  const SizedBox(height: UtenSpacing.s16),
                                  Text(
                                    chinese ? '刚刚完成检查' : 'Checked just now',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        if (available) ...[
                          const SizedBox(height: UtenSpacing.s24),
                          Padding(
                            key: const ValueKey('client-update-notes'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: UtenSpacing.s8,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.clientUpdateNotes,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                                Text(
                                  candidate.releaseNotes.isNotEmpty
                                      ? candidate.releaseNotes
                                      : l10n.clientUpdateNoNotes,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    height: 1.8,
                                  ),
                                ),
                              ],
                            ),
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
      width: 156,
      height: 156,
      child: Stack(
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.06),
            ),
            child: const SizedBox(width: 156, height: 156),
          ),
          Positioned.fill(
            child: RotationTransition(
              turns: _rotation,
              child: CustomPaint(
                painter: _UpdateRing(
                  accent: accent,
                  track: colors.outlineVariant,
                  progress: widget.progress ?? (widget.spinning ? 0.23 : 1),
                ),
              ),
            ),
          ),
          Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: UtenRadius.cardAll,
            ),
            child: Icon(
              Icons.system_update_alt_rounded,
              size: 54,
              color: colors.onPrimaryContainer,
            ),
          ),
          if (!widget.spinning && widget.progress == null)
            Positioned(
              right: 7,
              bottom: 9,
              child: Container(
                padding: const EdgeInsets.all(UtenSpacing.s8),
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
                  size: 22,
                  color: accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UpdateRing extends CustomPainter {
  const _UpdateRing({
    required this.accent,
    required this.track,
    required this.progress,
  });
  final Color accent, track;
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect, pen..color = track);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * progress.clamp(0, 1),
      false,
      pen..color = accent,
    );
  }

  @override
  bool shouldRepaint(covariant _UpdateRing oldDelegate) =>
      accent != oldDelegate.accent ||
      track != oldDelegate.track ||
      progress != oldDelegate.progress;
}
