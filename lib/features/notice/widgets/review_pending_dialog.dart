// ReviewPendingDialog —— 审核待办居中弹窗（V459/ADR-063；2026-09-03 第四轮口径）
//
// 一个待审事件的三种提醒形态并存：通知中心条目 + 顶部通知条（纯显示）+ 本居中弹窗。
// 本弹窗承载主交互：
// - 登录检查（ReviewPendingLoginGate）与在线到达（dispatchReviewCard）共用；
// - 在线多事件同到：先弹一条，后续待办**并入同一弹窗**（「一共有 N 项」），不再丢弃；
// - 弹窗内实时显示「是否有人在处理」（30s 心跳 pending-review-status：
//   他人认领 → 「XX 正在审核」黄色 chip；办结 → 条目自动移除，清空则弹窗自关）；
// - 【去工作台处理】（2026-09-03 第四轮：不再直达单据详情）：全部待办同域 →
//   该域任务工作台；跨域混合 → 工作台首页 /dashboard。点单条条目 →
//   该条所属域的工作台。去工作台 = 提醒已响应，弹窗内条目全部标已读；
// - 【稍后再看】：全部条目标已读 + 服务端 snooze 15 分钟（跨设备一致，
//   到点未办结下次登录/到达再弹）；
// - 右上 X：仅关闭本次（不 snooze——「每次登录检查、有待办就弹」的产品口径）。
// 文档：docs/02-组件库/ReviewPendingDialog.md

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';
import '../repositories/notice_repository.dart';

/// sourceEvent → 该域任务工作台（汇总列表）。主按钮不再直达单据详情
/// （2026-09-03 第四轮口径：弹窗只做提醒汇总，处理在工作台做）。
String workbenchRouteFor(
  String? sourceEvent, {
  String? actionRoute,
}) => switch (sourceEvent) {
  'SALES_ORDER_PENDING_FINANCE_CONFIRM' =>
    actionRoute == '/finance/sales-order-changes'
        ? '/finance/sales-order-changes'
        : '/finance/sales-order-confirmations',
  'PROCUREMENT_FINANCE_SUBMITTED' ||
  'PROCUREMENT_FINANCE_CHANGE_SUBMITTED' => '/finance/procurement-approvals',
  'PROCUREMENT_IQC_PENDING' => RouteName.qualityTaskCenter,
  'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP' => RouteName.salesOrderProgress,
  'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED' =>
    RouteName.productionWorkshopTasks,
  'SALES_ORDER_APPROVED' ||
  'SUBCONTRACT_PREPARATION_REQUIRED' ||
  'SUBCONTRACT_ORDER_PREPARATION_DISPATCHED' =>
    RouteName.productionMaterialAnalysis,
  'PROCUREMENT_IQC_STOCK_IN_PENDING' => RouteName.warehouseQualityResults,
  'PRODUCTION_DRAW_PENDING' => RouteName.warehouseDrawTasks,
  'PROCUREMENT_FINANCE_APPROVED' => RouteName.warehouseInboundTasks,
  'PROCUREMENT_IQC_REJECTION_OPENED' ||
  'PROCUREMENT_IQC_REJECTION_RETURNED' => RouteName.procurementIqcRejections,
  _ => RouteName.dashboard,
};

/// 居中弹窗单例守卫：已打开时新待办并入当前弹窗（在线多事件同到
/// 「一共有 N 项」；登录检查与到达链竞争时只保一层）。
bool _reviewPendingDialogOpen = false;
int _dialogGeneration = 0;
int get reviewPendingDialogGeneration => _dialogGeneration;
_ReviewPendingDialogState? _openDialogState;

/// Session replacement must remove the old account's exact dialog route.
void closeReviewPendingDialog() {
  _dialogGeneration++;
  final state = _openDialogState;
  if (state != null && state.mounted) {
    final route = ModalRoute.of(state.context);
    if (route != null) {
      Navigator.of(state.context, rootNavigator: true).removeRoute(route);
    }
  }
  _openDialogState = null;
  _reviewPendingDialogOpen = false;
}

/// 仅测试用：重置单例守卫（widget 测试间隔离）。
@visibleForTesting
void resetReviewPendingDialogForTest() {
  _reviewPendingDialogOpen = false;
  _openDialogState = null;
}

