// 仓库任务中心仅保留大类、单据来源两行导航；作业阶段由状态表头查询。
// 生产领料归出库，生产退料归入库；旧 draw 深链按来源映射到对应方向。
// 大类与来源徽章沿用服务端本人/所选仓范围；旧领料徽章仅作兼容别名，
// 不重复进入模块合计。没有预选大类时显示引导，不请求列表。
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
import '../../../shared/drafts/form_draft_category.dart';
import '../../../shared/drafts/form_drafts_page.dart';
import '../../../shared/drafts/task_form_draft_recovery_notice.dart';
import '../widgets/warehouse_form_draft_categories.dart';
import '../../../shared/warehouse/warehouse_task_badges.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../config/warehouse_document_history_config.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../materialbin/widgets/workshop_material_task_center.dart';
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
  String? _workshopMaterialSection;
  int _workshopMaterialSelection = 0;

  @override
  void initState() {
    super.initState();
    _group = _initialGroup;
    if (_group == 'workshopMaterial') {
      _workshopMaterialSection = widget.initialSection;
    }
  }

  bool get _legacyReturn =>
      {'wdraw', 'productionReturn', 'RETURN'}.contains(widget.initialSection);

  String? get _initialGroup => widget.initialGroup == 'draw'
      ? (_legacyReturn ? 'inbound' : 'outbound')
      : widget.initialGroup;

  String? get _initialSection => widget.initialGroup == 'draw'
      ? (_legacyReturn ? 'RETURN' : 'DRAW')
      : widget.initialSection;

  @override
  void didUpdateWidget(covariant WarehouseTaskCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.initialGroup != oldWidget.initialGroup ||
            widget.initialSection != oldWidget.initialSection ||
            widget.initialView != oldWidget.initialView) &&
        widget.initialGroup != null) {
      _group = _initialGroup;
      if (_group == 'workshopMaterial') {
        _workshopMaterialSection = widget.initialSection;
        _workshopMaterialSelection++;
      }
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
    final canQuality = canOpen(RouteName.warehouseQualityResults);
    final canScReturn = canOpen(
      RouteName.warehouseSubcontractFinishedReturnHistory,
    );
    final canMasterDrafts = canOpen(RouteName.basicinfoWarehouse);
    final canReviewCounts = canOpen(RouteName.warehouseStockCountReview);
    // 独立授权的盘点审核人也从同一分类办理，不要求仓库发料权限。
    final canWorkshopMaterial = canOpen(RouteName.workshopMaterialIssue);
    final canCycleCount =
        canOpen(RouteName.workshopMaterialBin) &&
        canOpen(RouteName.workshopMaterialCount);
    // ADR-149: 大类数与各分段列表同一服务端仓库范围——没选仓 = 全站徽章汇总(服务端已按
    // 本人范围算); 选了仓 = 同一汇总接口带 scopeWarehouseId。不再用 list(size:1) 凑数。
    int todo(BadgeEntry entry) =>
        ref.watch(warehouseTaskEntryTodoProvider(entry));
    int inProgress(BadgeEntry entry) =>
        ref.watch(warehouseTaskEntryInProgressProvider(entry));
    // 红 = 待发料/退回与待审盘点(各按自己的入口); 黄仅真实周期盘点中。
    final workshopTodo =
        (canWorkshopMaterial ? todo(BadgeEntry.warehouseWorkshopMaterial) : 0) +
        (canReviewCounts ? todo(BadgeEntry.warehouseStockCountReview) : 0);
    final workshopInProgress = canCycleCount
        ? inProgress(BadgeEntry.warehouseWorkshopMaterial)
        : 0;
    // 本页其余文案尚未接 arb (部分既有测试不挂本地化代理), 取不到时回落中文原文。
    final workshopMaterialLabel =
        Localizations.of<AppLocalizations>(
          context,
          AppLocalizations,
        )?.workshopMaterialGroup ??
        '车间内料仓';

    // 大类计数与原 hub 四张卡同源（徽章汇总一次带回；未到/无权为 null 不渲染）。
    final groups = <_GroupSpec>[
      if (canOutbound)
        _GroupSpec(
          value: 'outbound',
          label: '出库',
          count:
              todo(BadgeEntry.warehouseOutboundCenter) +
              ref.watch<int>(
                formDraftCategoryCountProvider(warehouseDrawAllDraftScope),
              ) +
              ref.watch<int>(
                formDraftCategoryCountProvider(warehouseOutboundAllDraftScope),
              ),
        ),
      if (canInbound)
        _GroupSpec(
          value: 'inbound',
          label: '入库',
          count:
              todo(BadgeEntry.warehouseInboundCenter) +
              ref.watch<int>(
                formDraftCategoryCountProvider(warehouseInboundAllDraftScope),
              ),
        ),
      if (canQuality)
        _GroupSpec(
          value: 'quality',
          label: '品质检查结果',
          count: todo(BadgeEntry.warehouseQualityResult),
          inProgressCount: inProgress(BadgeEntry.warehouseQualityResult),
        ),
      if (canWorkshopMaterial || canReviewCounts || canCycleCount)
        _GroupSpec(
          value: 'workshopMaterial',
          label: workshopMaterialLabel,
          // 红 = 待发料/退回与待审盘点的独立入口并集；黄仅真实周期盘点中。
          count: workshopTodo,
          inProgressCount: workshopInProgress,
        ),
      if (canScReturn) const _GroupSpec(value: 'scReturn', label: '委外成品退货'),
    ];
    final activeGroup = groups.any((group) => group.value == _group)
        ? _group
        : null;

    // 大类行组件：选中大类后作为 externalHeader 传入正文，由分段视图挂进
    // 自己的折叠头一起随页滚走（2026-09-24「表格完全置顶」）。
    final categoryBar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TaskDraftRecoveryNotice(
          scope: FormDraftCategoryScope(module: BadgeModule.warehouse),
        ),
        UtenFilterToolbar<String>(
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
          selected: activeGroup == null ? const <String>{} : {activeGroup},
          onSelectionChanged: (value) => setState(() => _group = value),
          searchHint: '搜索单号 / 客户 / 供应商 / 委外商 / 货品',
          onSearchChanged: (value) => setState(() => _keyword = value.trim()),
        ),
      ],
    );

    if (groups.isEmpty && !canMasterDrafts && !canReviewCounts) {
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
          if (canMasterDrafts)
            const FormDraftsAppBarButton(categoryId: 'warehouse-master'),
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
            child: activeGroup == null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      categoryBar,
                      const SizedBox(height: UtenSpacing.s8),
                      const Expanded(child: _GroupPlaceholder()),
                    ],
                  )
                : _buildGroupBody(activeGroup, categoryBar),
          ),
        ),
      ),
    );
  }

  /// 当前大类的正文：三张方向任务中心与品质结果页以嵌入态整体复用
  ///（小类行、表格、办理动作与独立页完全一致）；委外两类为时间门控历史视图。
  Widget _buildGroupBody(String group, Widget categoryBar) => switch (group) {
    'drafts' => WarehouseFormDraftCategory(
      scope: warehouseMasterFormDraftScope,
      header: categoryBar,
      search: _keyword,
    ),
    'outbound' => WarehouseOutboundTaskCenterPage(
      key: const ValueKey('warehouse-outbound-direction'),
      embedded: true,
      externalKeyword: _keyword,
      externalRefreshTick: _refreshTick,
      initialSection: _initialSection,
      initialView: widget.initialView,
      externalHeader: categoryBar,
    ),
    'inbound' => WarehouseInboundTaskCenterPage(
      key: const ValueKey('warehouse-inbound-direction'),
      embedded: true,
      externalKeyword: _keyword,
      externalRefreshTick: _refreshTick,
      externalHeader: categoryBar,
      initialSection: _initialSection,
    ),
    'quality' => WarehouseQualityResultsPage(
      embedded: true,
      externalKeyword: _keyword,
      externalRefreshTick: _refreshTick,
      externalHeader: categoryBar,
    ),
    'workshopMaterial' => WorkshopMaterialTaskCenter(
      key: ValueKey(_workshopMaterialSelection),
      initialSection: _workshopMaterialSection,
      externalKeyword: _keyword,
      externalRefreshTick: _refreshTick,
      externalHeader: categoryBar,
    ),
    'scReturn' => WarehouseHistoryGate(
      key: const ValueKey('warehouse-subcontract-return-history'),
      timeKey: const Key('warehouse-task-center-sc-return-time'),
      externalHeader: categoryBar,
      builder: (time) => WarehouseDocumentHistoryView(
        type: WarehouseDocumentHistoryType.subcontractReturn,
        keyword: _keyword,
        refreshTick: _refreshTick,
        embedded: true,
        dateFrom: time.range == null
            ? null
            : ChinaDateTime.formatDate(time.range!.start),
        dateTo: time.range == null
            ? null
            : ChinaDateTime.formatDate(time.range!.end),
      ),
    ),
    _ => const _GroupPlaceholder(),
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
