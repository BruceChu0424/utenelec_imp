import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/l10n/maintenance_text.dart';
import '../../core/maintenance/server_maintenance.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/utils/display_datetime.dart';
import '../providers/app_visibility_provider.dart';

/// Covers login, business routes and native clients through the same status.
class ServerMaintenanceHost extends ConsumerWidget {
  const ServerMaintenanceHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ServerMaintenanceView(
    controller: ref.watch(serverMaintenanceControllerProvider),
    visible: ref.watch(appVisibilityProvider),
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
  });

  final ServerMaintenanceController controller;
  final Widget child;
  final bool visible;

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
        if (warns && !showReminder)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Material(
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s16,
                    vertical: UtenSpacing.s4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.schedule_rounded,
                        color: scheme.onSecondaryContainer,
                        size: 20,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Expanded(
                        child: Text(
                          '${maintenanceText(context, '更新时连接会暂时中断')} · ${_countdown(controller.remaining)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(
                          () => _acknowledged.remove(snapshot!.noticeKey),
                        ),
                        child: Text(maintenanceText(context, '查看更新提醒')),
                      ),
                    ],
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final recovery = snapshot.phase == ServerMaintenancePhase.recoveryRequired;
    final title = maintenanceText(
      context,
      recovery ? '服务恢复需要管理员确认' : '服务器正在更新中',
    );
    return Material(
      key: const ValueKey('server-maintenance-page'),
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(UtenSpacing.s24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Semantics(
                container: true,
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      recovery
                          ? Icons.support_agent_rounded
                          : Icons.dns_rounded,
                      size: 48,
                      color: recovery ? scheme.error : scheme.primary,
                    ),
                    const SizedBox(height: UtenSpacing.s24),
                    Text(
                      title,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    Text(
                      maintenanceText(
                        context,
                        recovery
                            ? '更新尚未完成。请保留当前窗口并联系管理员，服务通过检查后会自动返回。'
                            : '正在更新服务并检查运行状态。请保留当前窗口，恢复后会自动返回。',
                      ),
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
                    ),
                    const SizedBox(height: UtenSpacing.s32),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(UtenSpacing.s20),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        border: Border.all(color: scheme.outlineVariant),
                        borderRadius: UtenRadius.cardAll,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (snapshot.targetVersion != null) ...[
                            Text(
                              '${maintenanceText(context, '目标版本')} ${snapshot.targetVersion}',
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: UtenSpacing.s16),
                          ],
                          for (final (index, label) in [
                            '更新预告已发布',
                            recovery ? '等待恢复服务' : '服务更新中',
                            '恢复后返回工作',
                          ].indexed) ...[
                            if (index > 0)
                              const SizedBox(height: UtenSpacing.s12),
                            Row(
                              children: [
                                Icon(
                                  index == 0
                                      ? Icons.check_circle_rounded
                                      : index == 1
                                      ? Icons.build_circle_outlined
                                      : Icons.radio_button_unchecked_rounded,
                                  size: 20,
                                  color: index < 2
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: UtenSpacing.s12),
                                Expanded(
                                  child: Text(maintenanceText(context, label)),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s20),
                    Text(
                      maintenanceText(
                        context,
                        '当前页面和已输入内容保留在此窗口中。恢复连接不会自动重复提交；结果不确定时，请先核对单据。',
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.6,
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
                      type: UtenButtonType.secondary,
                      child: Text(
                        maintenanceText(context, checking ? '正在检查' : '检查恢复状态'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
