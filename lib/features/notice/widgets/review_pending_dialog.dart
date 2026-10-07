// ReviewPendingDialog —— 审核待办居中弹窗（V459/ADR-063；2026-09-03 第四轮口径）
//
// 一个待审事件的三种提醒形态并存：通知中心条目 + 顶部通知条（纯显示）+ 本居中弹窗。
// 本弹窗承载主交互：
// - 登录检查（ReviewPendingLoginGate）与在线到达（dispatchReviewCard）共用；
// - 在线多事件同到：先弹一条，后续待办**并入同一弹窗**（「一共有 N 项」），不再丢弃；
// - 弹窗内实时显示「是否有人在处理」（30s 心跳 pending-review-status：
//   他人认领 → 「XX 正在审核」tertiaryContainer 认领 chip；办结 → 条目自动移除，清空则弹窗自关）；
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
// 分级体系（2026-10-06，ADR-163）：条目按 (type, priority, interactive/manual)
// 归入紧急/行动/进度/广播四档视觉级别（见 [ReviewNoticeLevel]），颜色+图标+
// 徽章三重编码；排序 紧急 > 行动 > 进度 > 广播。修订（2026-10-06）：审批/
// 工作流类(type=approval/workflow)一律行动级，不受 priority=normal 降级。
// 文档：docs/02-组件库/ReviewPendingDialog.md

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
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
  'SALES_SHIPMENT_PENDING_FINANCE_AUDIT' => RouteName.financeSalesShipmentAudit,
  // ADR-134 报价待财务核价：落核价队列(待核价分段)。
  'SALES_QUOTE_PENDING_FINANCE_REVIEW' => RouteName.financeQuoteReview,
  'PROCUREMENT_FINANCE_SUBMITTED' ||
  'PROCUREMENT_FINANCE_CHANGE_SUBMITTED' => '/finance/procurement-approvals',
  'PROCUREMENT_IQC_PENDING' => RouteName.qualityTaskCenter,
  'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP' => RouteName.salesOrderProgress,
  'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED' =>
    RouteName.productionWorkshopTasks,
  'PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED' =>
    RouteName.productionOverproductionRateRequests,
  'PRODUCTION_MATERIAL_INCREMENT_SUBMITTED' =>
    RouteName.productionMaterialIncrementRequests,
  'SALES_ORDER_APPROVED' => RouteName.productionMaterialAnalysis,
  // ADR-143 委外可领料：落委外任务中心「领料」分段(通知自带定位时沿用)。
  'SUBCONTRACT_DRAW_AVAILABLE' =>
    actionRoute != null &&
            actionRoute.startsWith(RouteName.operationsSubcontractWorkbench)
        ? actionRoute
        : RouteName.operationsSubcontractDrawSegment(),
  // ADR-156 委外可下单(直属物料齐套)：落委外任务中心「待处理」分段(通知自带申请号时沿用)。
  'SUBCONTRACT_ORDER_KIT_READY' =>
    actionRoute != null &&
            actionRoute.startsWith(RouteName.operationsSubcontractWorkbench)
        ? actionRoute
        : RouteName.operationsSubcontractPendingSegment(),
  'SUBCONTRACT_OUTBOUND_READY' => RouteName.warehouseSubcontractOutbound,
  // ADR-117 车间催计划：直落被催的那一份物料分析(?analysisId=)。
  'PRODUCTION_PLANNING_URGED' =>
    actionRoute != null &&
            actionRoute.startsWith('${RouteName.productionMaterialAnalysis}?')
        ? actionRoute
        : RouteName.productionMaterialAnalysis,
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
  'EXPENSE_CLAIM_REJECTED' => RouteName.expense,
  'PAYROLL_BATCH_SUBMITTED' ||
  'PAYROLL_BATCH_PENDING_PUBLISH' => '/payroll/review',
  // 建议箱列表默认「建议广场」（全部建议），scope 是页面状态不是 URL 参数。
  'SUGGESTION_SUBMITTED' => RouteName.suggestion,
  _ => RouteName.dashboard,
};

