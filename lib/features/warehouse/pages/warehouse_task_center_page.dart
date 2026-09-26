// 仓库任务中心（/warehouse/tasks）—— 2026-09-24 四卡合并的一站式入口。
//
// 背景（2026-09-24 模块三段式统一，docs/01-规划/2026-09-24-模块三段式统一*.md）：
// 仓库 hub 原本并排四张任务中心卡（出库/入库/生产领料/品质部检查结果）+ 两张
// 历史只读卡，用户口径「任务中心一堆 要不要汇总」。本页把六类收拢为一个页面：
//
//   大类（第一行）= 出库 / 入库 / 生产领料 / 品质检查结果 / 委外成品退货 / 委外损耗
//   小类（第二行起）= 原三张任务中心页各自的分段（嵌入态复用整页能力）；
//   品质检查结果大类内保留其来源行 + 状态行；委外两类为时间门控的历史视图。
//
// 徽章口径（准则 14 不变）：
//   · 出库/入库/领料/品质四个大类的红数 = 原 hub 四张卡同源入口
//    （BadgeEntry.warehouseOutboundCenter / warehouseInboundCenter /
//     warehouseDrawCenter / warehouseQualityResult）；品质大类另挂黄数
//    （等待检查结果，badgeEntryInProgressProvider 同源）。
//   · 委外成品退货 / 委外损耗是历史只读大类，不挂数（准则 14 §二）。
//   · hub「仓库任务中心」卡角标 = 模块两枚药丸同源（BadgeModule.warehouse）。
//
// 旧三路由 /warehouse/tasks/{outbound|inbound|draw} 与 /warehouse/quality-results
// 路由保留（通知深链/收藏直达），构建本页并预设对应大类；?section=/?view=
// 参数原样透传给出库小类。进页面不预选大类（未选显示引导空态，不发请求）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../config/warehouse_document_history_config.dart';
import '../pages/warehouse_draw_task_center_page.dart';
import '../pages/warehouse_inbound_task_center_page.dart';
import '../pages/warehouse_outbound_task_center_page.dart';
import '../pages/warehouse_quality_results_page.dart';
import '../providers/warehouse_count_refresh.dart';
import '../widgets/warehouse_document_history_view.dart';
import '../widgets/warehouse_history_gate.dart';
import '../widgets/warehouse_scope_selector.dart';

/// 一个大类分段（含待办/在办计数与可见性）。
class _GroupSpec {
  const _GroupSpec({
    required this.value,
    required this.label,
    this.count,
    this.inProgressCount,
  });

  final String value;
  final String label;
  final int? count;
  final int? inProgressCount;
}

class WarehouseTaskCenterPage extends ConsumerStatefulWidget {
  const WarehouseTaskCenterPage({
    super.key,
    this.initialGroup,
    this.initialSection,
    this.initialView,
  });

  /// 深链预设大类（旧三路由 /warehouse/tasks/{outbound|inbound|draw} 构建）。
  final String? initialGroup;

  /// 出库小类深链（?section=，透传给出库任务中心）。
  final String? initialSection;

  /// 出库·委外出库视图深链（?view=tasks）。
  final String? initialView;

  @override
  ConsumerState<WarehouseTaskCenterPage> createState() =>
      _WarehouseTaskCenterPageState();
}