/// 弹出居中审核待办弹窗。[pending] 非空（调用方保证）；全空由心跳自然自关。
/// 弹窗已打开时把 [pending] 并入当前弹窗（按 id 去重）。
Future<void> showReviewPendingDialog(
  BuildContext context, {
  required List<Notice> pending,
}) {
  if (_reviewPendingDialogOpen) {
    _openDialogState?.addPendingItems(pending);
    return Future<void>.value();
  }
  _reviewPendingDialogOpen = true;
  final generation = _dialogGeneration;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => ReviewPendingDialog(
      key: const ValueKey('review-pending-dialog'),
      pending: pending,
    ),
  ).whenComplete(() {
    if (generation == _dialogGeneration) _reviewPendingDialogOpen = false;
  });
}

class ReviewPendingDialog extends ConsumerStatefulWidget {
  const ReviewPendingDialog({super.key, required this.pending});

  final List<Notice> pending;

  @override
  ConsumerState<ReviewPendingDialog> createState() =>
      _ReviewPendingDialogState();
}

class _ReviewPendingDialogState extends ConsumerState<ReviewPendingDialog> {
  late List<Notice> _items;
  final Map<String, PendingReviewStatus> _statusById = {};
  Timer? _heartbeat;
  bool _busy = false;
  bool _statusLoading = false;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.pending);
    _openDialogState = this;
    _refreshStatus();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshStatus(),
    );
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    if (_openDialogState == this) _openDialogState = null;
    super.dispose();
  }

  /// 在线新到待办并入当前弹窗（按 id 去重）——多事件同到合成
  /// 「一共有 N 项」一个弹窗，而不是每条各弹一层。
  void addPendingItems(List<Notice> items) {
    if (!mounted || items.isEmpty) return;
    final fresh = items
        .where((n) => !_items.any((e) => e.id == n.id))
        .toList(growable: false);
    if (fresh.isEmpty) return;
    setState(() => _items.addAll(fresh));
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    if (!mounted || _items.isEmpty || _statusLoading) return;
    _statusLoading = true;
    final requestedIds = _items.map((n) => n.id).toSet();
    try {
      final statuses = await ref
          .read(noticeRepositoryProvider)
          .pendingReviewStatus(requestedIds.toList());
      if (!mounted) return;
      setState(() {
        _statusById
          ..clear()
          ..addAll({for (final s in statuses) s.noticeId: s});
        // 办结撤回：条目自动移除；全部办结则弹窗自关（不打扰已无需处理的人）。
        _items.removeWhere(
          (n) =>
              requestedIds.contains(n.id) &&
              (!_statusById.containsKey(n.id) || _statusById[n.id]!.resolved),
        );
        if (_items.isEmpty) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      });
    } catch (_) {
      // 真态校验失败可容忍：条目保持上次状态。
    } finally {
      _statusLoading = false;
    }
  }

  /// 主按钮落点：全部待办同域 → 该域任务工作台；跨域混合 → 工作台首页。
  String get _primaryTarget {
    final routes = {
      for (final n in _items)
        workbenchRouteFor(n.sourceEvent, actionRoute: n.actionRoute),
    };
    return routes.length == 1 ? routes.first : RouteName.dashboard;
  }

  /// 去任务工作台（2026-09-03 第四轮：不再直达单据详情）。
  /// [only] 为空 = 主按钮：跳综合落点(同域工作台/工作台首页)，弹窗内全部
  /// 条目标已读（提醒已响应）；指定条目 = 点列表行：跳该条所属域工作台，
  /// 仅该条标已读。
  Future<void> _openWorkbench({Notice? only}) async {
    if (_busy) return;
    _busy = true;
    final container = ProviderScope.containerOf(context, listen: false);
    final targets = only == null ? _items : [only];
    for (final n in targets) {
      markNoticeReadContainer(container, n.id).ignore();
    }
    final target = only == null
        ? _primaryTarget
        : workbenchRouteFor(only.sourceEvent, actionRoute: only.actionRoute);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    try {
      GoRouter.of(context).go(target);
    } catch (_) {
      // 工作台路由为前端常量（app_router 必注册）；异常仅见于测试环境。
    }
  }

  Future<void> _snoozeAll() async {
    if (_busy) return;
    _busy = true;
    final container = ProviderScope.containerOf(context, listen: false);
    final repository = container.read(noticeRepositoryProvider);
    for (final n in _items) {
      markNoticeReadContainer(container, n.id).ignore();
      repository.snooze(n.id).ignore();
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final single = _items.length == 1;
    // 高度完全随内容自适应；封顶 min(60% 屏高, 560)——积压多条时列表内部
    // 滚动，弹窗保持正常卡片比例，不再被拉到接近全屏。
    final maxHeight = math.min(MediaQuery.sizeOf(context).height * 0.6, 560.0);
    return Dialog(
      backgroundColor: scheme.surface,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 480, maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(theme: theme, count: _items.length),
              const SizedBox(height: UtenSpacing.s16),
              Flexible(
                child: single
                    ? _LargeItemCard(
                        theme: theme,
                        notice: _items.first,
                        status: _statusById[_items.first.id],
                        onTap: () => _openWorkbench(),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final item in _items)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: UtenSpacing.s8,
                              ),
                              child: _CompactItemCard(
                                theme: theme,
                                notice: item,
                                status: _statusById[item.id],
                                onTap: () => _openWorkbench(only: item),
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              _Actions(
                theme: theme,
                busy: _busy,
                onReview: () => _openWorkbench(),
                onSnooze: _snoozeAll,
                onClose: () => Navigator.of(context, rootNavigator: true).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.theme, required this.count});

  final ThemeData theme;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            Icons.fact_check_rounded,
            size: 28,
            color: scheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '待办提醒',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  count == 1 ? '有 1 项事务等待你处理' : '有 $count 项事务等待你处理',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          icon: Icon(
            Icons.close_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          tooltip: '关闭，稍后可从工作台或通知进入',
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }
}

IconData _eventIcon(String? sourceEvent) => switch (sourceEvent) {
  'SALES_ORDER_PENDING_FINANCE_CONFIRM' => Icons.request_quote_outlined,
  'PROCUREMENT_FINANCE_SUBMITTED' => Icons.approval_outlined,
  'PROCUREMENT_IQC_PENDING' => Icons.science_outlined,
  'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP' => Icons.local_shipping_outlined,
  'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED' =>
    Icons.precision_manufacturing_outlined,
  _ => Icons.fact_check_outlined,
};

/// 单条：大卡布局（图标+标题+摘要+状态+操作提示）。
class _LargeItemCard extends StatelessWidget {
  const _LargeItemCard({
    required this.theme,
    required this.notice,
    required this.status,
    required this.onTap,
  });

  final ThemeData theme;
  final Notice notice;
  final PendingReviewStatus? status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final claimedBy = status?.claimedByName;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Column(
          // 不写 min 会在外层 Flexible 的 loose 约束下占满剩余高度，
          // 单条时卡片下方出现大片空白（2026-09-03 修复）。
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    _eventIcon(notice.sourceEvent),
                    size: 22,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Text(
                    notice.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (notice.content.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                notice.content,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            _ClaimChip(theme: theme, claimedByName: claimedBy),
          ],
        ),
      ),
    );
  }
}

