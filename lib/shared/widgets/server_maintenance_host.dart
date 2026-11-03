import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/constants/assets.dart';
import '../../core/l10n/maintenance_text.dart';
import '../../core/maintenance/server_maintenance.dart';
import '../../core/performance/performance_tier.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/utils/display_datetime.dart';
import '../../core/web_update/web_update_bridge.dart';
import '../providers/app_visibility_provider.dart';
import '../providers/performance_provider.dart';

/// Covers login, business routes and native clients through the same status.
class ServerMaintenanceHost extends ConsumerWidget {
  const ServerMaintenanceHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ServerMaintenanceView(
    controller: ref.watch(serverMaintenanceControllerProvider),
    visible: ref.watch(appVisibilityProvider),
    animateCountdown: !ref.watch(performanceProvider).isLite,
    child: child,
  );
}

/// Keeps the routed child mounted, including editors and unknown submissions.
/// The host only displays state; it never reloads, signs out, or replays writes.
class ServerMaintenanceView extends StatefulWidget {
  const ServerMaintenanceView({
    super.key,
    required this.controller,
    required this.child,
    this.visible = true,
    this.animateCountdown = true,
  });

  final ServerMaintenanceController controller;
  final Widget child;
  final bool visible;
  final bool animateCountdown;

  @override
  State<ServerMaintenanceView> createState() => _ServerMaintenanceViewState();
}