class _WarehouseTaskCenterPageState
    extends ConsumerState<WarehouseTaskCenterPage> {
  /// 当前选中大类；null = 未选择引导态（不发请求）。
  String? _group;
  String _keyword = '';
  String? _myLocation;
  int _refreshTick = 0;

  @override
  void initState() {
    super.initState();
    _group = widget.initialGroup;
  }

  @override
  void didUpdateWidget(covariant WarehouseTaskCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialGroup != oldWidget.initialGroup &&
        widget.initialGroup != null) {
      _group = widget.initialGroup;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _myLocation ??= currentLocationOr(context, RouteName.warehouseTasks);
    // 返回本页：重拉任务中心各计数（大类徽章/模块药丸同源）并推进分段刷新。
    ref.onPageResume(_myLocation!, () {
      setState(() => _refreshTick++);
      invalidateWarehouseTaskCounts(ref);
    });
    // 仓库范围变化：分段与计数按新范围重拉（嵌入的三张任务中心也各自监听）。
    ref.listen<WarehouseTaskScope>(warehouseTaskScopeProvider, (
      previous,
      next,
    ) {
      if (previous == null || previous == next) return;
      setState(() => _refreshTick++);
      invalidateWarehouseTaskCounts(ref);
    });

    // 大类可见性 = 对应旧任务中心路由的守卫（locationAllowedFor 与路由守卫
    // 同一份 any/all 契约，页面里不手写权限清单——与 hub 卡同一判定）。
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool canOpen(String location) =>
        locationAllowedFor(permissions, superAdmin, location);

    final canOutbound = canOpen(RouteName.warehouseOutboundTasks);
    final canInbound = canOpen(RouteName.warehouseInboundTasks);
    final canDraw = canOpen(RouteName.warehouseDrawTasks);
    final canQuality = canOpen(RouteName.warehouseQualityResults);
    final canScReturn = canOpen(
      RouteName.warehouseSubcontractFinishedReturnHistory,
    );
    final canScWaste = canOpen(RouteName.warehouseSubcontractWasteHistory);

    // 大类计数与原 hub 四张卡同源（徽章汇总一次带回；未到/无权为 null 不渲染）。
    final groups = <_GroupSpec>[
      if (canOutbound)
        _GroupSpec(
          value: 'outbound',
          label: '出库',
          count: ref.watch(
            badgeEntryTodoProvider(BadgeEntry.warehouseOutboundCenter),
          ),
        ),
      if (canInbound)
        _GroupSpec(
          value: 'inbound',
          label: '入库',
          count: ref.watch(
            badgeEntryTodoProvider(BadgeEntry.warehouseInboundCenter),
          ),
        ),
      if (canDraw)
        _GroupSpec(
          value: 'draw',
          label: '生产领料',
          count: ref.watch(
            badgeEntryTodoProvider(BadgeEntry.warehouseDrawCenter),
          ),
        ),
      if (canQuality)
        _GroupSpec(
          value: 'quality',
          label: '品质检查结果',
          count: ref.watch(
            badgeEntryTodoProvider(BadgeEntry.warehouseQualityResult),
          ),
          inProgressCount: ref.watch(
            badgeEntryInProgressProvider(BadgeEntry.warehouseQualityResult),
          ),
        ),
      if (canScReturn) const _GroupSpec(value: 'scReturn', label: '委外成品退货'),
      if (canScWaste) const _GroupSpec(value: 'scWaste', label: '委外损耗'),
    ];

    // 大类行组件：选中大类后作为 externalHeader 传入正文，由分段视图挂进
    // 自己的折叠头一起随页滚走（2026-09-24「表格完全置顶」）。
    final categoryBar = UtenFilterToolbar<String>(
      segmentsKey: const Key('warehouse-task-center-groups'),
      searchKey: const Key('warehouse-task-center-search'),
      segments: [
        for (final g in groups)
          UtenFilterSegment(
            value: g.value,
            label: g.label,
            count: g.count,
            // 大类计数只有待办语义（与合并前三张卡角标同口径）；
            // 浏览型大类传 null。
            countForm: UtenSegmentCountForm.actionable,
            inProgressCount: g.inProgressCount,
          ),
      ],
      selected: _group == null ? const <String>{} : {_group!},
      onSelectionChanged: (value) => setState(() => _group = value),
      searchHint: '搜索单号 / 客户 / 供应商 / 委外商 / 货品',
      onSearchChanged: (value) => setState(() => _keyword = value.trim()),
    );

    if (groups.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('仓库任务中心')),
        body: Center(
          child: Text(
            '暂无已授权的仓库任务页面，请联系仓库主管开通。',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '仓库任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          const WarehouseScopeSelector(),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () {
              setState(() => _refreshTick++);
              invalidateWarehouseTaskCounts(ref);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            // 选中大类：大类行随正文进分段视图折叠头（滑到头只剩表格工具条）；
            // 未选大类：大类行钉在占位区上方。
            child: _group == null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      categoryBar,
                      const SizedBox(height: UtenSpacing.s12),
                      const Expanded(child: _GroupPlaceholder()),
                    ],
                  )
                : _buildGroupBody(_group!, categoryBar),
          ),
        ),
      ),
    );
  }

  /// 当前大类的正文：三张方向任务中心与品质结果页以嵌入态整体复用
  ///（小类行、表格、办理动作与独立页完全一致）；委外两类为时间门控历史视图。
  Widget _buildGroupBody(String group, Widget categoryBar) => switch (group) {
    'outbound' => WarehouseOutboundTaskCenterPage(
      embedded: true,
      externalKeyword: _keyword,
      externalRefreshTick: _refreshTick,
      initialSection: widget.initialSection,
      initialView: widget.initialView,
      externalHeader: categoryBar,
    ),
    'inbound' => WarehouseInboundTaskCenterPage(
      embedded: true,
      externalKeyword: _keyword,
      externalRefreshTick: _refreshTick,
      externalHeader: categoryBar,
    ),
    'draw' => WarehouseDrawTaskCenterPage(
      embedded: true,
      externalKeyword: _keyword,
      externalRefreshTick: _refreshTick,
      externalHeader: categoryBar,
    ),
    'quality' => WarehouseQualityResultsPage(
      embedded: true,
      externalKeyword: _keyword,
      externalRefreshTick: _refreshTick,
      externalHeader: categoryBar,
    ),
    'scReturn' => WarehouseHistoryGate(
      timeKey: const Key('warehouse-task-center-sc-return-time'),
      builder: (time) => WarehouseDocumentHistoryView(
        type: WarehouseDocumentHistoryType.subcontractReturn,
        keyword: _keyword,
        refreshTick: _refreshTick,
        embedded: true,
        externalHeader: categoryBar,
        dateFrom: time.range == null
            ? null
            : ChinaDateTime.formatDate(time.range!.start),
        dateTo: time.range == null
            ? null
            : ChinaDateTime.formatDate(time.range!.end),
      ),
    ),
    _ => WarehouseHistoryGate(
      timeKey: const Key('warehouse-task-center-sc-waste-time'),
      builder: (time) => WarehouseDocumentHistoryView(
        type: WarehouseDocumentHistoryType.subcontractWaste,
        keyword: _keyword,
        refreshTick: _refreshTick,
        embedded: true,
        externalHeader: categoryBar,
        dateFrom: time.range == null
            ? null
            : ChinaDateTime.formatDate(time.range!.start),
        dateTo: time.range == null
            ? null
            : ChinaDateTime.formatDate(time.range!.end),
      ),
    ),
  };
}

/// 大类未选时的内容区占位：进页面不预选，引导先选分类。
class _GroupPlaceholder extends StatelessWidget {
  const _GroupPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '请先在上方选择分类',
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.touch_app_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text('在上方选择分类后开始办理', style: theme.textTheme.titleSmall),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '分段右侧数字徽章为该分类的待办数量',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
