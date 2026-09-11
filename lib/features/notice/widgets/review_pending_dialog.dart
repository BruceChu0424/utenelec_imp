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
//   该条所属域的工作台。去工作台 = 提醒已响应：弹窗内条目全部 markRead
//   （服务端同时置 popup_acknowledged → 未办结也不再登录重弹）；
// - 【稍后再看】：只调服务端 snooze 15 分钟（服务端顺带置已读；**不再另调
//   markRead**，否则并发写会把 snoozed_until 冲掉）——到点未办结下次登录/到达
//   再弹，即使期间已读；
// - 右上 X：仅关闭本次（不 snooze、不 ack——未确认的待办下次登录仍弹）。
// 登录弹窗口径（2026-09-10，ADR-063 修订）：未办结 且（未确认弹窗 或 稍后到期）。
// 人工通知（2026-09-10，ADR-063 §8）：人事手动发布的通知与待办审核同弹窗、独立分组
// 「人事/公司通知」——打卡类型（公告/制度/系统/紧急/福利）每条带【打卡确认】，不打卡
// 每次登录都弹；只提醒类型【知道了】= markRead；【查看详情】关弹窗进详情页；
// 【全部稍后再看】对两组一起 snooze。人工条目不参与 pending-review-status 心跳。
// 文档：docs/02-组件库/ReviewPendingDialog.md

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
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
  // 2026-09-09 人事域弹卡（HrNoticeService）：各审批队列落点
  'PROFILE_CHANGE_SUBMITTED' => '/hr/profile-changes',
  'VISITOR_APPLY_SUBMITTED' => '/visitor-approval',
  'VISITOR_HOST_CONFIRM_REQUIRED' => '/my-visitors',
  'EXPENSE_CLAIM_SUBMITTED' ||
  'EXPENSE_CLAIM_PENDING_PAYMENT' => '/expense/approval',
  'PAYROLL_BATCH_SUBMITTED' ||
  'PAYROLL_BATCH_PENDING_PUBLISH' => '/payroll/review',
  // 建议箱列表默认「建议广场」（全部建议），scope 是页面状态不是 URL 参数。
  'SUGGESTION_SUBMITTED' => RouteName.suggestion,
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

/// 弹出居中待办弹窗。[pending]（审核待办）与 [manual]（人工通知）至少一组非空
/// （调用方保证；两组皆空直接返回）；全空由心跳/逐条处理自然自关。
/// 弹窗已打开时把两组并入当前弹窗（按 id 去重）。
Future<void> showReviewPendingDialog(
  BuildContext context, {
  required List<Notice> pending,
  List<Notice> manual = const [],
}) {
  if (pending.isEmpty && manual.isEmpty) return Future<void>.value();
  if (_reviewPendingDialogOpen) {
    _openDialogState?.addPendingItems(pending, manual: manual);
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
      manual: manual,
    ),
  ).whenComplete(() {
    if (generation == _dialogGeneration) _reviewPendingDialogOpen = false;
  });
}

class ReviewPendingDialog extends ConsumerStatefulWidget {
  const ReviewPendingDialog({
    super.key,
    required this.pending,
    this.manual = const [],
  });

  /// 审核待办（interactive=true，参与 pending-review-status 心跳）。
  final List<Notice> pending;

  /// 人工通知（人事手动发布：打卡 / 只提醒），不参与心跳。
  final List<Notice> manual;

  @override
  ConsumerState<ReviewPendingDialog> createState() =>
      _ReviewPendingDialogState();
}

class _ReviewPendingDialogState extends ConsumerState<ReviewPendingDialog> {
  late List<Notice> _items;
  late List<Notice> _manualItems;
  final Map<String, PendingReviewStatus> _statusById = {};

  /// 已打卡成功、正在短暂展示「已打卡」后移除的人工条目。
  final Set<String> _ackedIds = {};

