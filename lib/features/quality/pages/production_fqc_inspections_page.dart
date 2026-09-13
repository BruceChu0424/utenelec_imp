import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../warehouse/providers/production_finished_inbound_task_count_provider.dart';
import '../models/production_fqc_inspection.dart';
import '../repositories/production_fqc_repository.dart';
import '../widgets/production_fqc_dialogs.dart';
import 'quality_batch_approval_page.dart';

class ProductionFqcInspectionsPage extends ConsumerStatefulWidget {
  const ProductionFqcInspectionsPage({super.key});

  @override
  ConsumerState<ProductionFqcInspectionsPage> createState() =>
      _ProductionFqcInspectionsPageState();
}

class _ProductionFqcInspectionsPageState
    extends ConsumerState<ProductionFqcInspectionsPage> {
  PagedResult<ProductionFqcInspection>? _result;
  bool _loading = false;
  String? _error;
  String _status = 'ACTIVE';
  String _keyword = '';
  int _requestVersion = 0;
  bool _canDecideByScope = false;
  final Set<String> _selectedIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({int? page}) async {
    final requestVersion = ++_requestVersion;
    final requestedPage = page ?? _result?.page ?? 1;
    final requestedStatus = _status;
    final requestedKeyword = _keyword;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(productionFqcRepositoryProvider);
      final permissions = ref.read(currentPermissionsProvider);
      final mayApprove =
          ref.read(isSuperAdminProvider) ||
          permissions.contains(Perm.productionQualityInspectionApprove);
      var canDecideByScope = false;
      if (mayApprove) {
        try {
          canDecideByScope = await repository.canDecide();
        } catch (_) {
          // Fail closed for the write button; task reading remains available.
        }
      }
      final result = await repository.list(
        status: requestedStatus,
        keyword: requestedKeyword,
        page: requestedPage,
      );
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _canDecideByScope = canDecideByScope;
        _loading = false;
        final currentIds = result.items.map((item) => item.id).toSet();
        _selectedIds.removeWhere((id) => !currentIds.contains(id));
      });
      ref.invalidate(productionFqcPendingCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '生产成品质检任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _switchStatus(String status) async {
    if (_status == status) return;
    setState(() => _status = status);
    await _load(page: 1);
  }

  void _onSearchInput(String value) {
    if (_keyword == value) return;
    _keyword = value;
    _requestVersion++;
  }

  Future<void> _applySearch(String value) async {
    final normalized = value.trim();
    if (_keyword != normalized) _keyword = normalized;
    await _load(page: 1);
  }

  /// 双击行 / 右键「办理质检」：进入 FQC 单任务办理页（2026-09-12 弹窗改页，
  /// 对齐采购 IQC 处置页——详情事实 + 合格/不合格数量 + 提交报告 + 检验证据）。
  Future<void> _openHandling(
    ProductionFqcInspection inspection, {
    required bool canApprove,
  }) async {
    // 页面决定成功后带结果返回：先本地落位（刷新失败也保得住「已决定」事实），
    // 再重拉列表与角标。
    final decided = await context.push<ProductionFqcInspection>(
      RouteName.productionFqcInspectionHandling(inspection.id),
      extra: inspection,
    );
    if (!mounted) return;
    if (decided != null) {
      _applyDecisionResult(decided);
    }
    ref.invalidate(productionFqcPendingCountProvider);
    ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
    await _load(page: _result?.page ?? 1);
  }

  /// 决定成功先本地落位（决定行保留为 PARTIAL 或移除 RESOLVED），刷新失败也不回滚。
  void _applyDecisionResult(ProductionFqcInspection updated) {
    final current = _result;
    if (current == null) return;
    final items = [...current.items];
    final index = items.indexWhere((item) => item.id == updated.id);
    if (index < 0) return;
    final remainsVisible = _matchesCurrentFilter(updated);
    if (remainsVisible) {
      items[index] = updated;
    } else {
      items.removeAt(index);
    }
    final total = (current.total + (remainsVisible ? 0 : -1)).clamp(0, 1 << 31);
    setState(() {
      _result = PagedResult(
        items: items,
        page: current.page,
        size: current.size,
        total: total,
        totalPages: total == 0 ? 0 : (total + current.size - 1) ~/ current.size,
      );
      if (!remainsVisible) _selectedIds.remove(updated.id);
    });
  }

  bool _matchesCurrentFilter(ProductionFqcInspection item) {
    final statusMatch = switch (_status) {
      'ACTIVE' => item.active,
      'ALL' => true,
      _ => item.status == _status,
    };
    if (!statusMatch) return false;
    final keyword = _keyword.trim().toLowerCase();
    if (keyword.isEmpty) return true;
    final text = [
      item.reportNo,
      item.planNo,
      item.goodsCode,
      item.goodsName,
      item.colorName,
    ].whereType<String>().join(' ').toLowerCase();
    return text.contains(keyword);
  }

  void _setSelectedIds(Set<String> next) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(next);
    });
  }

  /// 右下角「批量审批」（2026-09-12 与待检处置统一）：所选任务进批量审批汇总页
  ///（默认全勾 = 全部合格），页面里可再取消/调整后一次「提交报告」。
  Future<void> _openBatchApproval(Set<String> selectedIds) async {
    if (selectedIds.isEmpty) {
      context.appWarning('请先选择待处理质检任务');
      return;
    }
    final inspections = [
      for (final item in _result?.items ?? const <ProductionFqcInspection>[])
        if (selectedIds.contains(item.id) && item.active) item,
    ];
    if (inspections.isEmpty) {
      context.appWarning('所选任务状态已变化，请刷新后重新选择');
      return;
    }
    final done = await context.push<bool>(
      RouteName.warehouseInspectionBatchApproval,
      extra: QualityBatchApprovalSelection(inspections: inspections),
    );
    if (!mounted) return;
    setState(() => _selectedIds.clear());
    if (done == true) await _load(page: _result?.page ?? 1);
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final count = selectedIds.length;
    return [
      Tooltip(
        message: count == 0 ? '请选择待检或部分已决定的任务' : '所选任务汇总到批量审批页：默认全部合格，一次提交报告办结',
        child: UtenButton(
          key: const Key('production-fqc-batch-approval'),
          size: UtenButtonSize.large,
          type: UtenButtonType.danger,
          icon: Icons.fact_check_outlined,
          onPressed: count == 0 ? null : () => _openBatchApproval(selectedIds),
          onDisabledTap: count == 0
              ? () => context.appWarning('请先选择待处理质检任务')
              : null,
          child: Text(count == 0 ? '批量审批' : '批量审批($count)'),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(RouteName.productionFqcInspections, _load);
    final permissions = ref.watch(currentPermissionsProvider);
    final canApprove =
        (ref.watch(isSuperAdminProvider) ||
            permissions.contains(Perm.productionQualityInspectionApprove)) &&
        _canDecideByScope;
    final result = _result;
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产成品质检',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.qualityTaskCenter),
        ),
        actions: [
          UtenAppBarActionButton(
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading && result != null,
            onPressed: _loading ? null : () => _load(page: 1),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && result == null
            ? const UtenSkeletonList()
            : _error != null && result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : _buildTable(canApprove),
      ),
    );
  }

  Widget _buildTable(bool canApprove) {
    final value = _result;
    final result =
        value ??
        const PagedResult<ProductionFqcInspection>(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 1,
        );
    final canBatchPass = canApprove && _status == 'ACTIVE';
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(result, canBatchPass: canBatchPass),
            const SizedBox(height: UtenSpacing.s8),
            const _FqcProcessHint(),
            if (_error != null && value != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              Semantics(
                liveRegion: true,
                child: Text(
                  '刷新失败：$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            Expanded(
              child: MasterDataTableView<ProductionFqcInspection>(
                key: const Key('production-fqc-inspection-table'),
                columns: _columns,
                items: result.items,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                selectable: canBatchPass,
                idOf: (inspection) => inspection.active ? inspection.id : null,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: _setSelectedIds,
                batchActionsBuilder: canBatchPass ? _batchActions : null,
                onRowTap: (inspection) =>
                    _openHandling(inspection, canApprove: canApprove),
                rowMenuBuilder: (inspection) => [
                  UtenMenuItem(
                    label: inspection.active && canApprove
                        ? '办理质检（详情 + 登记决定）'
                        : '查看质检详情',
                    icon: inspection.active && canApprove
                        ? Icons.rule_rounded
                        : Icons.visibility_outlined,
                    onTap: () =>
                        _openHandling(inspection, canApprove: canApprove),
                  ),
                ],
                isLoading: _loading,
                loadingMore: _loading && value != null,
                error: value == null ? _error : null,
                onRetry: () => _load(page: result.page),
                emptyMessage: _keyword.trim().isEmpty
                    ? '当前筛选下没有生产质检任务'
                    : '没有匹配的生产质检任务',
                currentPage: result.page,
                totalPages: result.totalPages,
                onPageChange: (page) => _load(page: page),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(
    PagedResult<ProductionFqcInspection> result, {
    required bool canBatchPass,
  }) {
    // 「待处理」分段挂红色圆数字徽章（与待检处置合并队列同款）：计数取
    // pending-count 权威接口；加载中/失败不显示（本页此前无计数，非回归）。
    final fqcPending = ref.watch(productionFqcPendingCountProvider).valueOrNull;
    return Semantics(
      header: true,
      label: '共有 ${result.total} 条生产成品质检任务',
      // 全平台统一筛选工具条：分段(红圆计数徽章) + 胶囊搜索框。
      child: UtenFilterToolbar<String>(
        segmentsKey: const Key('production-fqc-status-segments'),
        searchKey: const Key('production-fqc-search'),
        segments: [
          // 「待处理」= 等品质动手的待检队列 → 红徽章；其余状态段不传 count。
          UtenFilterSegment(
            value: 'ACTIVE',
            label: '待处理',
            count: fqcPending,
            countForm: UtenSegmentCountForm.actionable,
          ),
          const UtenFilterSegment(value: 'RESOLVED', label: '已决定'),
          const UtenFilterSegment(value: 'CANCELLED', label: '已取消'),
          const UtenFilterSegment(value: 'ALL', label: '全部'),
        ],
        selected: {_status},
        onSelectionChanged: _switchStatus,
        searchHint: '搜索报工单 / 生产计划 / 货品',
        initialSearchValue: _keyword,
        onSearchInputChanged: _onSearchInput,
        onSearchChanged: _applySearch,
        trailing: Text(
          canBatchPass
              ? '共 ${result.total} 条 · 单击多选，双击详情'
              : '共 ${result.total} 条 · 双击详情',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  List<MasterColumnDef<ProductionFqcInspection>> get _columns => [
    const MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 130,
      value: fqcStatusLabel,
    ),
    MasterColumnDef(
      key: 'reportNo',
      label: '报工单',
      width: 180,
      value: (inspection) => inspection.reportNo ?? '—',
    ),
    MasterColumnDef(
      key: 'planNo',
      label: '生产计划',
      width: 170,
      value: (inspection) => inspection.planNo ?? '—',
    ),
    MasterColumnDef(
      key: 'sheetNo',
      label: '检查单号',
      width: 170,
      value: (inspection) => inspection.sheetNo ?? '无检查单',
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '货品编码',
      width: 140,
      value: (inspection) => inspection.goodsCode ?? '—',
    ),
    MasterColumnDef(
      key: 'goodsName',
      label: '货品名称',
      width: 240,
      value: (inspection) => inspection.goodsName ?? '—',
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 120,
      value: (inspection) => inspection.colorName ?? '—',
    ),
    MasterColumnDef(
      key: 'reportedQty',
      label: '报工数量',
      width: 110,
      type: 'number',
      value: (inspection) => fqcQtyText(inspection.reportedQty),
    ),
    MasterColumnDef(
      key: 'passedQty',
      label: '合格数量',
      width: 110,
      type: 'number',
      value: (inspection) => fqcQtyText(inspection.passedQty),
    ),
    MasterColumnDef(
      key: 'failedQty',
      label: '不合格数量',
      width: 120,
      type: 'number',
      value: (inspection) => fqcQtyText(inspection.failedQty),
    ),
    MasterColumnDef(
      key: 'remainingQty',
      label: '待检数量',
      width: 110,
      type: 'number',
      value: (inspection) => fqcQtyText(inspection.remainingQty),
    ),
    MasterColumnDef(
      key: 'authorizedInboundQty',
      label: '已生成待点收',
      width: 120,
      type: 'number',
      value: (inspection) => fqcQtyText(inspection.authorizedInboundQty),
    ),
    MasterColumnDef(
      key: 'unitName',
      label: '单位',
      width: 90,
      value: (inspection) => inspection.unitName ?? '—',
    ),
    MasterColumnDef(
      key: 'createdAt',
      label: '进入质检时间',
      width: 170,
      value: (inspection) => ChinaDateTime.formatInstant(inspection.createdAt),
    ),
    MasterColumnDef(
      key: 'updatedAt',
      label: '更新时间',
      width: 170,
      value: (inspection) => ChinaDateTime.formatInstant(inspection.updatedAt),
    ),
  ];
}

class _FqcProcessHint extends StatelessWidget {
  const _FqcProcessHint();

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        Icons.info_outline_rounded,
        size: 18,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(width: UtenSpacing.s8),
      const Expanded(
        child: Text(
          '任务来自仓库已登记送检；FQC 只记录质量决定，不直接写库存或 iqty。'
          '双击进入办理页逐项登记；多选后点右下角「批量审批」汇总到一页，'
          '默认全部合格、一次提交办结。',
        ),
      ),
    ],
  );
}