class _ServerMaintenanceViewState extends State<ServerMaintenanceView> {
  final _acknowledged = <String>{};
  final _reminderFocus = FocusScopeNode();
  final _pageFocus = FocusScopeNode();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.setVisible(widget.visible);
    });
  }

  @override
  void didUpdateWidget(covariant ServerMaintenanceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller
        ..removeListener(_changed)
        ..setVisible(false);
      widget.controller.addListener(_changed);
      _acknowledged.clear();
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.visible != widget.visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.controller.setVisible(widget.visible);
          _changed();
        }
      });
    }
  }

  void _changed() {
    if (!mounted) return;
    final snapshot = widget.controller.snapshot;
    if (!widget.controller.checking &&
        !widget.controller.lastCheckFailed &&
        snapshot != null) {
      publishWebServerMaintenance(switch (snapshot.phase) {
        ServerMaintenancePhase.available => 'available',
        ServerMaintenancePhase.scheduled => 'scheduled',
        ServerMaintenancePhase.updating => 'updating',
        ServerMaintenancePhase.recoveryRequired => 'recovery_required',
      }, snapshot.noticeKey);
    }
    _ticker?.cancel();
    if (widget.visible &&
        widget.controller.snapshot?.phase == ServerMaintenancePhase.scheduled) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.controller.removeListener(_changed);
    _reminderFocus.dispose();
    _pageFocus.dispose();
    // The provider owns the controller. A provider rebuild may already have
    // disposed it before this widget is removed; no mutation is needed here.
    super.dispose();
  }

  void _acknowledge() {
    final snapshot = widget.controller.snapshot;
    if (snapshot != null) {
      setState(() => _acknowledged.add(snapshot.noticeKey));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    final blocksWork = snapshot?.blocksWork == true;
    final warns = controller.shouldWarn;
    final showReminder = warns && !_acknowledged.contains(snapshot!.noticeKey);
    final modal = blocksWork || showReminder;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: modal,
          child: ExcludeSemantics(
            excluding: modal,
            child: AbsorbPointer(absorbing: modal, child: widget.child),
          ),
        ),
        if (warns)
          Positioned.fill(
            child: ExcludeFocus(
              excluding: showReminder || !widget.visible,
              child: TickerMode(
                enabled: widget.visible && !showReminder,
                // Retain the chosen position while the details are open.
                child: Offstage(
                  offstage: showReminder,
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.viewInsetsOf(context).bottom,
                    ),
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s16),
                        child: _MaintenanceCountdown(
                          remaining: controller.remaining,
                          animate: widget.animateCountdown,
                          onTap: () => setState(
                            () => _acknowledged.remove(snapshot!.noticeKey),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (showReminder) ...[
          ModalBarrier(
            dismissible: false,
            color: scheme.scrim.withValues(alpha: 0.36),
          ),
          Center(
            child: FocusScope(
              autofocus: true,
              node: _reminderFocus,
              child: Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    _acknowledge();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Semantics(
                  scopesRoute: true,
                  namesRoute: true,
                  explicitChildNodes: true,
                  label: maintenanceText(context, '服务器即将更新'),
                  child: UtenAlertDialog(
                    key: const ValueKey('server-maintenance-reminder'),
                    maxWidth: 520,
                    title: UtenDialogHeading(
                      title: Text(maintenanceText(context, '服务器即将更新')),
                      icon: Icons.schedule_rounded,
                    ),
                    content: _ScheduledContent(
                      snapshot: snapshot,
                      remaining: controller.remaining,
                    ),
                    actions: [
                      UtenButton(
                        onPressed: _acknowledge,
                        child: Text(maintenanceText(context, '我知道了，继续保存工作')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        if (blocksWork)
          Positioned.fill(
            child: FocusScope(
              autofocus: true,
              node: _pageFocus,
              child: ServerMaintenancePage(
                snapshot: snapshot!,
                checking: controller.checking,
                statusUnavailable: controller.lastCheckFailed,
                onCheck: controller.checkNow,
              ),
            ),
          ),
      ],
    );
  }
}

String _countdown(Duration? duration) {
  if (duration == null || duration.isNegative) return '00:00';
  final seconds = duration.inSeconds;
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// A status capsule, rather than an editor window: no modal surface, resize
/// controls or focus changes when dragged. The root host covers every route.
class _MaintenanceCountdown extends StatefulWidget {
  const _MaintenanceCountdown({
    required this.remaining,
    required this.animate,
    required this.onTap,
  });

  final Duration? remaining;
  final bool animate;
  final VoidCallback onTap;

  @override
  State<_MaintenanceCountdown> createState() => _MaintenanceCountdownState();
}

class _MaintenanceCountdownState extends State<_MaintenanceCountdown>
    with SingleTickerProviderStateMixin {
  final _areaKey = GlobalKey();
  final _capsuleKey = GlobalKey();
  Offset? _position;
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  bool get _urgent =>
      widget.remaining != null &&
      widget.remaining! < const Duration(minutes: 1);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _MaintenanceCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    final animate =
        _urgent &&
        widget.animate &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (animate && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!animate) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  void _startDrag(DragStartDetails details) {
    final area = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    final capsule =
        _capsuleKey.currentContext?.findRenderObject() as RenderBox?;
    if (area == null || capsule == null) return;
    // Seed from the laid-out position after any resize or text-size change.
    _position = capsule.localToGlobal(Offset.zero, ancestor: area);
  }

  void _drag(DragUpdateDetails details) {
    final area = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    final capsule =
        _capsuleKey.currentContext?.findRenderObject() as RenderBox?;
    if (area == null || capsule == null || _position == null) return;
    setState(() {
      _position = _CountdownLayout.clamp(
        _position! + details.delta,
        area.size,
        capsule.size,
      );
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final time = _countdown(widget.remaining);
    final foreground = _urgent ? scheme.error : scheme.primary;
    final hint = maintenanceText(context, '拖动调整位置，点击查看更新提醒');
    final label = '${maintenanceText(context, '服务器更新倒计时')} $time';
    Widget capsule = Semantics(
      button: true,
      label: label,
      hint: hint,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: MouseRegion(
        key: _capsuleKey,
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          key: const ValueKey('server-maintenance-countdown'),
          excludeFromSemantics: true,
          onPanStart: _startDrag,
          onPanUpdate: _drag,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                final pulse = Curves.easeInOut.transform(_pulse.value);
                return DecoratedBox(
                  key: const ValueKey('server-maintenance-countdown-surface'),
                  decoration: BoxDecoration(
                    color: _urgent
                        ? Color.lerp(
                            scheme.surface,
                            scheme.errorContainer,
                            0.6 + 0.4 * pulse,
                          )
                        : scheme.surface,
                    borderRadius: UtenRadius.pillAll,
                    border: Border.all(
                      color: foreground.withValues(
                        alpha: _urgent ? 0.55 + 0.45 * pulse : 0.35,
                      ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (_urgent ? scheme.error : scheme.shadow)
                            .withValues(
                              alpha: _urgent ? 0.14 + 0.24 * pulse : 0.12,
                            ),
                        blurRadius: _urgent ? 8 + 12 * pulse : 12,
                        spreadRadius: _urgent ? 1 + 2 * pulse : 0,
                        offset: Offset(0, _urgent ? 0 : 3),
                      ),
                    ],
                  ),
                  child: child,
                );
              },
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: widget.onTap,
                  borderRadius: UtenRadius.pillAll,
                  focusColor: foreground.withValues(alpha: 0.16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: UtenControlMetrics.minimumHitExtent(
                        context,
                        desktop: 48,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s12,
                        vertical: UtenSpacing.s8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 20,
                            color: foreground,
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                time,
                                maxLines: 1,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: foreground,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Icon(
                            Icons.drag_indicator_rounded,
                            size: 16,
                            color: foreground.withValues(alpha: 0.6),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // This host can be a sibling of Navigator, without an Overlay ancestor.
    if (Overlay.maybeOf(context) != null) {
      capsule = Tooltip(message: '$label\n$hint', child: capsule);
    }
    return CustomSingleChildLayout(
      key: _areaKey,
      delegate: _CountdownLayout(_position),
      child: capsule,
    );
  }
}

/// Uses the actual capsule size, including accessibility text scaling, so the
/// entire status remains reachable after dragging, resizing or opening a keyboard.
class _CountdownLayout extends SingleChildLayoutDelegate {
  const _CountdownLayout(this.position);
  final Offset? position;

  static Offset clamp(Offset position, Size area, Size child) => Offset(
    position.dx.clamp(
      0.0,
      (area.width - child.width).clamp(0.0, double.infinity),
    ),
    position.dy.clamp(
      0.0,
      (area.height - child.height).clamp(0.0, double.infinity),
    ),
  );

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size childSize) => clamp(
    position ?? Offset(size.width - childSize.width, 0),
    size,
    childSize,
  );

  @override
  bool shouldRelayout(_CountdownLayout oldDelegate) =>
      position != oldDelegate.position;
}

class _ScheduledContent extends StatelessWidget {
  const _ScheduledContent({required this.snapshot, required this.remaining});
  final ServerMaintenanceSnapshot snapshot;
  final Duration? remaining;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = remaining?.isNegative == true;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          maintenanceText(context, '请先保存当前工作'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          maintenanceText(
            context,
            waiting
                ? '更新尚未开始，请保存工作并等候服务器通知。'
                : '更新开始时连接会暂时中断。请在倒计时结束前保存正在编辑的内容，并等待当前提交完成。',
          ),
        ),
        const SizedBox(height: UtenSpacing.s24),
        LayoutBuilder(
          builder: (context, bounds) {
            final countdown = FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                _countdown(remaining),
                style: theme.textTheme.displaySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            );
            final startTime = Text(
              '${maintenanceText(context, '开始时间（北京时间）')}\n'
              '${DisplayDateTime.beijing(snapshot.startsAt?.toIso8601String())}',
              style: theme.textTheme.bodySmall,
            );
            if (bounds.maxWidth < 360) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  countdown,
                  const SizedBox(height: UtenSpacing.s12),
                  startTime,
                ],
              );
            }
            return Row(
              children: [
                countdown,
                const SizedBox(width: UtenSpacing.s20),
                Expanded(child: startTime),
              ],
            );
          },
        ),
        if (snapshot.targetVersion != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '${maintenanceText(context, '目标版本')} ${snapshot.targetVersion}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// The same recovery surface is used before login and inside native apps.
///
/// Layout mirrors the web maintenance page: a teal brand rail with the white
/// wordmark and a server-rack motif, and a status panel with chips and a
/// three-step timeline. Brand texts stay in Chinese on every locale, matching
/// the static web page.
class ServerMaintenancePage extends StatelessWidget {
  const ServerMaintenancePage({
    super.key,
    required this.snapshot,
    required this.checking,
    required this.statusUnavailable,
    required this.onCheck,
  });

  final ServerMaintenanceSnapshot snapshot;
  final bool checking;
  final bool statusUnavailable;
  final VoidCallback onCheck;

  static const _railBreakpoint = 880.0;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('server-maintenance-page'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _railBreakpoint;
            if (wide) {
              // The rail fills the height and the panel scrolls on its own,
              // so Spacer-based vertical distribution stays bounded.
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MaintenanceRail(
                    width: (constraints.maxWidth * 0.4).clamp(340.0, 460.0),
                    recovery: _recovery,
                  ),
                  Expanded(child: _buildPanel(context, wide: wide)),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MaintenanceRail.compact(recovery: _recovery),
                Expanded(child: _buildPanel(context, wide: wide)),
              ],
            );
          },
        ),
      ),
    );
  }

  bool get _recovery =>
      snapshot.phase == ServerMaintenancePhase.recoveryRequired;

  Widget _buildPanel(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final steps = [
      _MaintenanceStep(
        label: maintenanceText(context, '更新预告已发布'),
        state: _MaintenanceStepState.done,
      ),
      _MaintenanceStep(
        label: maintenanceText(
          context,
          _recovery
              ? '等待恢复服务'
              : snapshot.phase == ServerMaintenancePhase.scheduled
              ? '等待更新开始'
              : '服务更新中',
        ),
        state: _MaintenanceStepState.current,
      ),
      _MaintenanceStep(
        label: maintenanceText(context, '恢复后返回工作'),
        state: _MaintenanceStepState.pending,
      ),
    ];
    final scheduled = snapshot.phase == ServerMaintenancePhase.scheduled;
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = _buildPanelContent(
          context,
          theme: theme,
          scheme: scheme,
          dark: dark,
          steps: steps,
          scheduled: scheduled,
        );
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 560),
                padding: EdgeInsets.fromLTRB(24, wide ? 56 : 30, 24, 44),
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPanelContent(
    BuildContext context, {
    required ThemeData theme,
    required ColorScheme scheme,
    required bool dark,
    required List<_MaintenanceStep> steps,
    required bool scheduled,
  }) {
    final title = maintenanceText(
      context,
      _recovery ? '服务恢复需要管理员确认' : '服务器正在更新中',
    );
    return Semantics(
      container: true,
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: _recovery ? scheme.error : null,
              fontWeight: FontWeight.w700,
              height: 1.3,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            maintenanceText(
              context,
              _recovery
                  ? '更新尚未完成。请保留当前窗口并联系管理员，服务通过检查后会自动返回。'
                  : '正在更新服务并检查运行状态。请保留当前窗口，恢复后会自动返回。',
            ),
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.75,
            ),
          ),
          const SizedBox(height: UtenSpacing.s24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: UtenRadius.cardAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (snapshot.targetVersion != null)
                      _MaintenanceChip(
                        label:
                            '${maintenanceText(context, '目标版本')} ${snapshot.targetVersion}',
                        accent: true,
                        dark: dark,
                      ),
                    if (scheduled && snapshot.startsAt != null)
                      _MaintenanceChip(
                        label:
                            '${maintenanceText(context, '开始时间（北京时间）')} '
                            '${DisplayDateTime.beijing(snapshot.startsAt!.toIso8601String())}',
                        dark: dark,
                      ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s16),
                _MaintenanceSteps(steps: steps, recovery: _recovery),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            maintenanceText(
              context,
              '当前页面和已输入内容保留在此窗口中。恢复连接不会自动重复提交；结果不确定时，请先核对单据。',
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.7,
            ),
          ),
          if (statusUnavailable) ...[
            const SizedBox(height: UtenSpacing.s12),
            Text(
              maintenanceText(context, '暂时无法读取更新状态，正在继续检查。'),
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: UtenSpacing.s24),
          UtenButton(
            onPressed: onCheck,
            isLoading: checking,
            icon: Icons.refresh_rounded,
            child: Text(maintenanceText(context, checking ? '正在检查' : '检查恢复状态')),
          ),
        ],
      ),
    );
  }
}

class _MaintenanceStep {
  const _MaintenanceStep({required this.label, required this.state});

  final String label;
  final _MaintenanceStepState state;
}

enum _MaintenanceStepState { done, current, pending }

/// Brand rail with the white wordmark, platform name, a server-rack motif and
/// the copyright line. Collapses to a compact horizontal strip when narrow.
class _MaintenanceRail extends StatelessWidget {
  const _MaintenanceRail({required this.recovery, this.width})
    : compact = false;

  const _MaintenanceRail.compact({required this.recovery})
    : width = null,
      compact = true;

  final bool recovery;
  final double? width;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ledColor = recovery
        ? UtenColors.errorOnDark
        : (dark ? UtenColors.teal200 : UtenColors.teal100);
    final rail = Container(
      width: compact ? null : width,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: const Alignment(-0.4, -1),
          end: const Alignment(0.6, 1),
          colors: dark
              ? const [UtenColors.teal950, Color(0xFF0A4741)]
              : const [Color(0xFF0C4A45), UtenColors.teal700],
        ),
      ),
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 22, vertical: 18)
          : const EdgeInsets.fromLTRB(44, 48, 44, 36),
      child: compact
          ? const Row(
              children: [
                _Wordmark(width: 132),
                SizedBox(width: UtenSpacing.s16),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: DefaultTextStyle(
                      style: TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 3,
                      ),
                      child: Text('优腾综合管理平台'),
                    ),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Wordmark(width: 200),
                const SizedBox(height: UtenSpacing.s16),
                const Text(
                  '优腾综合管理平台',
                  style: TextStyle(
                    color: Color(0xE6FFFFFF),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 4,
                  ),
                ),
                // Scrolls only when the window is shorter than the motif
                // stack; otherwise the rack sits just above the copyright.
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: UtenSpacing.s40),
                        _RackMotif(ledColor: ledColor),
                        const SizedBox(height: 64),
                        const Text(
                          '© 中山市优腾电器有限公司',
                          style: TextStyle(
                            color: Color(0x9EFFFFFF),
                            fontSize: 12.5,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
    // The wordmark is decorative; the rail name text carries semantics.
    return Semantics(
      label: '优腾综合管理平台',
      child: ExcludeSemantics(child: rail),
    );
  }
}

/// White variant of the default wordmark: the teal artwork is recolored
/// through a srcIn mask so it reads on the teal rail. The maintenance surface
/// always shows the default brand, matching the static web page, so it does
/// not watch the branding providers.
class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: width / (2210 / 334),
      child: const ColorFiltered(
        colorFilter: ColorFilter.mode(Colors.white, BlendMode.srcIn),
        child: Image(
          image: AssetImage(UtenAssets.logoName),
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

class _RackMotif extends StatelessWidget {
  const _RackMotif({required this.ledColor});

  final Color ledColor;

  @override
  Widget build(BuildContext context) {
    Widget unit() {
      return Container(
        height: 46,
        padding: const EdgeInsets.only(left: 15, right: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.09),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
          borderRadius: UtenRadius.controlAll,
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: ledColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: ledColor.withValues(alpha: 0.55),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 17),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [0.9, 1.0, 0.82]
                    .map(
                      (w) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: FractionallySizedBox(
                          widthFactor: w,
                          alignment: Alignment.centerLeft,
                          child: Container(
                            height: 2,
                            decoration: const BoxDecoration(
                              color: Color(0x38FFFFFF),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      width: 204,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i < 2 ? 10 : 0),
              child: unit(),
            ),
        ],
      ),
    );
  }
}

class _MaintenanceChip extends StatelessWidget {
  const _MaintenanceChip({
    required this.label,
    required this.dark,
    this.accent = false,
  });

  final String label;
  final bool dark;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = accent
        ? dark
              ? (UtenColors.teal700.withValues(alpha: 0.35), UtenColors.teal200)
              : (UtenColors.teal50, UtenColors.teal800)
        : dark
        ? (UtenColors.darkSurfaceHigh, scheme.onSurfaceVariant)
        : (UtenColors.surfaceMid, scheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(UtenRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _MaintenanceSteps extends StatelessWidget {
  const _MaintenanceSteps({required this.steps, required this.recovery});

  final List<_MaintenanceStep> steps;
  final bool recovery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highlight = recovery ? scheme.error : scheme.primary;
    final children = <Widget>[];
    for (final (index, step) in steps.indexed) {
      if (index > 0) {
        final connector = step.state == _MaintenanceStepState.current
            ? highlight.withValues(alpha: 0.45)
            : scheme.outlineVariant;
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Container(width: 2, height: 16, color: connector),
          ),
        );
      }
      final marker = switch (step.state) {
        _MaintenanceStepState.done => Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: highlight, shape: BoxShape.circle),
          child: const Icon(Icons.check, size: 14, color: Colors.white),
        ),
        _MaintenanceStepState.current => Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: scheme.surface,
            shape: BoxShape.circle,
            border: Border.all(color: highlight, width: 2),
          ),
          child: Center(
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: highlight,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
        _MaintenanceStepState.pending => Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: scheme.surface,
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outline, width: 2),
          ),
        ),
      };
      children.add(
        Row(
          children: [
            marker,
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Text(
                step.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: step.state == _MaintenanceStepState.current
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                  fontWeight: step.state == _MaintenanceStepState.current
                      ? FontWeight.w600
                      : FontWeight.w400,
                  height: 1.55,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