/// 多条：紧凑行（图标+标题+时间+状态 chip）。
class _CompactItemCard extends StatelessWidget {
  const _CompactItemCard({
    required this.theme,
    required this.notice,
    required this.status,
    required this.onTap,
  });

  final ThemeData theme;
  final Notice notice;
  final PendingReviewStatus? status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s12,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              _eventIcon(notice.sourceEvent),
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                notice.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            _ClaimChip(theme: theme, claimedByName: status?.claimedByName),
          ],
        ),
      ),
    );
  }
}

/// 认领状态 chip：他人处理中（黄）/ 待处理（绿点）——「对应的人是否操作」。
class _ClaimChip extends StatelessWidget {
  const _ClaimChip({required this.theme, required this.claimedByName});

  final ThemeData theme;
  final String? claimedByName;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final claimed = claimedByName != null && claimedByName!.isNotEmpty;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: claimed
            ? scheme.tertiaryContainer.withValues(alpha: 0.7)
            : scheme.primaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            claimed ? Icons.person_pin_circle_rounded : Icons.schedule_rounded,
            size: 14,
            color: claimed
                ? scheme.onTertiaryContainer
                : scheme.onPrimaryContainer,
          ),
          const SizedBox(width: 5),
          Text(
            claimed ? '$claimedByName 正在审核' : '待处理',
            style: theme.textTheme.labelSmall?.copyWith(
              color: claimed
                  ? scheme.onTertiaryContainer
                  : scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.theme,
    required this.busy,
    required this.onReview,
    required this.onSnooze,
    required this.onClose,
  });

  final ThemeData theme;
  final bool busy;
  final VoidCallback onReview;
  final VoidCallback onSnooze;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: busy ? null : onReview,
            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
            // 同域进入对应任务页，混合待办进入工作台首页，
            // 不再直达第一条的详情页。
            label: const Text('去工作台处理'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              textStyle: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: OutlinedButton(
            onPressed: busy ? null : onSnooze,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            child: const Text('全部稍后再看'),
          ),
        ),
      ],
    );
  }
}