  /// 正在请求（打卡 / 知道了）的人工条目，防连点。
  final Set<String> _busyIds = {};
  Timer? _heartbeat;
  bool _busy = false;
  bool _statusLoading = false;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.pending);
    _manualItems = List.of(widget.manual);
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
  /// 「一共有 N 项」一个弹窗，而不是每条各弹一层。[manual] 为人工通知组。
  void addPendingItems(List<Notice> items, {List<Notice> manual = const []}) {
    if (!mounted) return;
    final fresh = items
        .where((n) => !_items.any((e) => e.id == n.id))
        .toList(growable: false);
    final freshManual = manual
        .where((n) => !_manualItems.any((e) => e.id == n.id))
        .toList(growable: false);
    if (fresh.isEmpty && freshManual.isEmpty) return;
    setState(() {
      _items.addAll(fresh);
      _manualItems.addAll(freshManual);
    });
    if (fresh.isNotEmpty) _refreshStatus();
  }

  bool get _empty => _items.isEmpty && _manualItems.isEmpty;

  void _closeIfEmpty() {
    if (_empty && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
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
        // 人工通知组不参与心跳，仍有人工条目时弹窗保留。
        _items.removeWhere(
          (n) =>
              requestedIds.contains(n.id) &&
              (!_statusById.containsKey(n.id) || _statusById[n.id]!.resolved),
        );
        _closeIfEmpty();
      });
    } catch (_) {
      // 真态校验失败可容忍：条目保持上次状态。
    } finally {
      _statusLoading = false;
    }
  }

  // ---------------- 人工通知（人事/公司通知）条目动作 ----------------

  /// 【打卡确认】：调 acknowledge（幂等）；成功后条目短暂显示「已打卡」再移除，
  /// 全部处理完弹窗自关；失败顶部报错、条目保留可重试。
  Future<void> _acknowledgeManual(Notice notice) async {
    if (_busyIds.contains(notice.id) || _ackedIds.contains(notice.id)) return;
    setState(() => _busyIds.add(notice.id));
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container.read(noticeRepositoryProvider).acknowledge(notice.id);
      container.invalidate(noticeListProvider);
      container.invalidate(noticeDetailProvider(notice.id));
      if (!mounted) return;
      setState(() {
        _busyIds.remove(notice.id);
        _ackedIds.add(notice.id);
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      setState(() {
        _manualItems.removeWhere((n) => n.id == notice.id);
        _ackedIds.remove(notice.id);
      });
      _closeIfEmpty();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busyIds.remove(notice.id));
      context.appError('打卡失败，请稍后重试或在通知中心打卡');
    }
  }

  /// 【知道了】（只提醒类型）：markRead（服务端同时置 popup_acknowledged_at，
  /// 下次登录不再弹）后移除条目。
  void _dismissManual(Notice notice) {
    if (_busyIds.contains(notice.id)) return;
    final container = ProviderScope.containerOf(context, listen: false);
    markNoticeReadContainer(container, notice.id).ignore();
    setState(() => _manualItems.removeWhere((n) => n.id == notice.id));
    _closeIfEmpty();
  }

  /// 【查看详情】：标已读（打卡类型仍待打卡，详情页可打卡）→ 关弹窗 → 进详情路由。
  void _openManualDetail(Notice notice) {
    if (_busy) return;
    final container = ProviderScope.containerOf(context, listen: false);
    markNoticeReadContainer(container, notice.id).ignore();
    final router = _routerOrNull();
    Navigator.of(context, rootNavigator: true).pop();
    try {
      router?.push(RoutePath.noticeDetail(notice.id));
    } catch (_) {
      // 详情路由为前端常量（app_router 必注册）；异常仅见于测试环境。
    }
  }

  GoRouter? _routerOrNull() {
    try {
      return GoRouter.of(context);
    } catch (_) {
      return null;
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

  /// 「全部稍后再看」只走 snooze：服务端置 snoozed_until + 已读；不能再并发
  /// 调 markRead（两次部分更新竞争会把刚写的 snoozed_until 覆盖回 NULL，
  /// 「稍后」就永远不会再弹——2026-09-10 修复）。
  Future<void> _snoozeAll() async {
    if (_busy) return;
    _busy = true;
    final container = ProviderScope.containerOf(context, listen: false);
    final repository = container.read(noticeRepositoryProvider);
    // 两组一起稍后：人工通知 snooze 到期后同样重弹（打卡类型直到打卡为止）。
    for (final n in [..._items, ..._manualItems]) {
      repository.snooze(n.id).ignore();
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 仅一条审核待办且无人工通知 → 大卡；其余（多条 / 含人工通知）→ 分组列表。
    final singleReviewOnly = _manualItems.isEmpty && _items.length == 1;
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
              _Header(theme: theme, items: _items, manual: _manualItems),
              const SizedBox(height: UtenSpacing.s16),
              Flexible(
                child: singleReviewOnly
                    ? _LargeItemCard(
                        theme: theme,
                        notice: _items.first,
                        status: _statusById[_items.first.id],
                        onTap: () => _openWorkbench(),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          if (_manualItems.isNotEmpty) ...[
                            _GroupLabel(
                              theme: theme,
                              label: '人事/公司通知',
                              count: _manualItems.length,
                            ),
                            for (final item in _manualItems)
                              Padding(
                                key: ValueKey('manual-${item.id}'),
                                padding: const EdgeInsets.only(
                                  bottom: UtenSpacing.s8,
                                ),
                                child: _ManualNoticeCard(
                                  theme: theme,
                                  notice: item,
                                  acked: _ackedIds.contains(item.id),
                                  busy: _busyIds.contains(item.id),
                                  onAcknowledge: () => _acknowledgeManual(item),
                                  onDismiss: () => _dismissManual(item),
                                  onOpenDetail: () => _openManualDetail(item),
                                ),
                              ),
                          ],
                          if (_items.isNotEmpty) ...[
                            if (_manualItems.isNotEmpty)
                              _GroupLabel(
                                theme: theme,
                                label: '待办审核',
                                count: _items.length,
                              ),
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
                        ],
                      ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              _Actions(
                theme: theme,
                busy: _busy,
                hasReviews: _items.isNotEmpty,
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
  const _Header({
    required this.theme,
    required this.items,
    this.manual = const [],
  });

  final ThemeData theme;
  final List<Notice> items;

  /// 人工通知组（人事/公司通知）；只有人工通知时标题改「登录提醒」。
  final List<Notice> manual;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final hasReviews = items.isNotEmpty;
    final count = items.length + manual.length;
    // 分组摘要（2026-09-09 用户口径「收到几个车间任务」）：按事件域聚合，
    // 多条时一眼看出「车间任务 3 · 来料待检验 1」；单一事件不重复摘要。
    // 人工通知作为独立一组「人事/公司通知 N」。
    final groups = <String, int>{
      for (final n in items) _eventGroupLabel(n.sourceEvent): 0,
    };
    for (final n in items) {
      groups[_eventGroupLabel(n.sourceEvent)] =
          groups[_eventGroupLabel(n.sourceEvent)]! + 1;
    }
    final groupChips = groups.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (manual.isNotEmpty) {
      groupChips.add(MapEntry('人事/公司通知', manual.length));
    }
    final subtitle = hasReviews
        ? (count == 1 ? '有 1 项事务等待你处理' : '有 $count 项事务等待你处理')
        : (count == 1 ? '有 1 条通知需要你确认' : '有 $count 条通知需要你确认');
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
            hasReviews ? Icons.fact_check_rounded : Icons.campaign_rounded,
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
                  hasReviews ? '待办提醒' : '登录提醒',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (count > 1 && groupChips.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final g in groupChips)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer.withValues(
                              alpha: 0.6,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${g.key} ${g.value}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSecondaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
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

/// 事件分组摘要的中文名（弹窗副标题下的「车间任务 N · 品质检验 N」chips）。
String _eventGroupLabel(String? sourceEvent) => switch (sourceEvent) {
  'SALES_ORDER_PENDING_FINANCE_CONFIRM' => '销售订单待确认',
  'SALES_SHIPMENT_PENDING_FINANCE_AUDIT' => '发货待财务审核',
  'SALES_SHIPMENT_PENDING_PICK' => '发货待拣货',
  'SALES_SHIPMENT_FINANCE_REJECTED' ||
  'DIRECT_CUSTOMER_SHIPMENT_FINANCE_REJECTED' => '发货被驳回',
  'PROCUREMENT_FINANCE_SUBMITTED' => '订货待财务审批',
  'PROCUREMENT_FINANCE_CHANGE_SUBMITTED' => '订货改量待审批',
  'PROCUREMENT_FINANCE_APPROVED' => '订货已批待入库',
  'PROCUREMENT_IQC_PENDING' => '来料待检验',
  'PROCUREMENT_IQC_STOCK_IN_PENDING' => '检验合格待入库',
  'PROCUREMENT_IQC_REJECTION_OPENED' ||
  'PROCUREMENT_IQC_REJECTION_RETURNED' => 'IQC 拒收处置',
  'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP' => '订单完工待发货',
  'SALES_ORDER_APPROVED' => '订单已确认待分析',
  'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED' => '车间任务',
  'PRODUCTION_DRAW_PENDING' => '领料待出库',
  'SUBCONTRACT_PREPARATION_REQUIRED' => '委外准备',
  'SUBCONTRACT_ORDER_PREPARATION_DISPATCHED' => '委外订货已派出',
  'PROFILE_CHANGE_SUBMITTED' => '信息变更待审核',
  'VISITOR_APPLY_SUBMITTED' => '访客申请待审批',
  'VISITOR_HOST_CONFIRM_REQUIRED' => '访客待确认接待',
  'EXPENSE_CLAIM_SUBMITTED' => '报销待审批',
  'EXPENSE_CLAIM_PENDING_PAYMENT' => '报销待打款',
  'PAYROLL_BATCH_SUBMITTED' => '工资批次待审核',
  'PAYROLL_BATCH_PENDING_PUBLISH' => '工资批次待发布',
  'SUGGESTION_SUBMITTED' => '建议待回复',
  _ => '待办',
};

IconData _eventIcon(String? sourceEvent) => switch (sourceEvent) {
  'SALES_ORDER_PENDING_FINANCE_CONFIRM' => Icons.request_quote_outlined,
  'PROCUREMENT_FINANCE_SUBMITTED' => Icons.approval_outlined,
  'PROCUREMENT_IQC_PENDING' => Icons.science_outlined,
  'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP' => Icons.local_shipping_outlined,
  'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED' =>
    Icons.precision_manufacturing_outlined,
  // 人事域（HrNoticeService）
  'PROFILE_CHANGE_SUBMITTED' => Icons.badge_outlined,
  'VISITOR_APPLY_SUBMITTED' => Icons.person_add_alt_outlined,
  'VISITOR_HOST_CONFIRM_REQUIRED' => Icons.handshake_outlined,
  'EXPENSE_CLAIM_SUBMITTED' => Icons.receipt_long_outlined,
  'EXPENSE_CLAIM_PENDING_PAYMENT' => Icons.payments_outlined,
  'PAYROLL_BATCH_SUBMITTED' => Icons.request_quote_outlined,
  'PAYROLL_BATCH_PENDING_PUBLISH' => Icons.publish_outlined,
  'SUGGESTION_SUBMITTED' => Icons.lightbulb_outline,
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
    this.hasReviews = true,
  });

  final ThemeData theme;
  final bool busy;
  final VoidCallback onReview;
  final VoidCallback onSnooze;
  final VoidCallback onClose;

  /// 无审核待办（只有人工通知）时不显示「去工作台处理」——人工条目逐条
  /// 打卡/知道了，底部只留「全部稍后再看」。
  final bool hasReviews;

  @override
  Widget build(BuildContext context) {
    if (!hasReviews) {
      return OutlinedButton(
        onPressed: busy ? null : onSnooze,
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
        child: const Text('全部稍后再看'),
      );
    }
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

// =========================== 人工通知（人事/公司通知）分组 ===========================

/// 分组小标题（「人事/公司通知 N」「待办审核 N」）。
class _GroupLabel extends StatelessWidget {
  const _GroupLabel({
    required this.theme,
    required this.label,
    required this.count,
  });

  final ThemeData theme;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8, top: 2),
      child: Text(
        '$label · $count',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 人工通知条目：类型图标 + 标题 + 发布人·时间 + 重要度徽章 + 正文两行预览 +
/// 操作（打卡类型【打卡确认】/ 只提醒【知道了】+【查看详情】）。
/// 375px 宽下操作区用 Wrap 自动换行。
class _ManualNoticeCard extends StatelessWidget {
  const _ManualNoticeCard({
    required this.theme,
    required this.notice,
    required this.acked,
    required this.busy,
    required this.onAcknowledge,
    required this.onDismiss,
    required this.onOpenDetail,
  });

  final ThemeData theme;
  final Notice notice;
  final bool acked;
  final bool busy;
  final VoidCallback onAcknowledge;
  final VoidCallback onDismiss;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final requiresAck =
        notice.interactionMode == NoticeInteractionMode.acknowledge;
    final typeColor = notice.type.color;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: notice.priority == NoticePriority.urgent
            ? Border.all(color: scheme.error.withValues(alpha: 0.5))
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(notice.type.icon, size: 20, color: typeColor),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${notice.type.label} · ${notice.publisher} · '
                      '${_manualTime(notice.publishedAt)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (notice.priority.showBadge) ...[
                const SizedBox(width: UtenSpacing.s8),
                UtenStatusBadge(
                  label: notice.priority.label,
                  type: notice.priority == NoticePriority.urgent
                      ? UtenStatusBadgeType.danger
                      : UtenStatusBadgeType.warning,
                  size: UtenStatusBadgeSize.small,
                ),
              ],
            ],
          ),
          if (notice.content.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              notice.content,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s4,
            children: [
              TextButton(
                onPressed: busy ? null : onOpenDetail,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('查看详情'),
              ),
              if (requiresAck)
                acked
                    ? const _DoneChip(label: '已打卡')
                    : FilledButton.icon(
                        onPressed: busy ? null : onAcknowledge,
                        icon: busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.how_to_reg_rounded, size: 18),
                        label: const Text('打卡确认'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(96, 36),
                        ),
                      )
              else
                OutlinedButton(
                  onPressed: busy ? null : onDismiss,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(80, 36),
                  ),
                  child: const Text('知道了'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 「已打卡」完成态 chip（打卡成功后短暂展示再移除条目）。
class _DoneChip extends StatelessWidget {
  const _DoneChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 16,
            color: scheme.onPrimaryContainer,
          ),
          const SizedBox(width: UtenSpacing.s4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 人工通知发布时间：1 小时内「N 分钟前」、当天内「N 小时前」、一周内「N 天前」，
/// 其余显示日期（与通知列表卡片口径一致）。
String _manualTime(DateTime publishedAt) {
  final diff = ChinaDateTime.now().difference(publishedAt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return ChinaDateTime.formatDate(publishedAt);
}
