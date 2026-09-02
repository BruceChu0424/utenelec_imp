import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
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
  bool _batchPassing = false;
  String? _batchSelectionFingerprint;
  String? _batchIdempotencyKey;

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

  Future<void> _openDecision(ProductionFqcInspection inspection) async {
    final result = await showDialog<ProductionFqcDecisionResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProductionFqcDecisionDialog(inspection: inspection),
    );
    if (result == null || !mounted) return;
    _applyDecisionResult(result.inspection);
    context.appSuccess(result.replay ? '该质检决定已安全重放' : '质检决定已保存');
    await _load(page: _result?.page ?? 1);
  }

  Future<void> _openDetail(
    ProductionFqcInspection inspection, {
    required bool canApprove,
  }) async {
    final decisionTarget = await showDialog<ProductionFqcInspection>(
      context: context,
      builder: (_) => ProductionFqcDetailDialog(
        key: ValueKey('production-fqc-detail-${inspection.id}'),
        inspectionId: inspection.id,
        canApprove: canApprove,
      ),
    );
    if (decisionTarget == null || !mounted) return;
    await _openDecision(decisionTarget);
  }

  void _setSelectedIds(Set<String> next) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(next);
    });
  }

  String _batchKey(Set<String> ids) {
    final sorted = ids.toList()..sort();
    final fingerprint = sorted.join('|');
    if (_batchSelectionFingerprint != fingerprint ||
        _batchIdempotencyKey == null) {
      _batchSelectionFingerprint = fingerprint;
      _batchIdempotencyKey = 'fqc-pass-all-${const Uuid().v4()}';
    }
    return _batchIdempotencyKey!;
  }

  Future<void> _passSelected(Set<String> selectedIds) async {
    if (_batchPassing || selectedIds.isEmpty) {
      if (selectedIds.isEmpty) context.appWarning('请先选择待处理质检任务');
      return;
    }
    final ids = selectedIds.toList()..sort();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('批量全部合格 ${ids.length} 项'),
        content: const Text(
          '系统将把所选任务当前全部待检数量登记为合格，并在同一事务生成对应的仓库待最终点收任务。'
          '本操作不会直接增加库存或 iqty；任一任务状态、权限、品质组织、放行或并发校验失败，整批都会回滚。'
          '存在不合格或部分合格时，请取消并双击对应任务逐项登记。',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.rule_rounded),
            label: const Text('确认全部合格'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _batchPassing = true);
    try {
      final result = await ref
          .read(productionFqcRepositoryProvider)
          .passAll(inspectionIds: ids, idempotencyKey: _batchKey(selectedIds));
      if (!mounted) return;
      for (final inspection in result.inspections) {
        _applyDecisionResult(inspection);
      }
      setState(() {
        _selectedIds.clear();
        _batchSelectionFingerprint = null;
        _batchIdempotencyKey = null;
      });
      ref.invalidate(productionFqcPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      context.appSuccess(
        result.replay
            ? '该批次已完成，已安全重放 ${result.processedCount} 项结果'
            : '已将 ${result.processedCount} 项质检任务批量登记为全部合格',
      );
      await _load(page: _result?.page ?? 1);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('批量全部合格失败，请保持当前选择后重试');
    } finally {
      if (mounted) setState(() => _batchPassing = false);
    }
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final count = selectedIds.length;
    return [
      Tooltip(
        message: count == 0 ? '请选择待检或部分已决定的任务' : '将所选任务全部剩余待检数量原子登记为合格',
        child: UtenButton(
          key: const Key('production-fqc-batch-pass-all'),
          size: UtenButtonSize.large,
          icon: Icons.rule_rounded,
          isLoading: _batchPassing,
          onPressed: _batchPassing || count == 0
              ? null
              : () => _passSelected(selectedIds),
          onDisabledTap: count == 0
              ? () => context.appWarning('请先选择待处理质检任务')
              : null,
          child: Text(count == 0 ? '批量全部合格' : '批量全部合格($count)'),
        ),
      ),
    ];
  }

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
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && result != null,
              onPressed: _loading ? null : _load,
              child: const Text('刷新'),
            ),
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
                    _openDetail(inspection, canApprove: canApprove),
                rowMenuBuilder: (inspection) => [
                  UtenMenuItem(
                    label: '查看质检详情',
                    icon: Icons.visibility_outlined,
                    onTap: () =>
                        _openDetail(inspection, canApprove: canApprove),
                  ),
                  if (inspection.active && canApprove)
                    UtenMenuItem(
                      label: '登记检验决定',
                      icon: Icons.rule_rounded,
                      onTap: () => _openDecision(inspection),
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
          UtenFilterSegment(value: 'ACTIVE', label: '待处理', count: fqcPending),
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
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
          '待处理任务可多选后在右下角批量登记为全部合格；部分合格或不合格仍须逐项登记。',
        ),
      ),
    ],
  );
}