// ========================= 分级体系（2026-10-06，ADR-163） =========================
//
// 用户痛点：几十种事件此前全部同一个 teal 样式，无法一眼识别类型与轻重。
// 分级按 (priority, interactive/manual) 归档，每级「颜色 + 图标 + 徽章文字」
// 三重编码——色弱/色盲下徽章文字与图标形状仍可区分级别。

/// 中央提醒弹窗条目的视觉级别。**枚举顺序即排序权重**
/// （urgent 置顶 → action → progress → broadcast 垫底）。
enum ReviewNoticeLevel {
  /// 紧急（红系）：priority=urgent，含人工紧急公告。error 描边 + 左侧竖红条 +
  /// 「紧急」红底白字徽章，排序置顶。
  urgent,

  /// 行动待办（teal 品牌色）：审批/工作流类（type=approval/workflow）一律归
  /// 此级（priority=normal 也不降级，2026-10-06 修订）；其余 interactive &&
  /// important 同级。保持既有 teal primaryContainer 风格（现样式微调强化），
  /// 「待办」teal 底徽章。
  action,

  /// 进度跟踪（info 蓝系）：task/其余 interactive 类型 && normal（物料到货
  /// 进展等）。视觉权重低于行动卡（更紧凑行高），「进度」蓝底徽章。
  progress,

  /// 人事广播（amber 暖色）：人工通知组（非 urgent）。暖色容器与 urgent 的红
  /// 拉开色相（amber 偏黄、error 偏红），「公告」琥珀底徽章。
  broadcast,
}

/// 条目 → 视觉级别。urgent 一票置顶（interactive 与人工通知同归 urgent）；
/// 审批/工作流类（type=approval/workflow）一律行动级——审批事件（如
/// SALES_ORDER_PENDING_FINANCE_CONFIRM、PROCUREMENT_FINANCE_SUBMITTED）后端
/// 多标 priority=normal，但语义是「待我决定」的强待办，不得落最低权重的
/// 进度级（2026-10-06 修订）；task 类按 important/normal 分行动/进度——
/// 同一 sourceEvent（如车间物料事件）因 priority 不同落不同级别：
/// 「可开工行动卡」=行动、「到货进展」=进度；其余 interactive 类型同此
/// 分级；人工通知为广播。
ReviewNoticeLevel reviewNoticeLevelOf(Notice notice) {
  if (notice.priority == NoticePriority.urgent) return ReviewNoticeLevel.urgent;
  if (!notice.interactive) return ReviewNoticeLevel.broadcast;
  if (notice.type == NoticeType.approval ||
      notice.type == NoticeType.workflow) {
    return ReviewNoticeLevel.action;
  }
  return notice.priority == NoticePriority.important
      ? ReviewNoticeLevel.action
      : ReviewNoticeLevel.progress;
}

/// 弹窗内排序：urgent > action > progress > broadcast；同级保持到达顺序
/// （[List.sort] 不稳定，先记录原始下标再按 (级别, 下标) 排）。
List<Notice> sortByReviewLevel(List<Notice> items) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final byLevel = reviewNoticeLevelOf(
      a.$2,
    ).index.compareTo(reviewNoticeLevelOf(b.$2).index);
    return byLevel != 0 ? byLevel : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

/// 单级视觉语言（明暗主题各自成对的容器色 + 强调色 + 徽章图标/底色）。
class _LevelStyle {
  const _LevelStyle({
    required this.iconContainer,
    required this.onIconContainer,
    required this.accent,
    required this.badgeContainer,
    required this.badgeForeground,
    required this.badgeIcon,
    required this.dense,
  });

  /// 图标底容器色。
  final Color iconContainer;

  /// 图标底上的图标色。
  final Color onIconContainer;

  /// 强调色（计数色点 / urgent 描边与标题色）。
  final Color accent;

  /// 级别徽章底色（urgent 用 dangerStrong 实底白字，其余用容器对浅底深字）。
  final Color badgeContainer;

  final Color badgeForeground;

  final IconData badgeIcon;

  /// 进度级更紧凑的行高（视觉权重低于行动卡）。
  final bool dense;
}

_LevelStyle _levelStyleOf(ThemeData theme, ReviewNoticeLevel level) {
  final scheme = theme.colorScheme;
  final dark = theme.brightness == Brightness.dark;
  return switch (level) {
    ReviewNoticeLevel.urgent => _LevelStyle(
      iconContainer: scheme.errorContainer,
      onIconContainer: scheme.onErrorContainer,
      accent: scheme.error,
      // 红底白字实底徽章（与「红徽章」计数口径同对：dangerStrong + 白）。
      badgeContainer: UtenColors.dangerStrong,
      badgeForeground: Colors.white,
      badgeIcon: Icons.priority_high_rounded,
      dense: false,
    ),
    ReviewNoticeLevel.action => _LevelStyle(
      iconContainer: scheme.primaryContainer,
      onIconContainer: scheme.onPrimaryContainer,
      accent: scheme.primary,
      badgeContainer: scheme.primaryContainer,
      badgeForeground: scheme.onPrimaryContainer,
      badgeIcon: Icons.task_alt_rounded,
      dense: false,
    ),
    ReviewNoticeLevel.progress => _LevelStyle(
      iconContainer: dark
          ? UtenColors.infoContainerDark
          : UtenColors.infoContainer,
      onIconContainer: dark
          ? UtenColors.onInfoContainerDark
          : UtenColors.onInfoContainer,
      accent: dark ? UtenColors.infoOnDark : UtenColors.info,
      badgeContainer: dark
          ? UtenColors.infoContainerDark
          : UtenColors.infoContainer,
      badgeForeground: dark
          ? UtenColors.onInfoContainerDark
          : UtenColors.onInfoContainer,
      badgeIcon: Icons.trending_up_rounded,
      dense: true,
    ),
    ReviewNoticeLevel.broadcast => _LevelStyle(
      iconContainer: dark
          ? UtenColors.broadcastContainerDark
          : UtenColors.broadcastContainer,
      onIconContainer: dark
          ? UtenColors.onBroadcastContainerDark
          : UtenColors.onBroadcastContainer,
      accent: dark ? UtenColors.warningOnDark : UtenColors.warning,
      badgeContainer: dark
          ? UtenColors.broadcastContainerDark
          : UtenColors.broadcastContainer,
      badgeForeground: dark
          ? UtenColors.onBroadcastContainerDark
          : UtenColors.onBroadcastContainer,
      badgeIcon: Icons.campaign_rounded,
      dense: false,
    ),
  };
}

String _levelLabel(AppLocalizations l10n, ReviewNoticeLevel level) =>
    switch (level) {
      ReviewNoticeLevel.urgent => l10n.noticeLevelUrgent,
      ReviewNoticeLevel.action => l10n.noticeLevelAction,
      ReviewNoticeLevel.progress => l10n.noticeLevelProgress,
      ReviewNoticeLevel.broadcast => l10n.noticeLevelBroadcast,
    };

/// 级别徽章：图标 + 文字（不只靠颜色——色弱下徽章文字仍可辨级）。
class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.style, required this.label});

  final _LevelStyle style;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: style.badgeContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.badgeIcon, size: 12, color: style.badgeForeground),
          const SizedBox(width: 3),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: style.badgeForeground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

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
    if (routes.length == 1) return routes.first;
    // 同一个工作台、只是深链参数不同(如几张催计划卡指向不同的物料分析)：落到该工作台本身。
    final paths = {for (final route in routes) Uri.parse(route).path};
    return paths.length == 1 ? paths.first : RouteName.dashboard;
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
    // 分级排序（ADR-163）：urgent → action → progress → broadcast，同级保持到达序。
    final sortedReviews = sortByReviewLevel(_items);
    final sortedManual = sortByReviewLevel(_manualItems);
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
              _Header(theme: theme, items: sortedReviews, manual: sortedManual),
              const SizedBox(height: UtenSpacing.s16),
              Flexible(
                child: singleReviewOnly
                    ? SingleChildScrollView(
                        child: _LargeItemCard(
                          theme: theme,
                          notice: sortedReviews.first,
                          status: _statusById[sortedReviews.first.id],
                          onTap: () => _openWorkbench(),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          // 分组顺序（ADR-163）：待办审核组在前（urgent → action →
                          // progress），人事广播组垫底（组内 urgent 人工条目仍置组首）。
                          if (sortedReviews.isNotEmpty) ...[
                            if (_manualItems.isNotEmpty)
                              _GroupLabel(
                                theme: theme,
                                label: '待办审核',
                                count: sortedReviews.length,
                              ),
                            for (final item in sortedReviews)
                              Padding(
                                key: ValueKey('review-${item.id}'),
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
                          if (sortedManual.isNotEmpty) ...[
                            _GroupLabel(
                              theme: theme,
                              label: '人事/公司通知',
                              count: sortedManual.length,
                            ),
                            for (final item in sortedManual)
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
    final l10n = AppLocalizations.of(context);
    final hasReviews = items.isNotEmpty;
    final count = items.length + manual.length;
    // 分级计数摘要（ADR-163）：按视觉级别带色点聚合（「紧急 1 · 待办 2 · 进度 1 ·
    // 公告 1」），取代旧事件域分组 chips——级别一眼可辨，域信息仍在条目卡上。
    final levelCounts = <ReviewNoticeLevel, int>{};
    for (final notice in [...items, ...manual]) {
      final level = reviewNoticeLevelOf(notice);
      levelCounts[level] = (levelCounts[level] ?? 0) + 1;
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
                if (count > 1) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final level in ReviewNoticeLevel.values)
                        if ((levelCounts[level] ?? 0) > 0)
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
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _levelStyleOf(theme, level).accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  l10n.noticeLevelSummary(
                                    _levelLabel(l10n, level),
                                    levelCounts[level]!,
                                  ),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSecondaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
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

IconData _eventIcon(String? sourceEvent) => switch (sourceEvent) {
  'SALES_ORDER_PENDING_FINANCE_CONFIRM' => Icons.request_quote_outlined,
  'PROCUREMENT_FINANCE_SUBMITTED' => Icons.approval_outlined,
  'PROCUREMENT_IQC_PENDING' => Icons.science_outlined,
  'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP' => Icons.local_shipping_outlined,
  'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED' =>
    Icons.precision_manufacturing_outlined,
  'PRODUCTION_PLANNING_URGED' => Icons.campaign_outlined,
  'PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED' => Icons.percent_rounded,
  'PRODUCTION_MATERIAL_INCREMENT_SUBMITTED' => Icons.playlist_add_check_rounded,
  // 人事域（HrNoticeService）
  'PROFILE_CHANGE_SUBMITTED' => Icons.badge_outlined,
  'VISITOR_APPLY_SUBMITTED' => Icons.person_add_alt_outlined,
  'VISITOR_HOST_CONFIRM_REQUIRED' => Icons.handshake_outlined,
  'EXPENSE_CLAIM_SUBMITTED' => Icons.receipt_long_outlined,
  'EXPENSE_CLAIM_PENDING_PAYMENT' => Icons.payments_outlined,
  'EXPENSE_CLAIM_REJECTED' => Icons.edit_note_outlined,
  'PAYROLL_BATCH_SUBMITTED' => Icons.request_quote_outlined,
  'PAYROLL_BATCH_PENDING_PUBLISH' => Icons.publish_outlined,
  'SUGGESTION_SUBMITTED' => Icons.lightbulb_outline,
  _ => Icons.fact_check_outlined,
};

/// 单条：大卡布局（图标+标题+摘要+状态+操作提示）。行动/紧急级的主力形态
/// （ADR-163：urgent=红系强化——error 描边 + 左竖红条 + 标题 error w700；
/// action=teal 现风格；progress=info 蓝、更紧凑）。
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
    final l10n = AppLocalizations.of(context);
    final level = reviewNoticeLevelOf(notice);
    final style = _levelStyleOf(theme, level);
    final urgent = level == ReviewNoticeLevel.urgent;
    final claimedBy = status?.claimedByName;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        // clip 让左侧竖红条贴着圆角裁齐。
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: urgent
              ? scheme.errorContainer.withValues(alpha: 0.45)
              : level == ReviewNoticeLevel.progress
              ? scheme.surfaceContainerLow
              : scheme.secondaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: urgent
                ? scheme.error
                : scheme.outlineVariant.withValues(alpha: 0.6),
            width: urgent ? 1.5 : 1,
          ),
        ),
        // IntrinsicHeight：列表项高度不定（unbounded），让左竖条 stretch 到整卡高。
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左侧竖红条（urgent 专属形状编码——色盲下仍可辨）。
              if (urgent) Container(width: 4, color: scheme.error),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.all(
                    style.dense ? UtenSpacing.s12 : UtenSpacing.s16,
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
                            width: style.dense ? 36 : 40,
                            height: style.dense ? 36 : 40,
                            decoration: BoxDecoration(
                              color: style.iconContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              _eventIcon(notice.sourceEvent),
                              size: style.dense ? 20 : 22,
                              color: style.onIconContainer,
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          Expanded(
                            child: Text(
                              notice.title,
                              style: urgent
                                  ? theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: scheme.error,
                                    )
                                  : theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          _LevelBadge(
                            style: style,
                            label: _levelLabel(l10n, level),
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
                          // 到料、尚缺和领料提示是一条完整业务信息，不能截断其后半段。
                          maxLines:
                              notice.sourceEvent ==
                                  'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'
                              ? null
                              : 3,
                          overflow:
                              notice.sourceEvent ==
                                  'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s12),
                      _ClaimChip(theme: theme, claimedByName: claimedBy),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 多条：紧凑行（图标+标题+时间+状态 chip）。进度类进紧凑形态且行高更矮
/// （dense，视觉权重低于行动卡）；urgent 用红系强化（描边+竖条+error 标题）。
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
    final l10n = AppLocalizations.of(context);
    final level = reviewNoticeLevelOf(notice);
    final style = _levelStyleOf(theme, level);
    final urgent = level == ReviewNoticeLevel.urgent;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: urgent
              ? scheme.errorContainer.withValues(alpha: 0.45)
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: urgent ? Border.all(color: scheme.error, width: 1.5) : null,
        ),
        // IntrinsicHeight：列表项高度不定（unbounded），让左竖条 stretch 到整行高。
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (urgent) Container(width: 3, color: scheme.error),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s12,
                    vertical: style.dense ? UtenSpacing.s8 : UtenSpacing.s12,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: style.iconContainer,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Icon(
                          _eventIcon(notice.sourceEvent),
                          size: 18,
                          color: style.onIconContainer,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              notice.title,
                              style: urgent
                                  ? theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: scheme.error,
                                    )
                                  : theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w500,
                                    ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (notice.sourceEvent ==
                                    'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED' &&
                                notice.content.isNotEmpty) ...[
                              const SizedBox(height: UtenSpacing.s8),
                              Text(
                                notice.content,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      _LevelBadge(
                        style: style,
                        label: _levelLabel(l10n, level),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      _ClaimChip(
                        theme: theme,
                        claimedByName: status?.claimedByName,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 认领状态 chip：他人处理中（tertiaryContainer 认领 chip）/ 待处理
/// （primaryContainer）——「对应的人是否操作」。
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

/// 人工通知条目：类型图标 + 标题 + 发布人·时间 + 级别徽章 + 正文两行预览 +
/// 操作（打卡类型【打卡确认】/ 只提醒【知道了】+【查看详情】）。
/// 375px 宽下操作区用 Wrap 自动换行。
/// ADR-163：广播级 = 暖色容器底（amber，与 urgent 红拉开色相）；人工紧急 =
/// 红系强化（errorContainer 底 + 1.5px error 描边 + 紧急红徽章，组内置顶）。
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
    final l10n = AppLocalizations.of(context);
    final requiresAck =
        notice.interactionMode == NoticeInteractionMode.acknowledge;
    final typeColor = notice.type.color;
    final level = reviewNoticeLevelOf(notice);
    final style = _levelStyleOf(theme, level);
    final urgent = level == ReviewNoticeLevel.urgent;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: urgent
            ? scheme.errorContainer.withValues(alpha: 0.45)
            : style.iconContainer,
        borderRadius: BorderRadius.circular(12),
        border: urgent ? Border.all(color: scheme.error, width: 1.5) : null,
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
              // 级别徽章（ADR-163）：人工紧急=红底白字「紧急」，其余人工=琥珀底
              // 「公告」——徽章文字不同，色弱下与 urgent 红仍可区分。
              const SizedBox(width: UtenSpacing.s8),
              _LevelBadge(style: style, label: _levelLabel(l10n, level)),
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
