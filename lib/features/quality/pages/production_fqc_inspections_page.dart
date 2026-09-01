import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
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
      builder: (_) => _ProductionFqcDecisionDialog(inspection: inspection),
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
      builder: (_) => _ProductionFqcDetailDialog(
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
    final segments = SegmentedButton<String>(
      key: const Key('production-fqc-status-segments'),
      segments: const [
        ButtonSegment(value: 'ACTIVE', label: Text('待处理')),
        ButtonSegment(value: 'RESOLVED', label: Text('已决定')),
        ButtonSegment(value: 'CANCELLED', label: Text('已取消')),
        ButtonSegment(value: 'ALL', label: Text('全部')),
      ],
      selected: {_status},
      onSelectionChanged: (selection) => _switchStatus(selection.first),
    );
    final search = UtenSearchBar(
      key: const Key('production-fqc-search'),
      hint: '搜索报工单 / 生产计划 / 货品',
      initialValue: _keyword,
      onInputChanged: _onSearchInput,
      onChanged: _applySearch,
    );
    final count = Text(
      canBatchPass
          ? '共 ${result.total} 条 · 单击多选，双击详情'
          : '共 ${result.total} 条 · 双击详情',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    return Semantics(
      header: true,
      label: '共有 ${result.total} 条生产成品质检任务',
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 980) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: segments,
                ),
                const SizedBox(height: UtenSpacing.s8),
                search,
                const SizedBox(height: UtenSpacing.s8),
                count,
              ],
            );
          }
          return Row(
            children: [
              segments,
              const SizedBox(width: UtenSpacing.s12),
              SizedBox(width: 360, child: search),
              const Spacer(),
              count,
            ],
          );
        },
      ),
    );
  }

  List<MasterColumnDef<ProductionFqcInspection>> get _columns => [
    const MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 130,
      value: _fqcStatusLabel,
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
      value: (inspection) => _qty(inspection.reportedQty),
    ),
    MasterColumnDef(
      key: 'passedQty',
      label: '合格数量',
      width: 110,
      type: 'number',
      value: (inspection) => _qty(inspection.passedQty),
    ),
    MasterColumnDef(
      key: 'failedQty',
      label: '不合格数量',
      width: 120,
      type: 'number',
      value: (inspection) => _qty(inspection.failedQty),
    ),
    MasterColumnDef(
      key: 'remainingQty',
      label: '待检数量',
      width: 110,
      type: 'number',
      value: (inspection) => _qty(inspection.remainingQty),
    ),
    MasterColumnDef(
      key: 'authorizedInboundQty',
      label: '已生成待点收',
      width: 120,
      type: 'number',
      value: (inspection) => _qty(inspection.authorizedInboundQty),
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

class _ProductionFqcDetailDialog extends ConsumerStatefulWidget {
  const _ProductionFqcDetailDialog({
    super.key,
    required this.inspectionId,
    required this.canApprove,
  });

  final String inspectionId;
  final bool canApprove;

  @override
  ConsumerState<_ProductionFqcDetailDialog> createState() =>
      _ProductionFqcDetailDialogState();
}

class _ProductionFqcDetailDialogState
    extends ConsumerState<_ProductionFqcDetailDialog> {
  ProductionFqcInspection? _inspection;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inspection = await ref
          .read(productionFqcRepositoryProvider)
          .detail(widget.inspectionId);
      if (!mounted) return;
      setState(() {
        _inspection = inspection;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '生产成品质检详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inspection = _inspection;
    return AlertDialog(
      title: const Text('生产成品质检详情'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: _loading
            ? const SizedBox(
                height: 280,
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : _error != null
            ? SizedBox(
                height: 320,
                child: UtenEmpty.error(
                  message: _error,
                  actionLabel: '重新加载',
                  onAction: _load,
                ),
              )
            : SingleChildScrollView(child: _buildDetail(inspection!)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        if (inspection != null && inspection.active && widget.canApprove)
          FilledButton.icon(
            key: ValueKey('production-fqc-decide-${inspection.id}'),
            onPressed: () => Navigator.of(context).pop(inspection),
            icon: const Icon(Icons.rule_rounded),
            label: const Text('登记检验决定'),
          ),
      ],
    );
  }

  Widget _buildDetail(ProductionFqcInspection inspection) {
    final theme = Theme.of(context);
    final readOnlyReason = inspection.active
        ? '当前为只读查看；登记决定需要生产质检审批权限，且账号必须属于品质任务组织。'
        : inspection.status == 'CANCELLED'
        ? '来源报工已红冲，本任务只读且不能再登记检验决定。'
        : '该任务已完成决定，当前详情只读。';
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer.withValues(
                alpha: 0.42,
              ),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Text(
              _fqcStatusLabel(inspection),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          _detailLine('报工单', inspection.reportNo ?? '—'),
          _detailLine('生产计划', inspection.planNo ?? '—'),
          _detailLine(
            '货品',
            [
              inspection.goodsCode,
              inspection.goodsName,
            ].whereType<String>().join(' '),
          ),
          _detailLine('颜色', inspection.colorName ?? '—'),
          _detailLine('单位', inspection.unitName ?? '—'),
          const Divider(height: UtenSpacing.s24),
          _detailLine('报工数量', _qty(inspection.reportedQty)),
          _detailLine('合格数量', _qty(inspection.passedQty)),
          _detailLine('不合格数量', _qty(inspection.failedQty)),
          _detailLine('待检数量', _qty(inspection.remainingQty)),
          _detailLine('已生成待点收', _qty(inspection.authorizedInboundQty)),
          const Divider(height: UtenSpacing.s24),
          _detailLine(
            '进入质检时间',
            ChinaDateTime.formatInstant(inspection.createdAt),
          ),
          _detailLine(
            '更新时间',
            ChinaDateTime.formatInstant(inspection.updatedAt),
          ),
          if (!inspection.active || !widget.canApprove) ...[
            const SizedBox(height: UtenSpacing.s8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    readOnlyReason,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailLine(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 112, child: Text('$label：')),
        Expanded(child: Text(value.isEmpty ? '—' : value)),
      ],
    ),
  );
}

class _ProductionFqcDecisionDialog extends ConsumerStatefulWidget {
  const _ProductionFqcDecisionDialog({required this.inspection});

  final ProductionFqcInspection inspection;

  @override
  ConsumerState<_ProductionFqcDecisionDialog> createState() =>
      _ProductionFqcDecisionDialogState();
}

class _ProductionFqcDecisionDialogState
    extends ConsumerState<_ProductionFqcDecisionDialog> {
  String _decision = 'PASS';
  String _disposition = 'REWORK';
  late final TextEditingController _passQty;
  late final TextEditingController _failQty;
  final TextEditingController _reason = TextEditingController();
  final String _idempotencyKey = 'fqc-decision-${const Uuid().v4()}';
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _passQty = TextEditingController(
      text: _qty(widget.inspection.remainingQty),
    );
    _failQty = TextEditingController(
      text: _qty(widget.inspection.remainingQty),
    );
  }

  @override
  void dispose() {
    _passQty.dispose();
    _failQty.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final remaining = widget.inspection.remainingQty;
    final pass = double.tryParse(_passQty.text.trim());
    final fail = double.tryParse(_failQty.text.trim());
    String? validation;
    if (_decision == 'PASS') {
      if (pass == null || pass <= 0 || pass > remaining + 0.000001) {
        validation = '合格数量必须大于 0 且不超过待检数量';
      }
    } else if (_decision == 'FAIL') {
      if (fail == null || fail <= 0 || fail > remaining + 0.000001) {
        validation = '不合格数量必须大于 0 且不超过待检数量';
      }
    } else {
      if (pass == null ||
          pass <= 0 ||
          fail == null ||
          fail <= 0 ||
          pass + fail > remaining + 0.000001) {
        validation = '部分决定必须同时填写正的合格/不合格数量，且合计不超过待检数量';
      }
    }
    if (_decision != 'PASS' && _reason.text.trim().length < 2) {
      validation ??= '不合格或部分决定必须填写至少 2 个字的原因';
    }
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionFqcRepositoryProvider)
          .decide(
            id: widget.inspection.id,
            decision: _decision,
            idempotencyKey: _idempotencyKey,
            passQty: _decision == 'FAIL' ? null : pass,
            failQty: _decision == 'PASS' ? null : fail,
            dispositionCode: _decision == 'PASS' ? null : _disposition,
            reason: _decision == 'PASS' ? null : _reason.text,
          );
      ref.invalidate(productionFqcPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '质检决定保存失败，请保持本窗口并重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('登记生产成品质检决定'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '待检 ${_qty(widget.inspection.remainingQty)} '
                '${widget.inspection.unitName ?? ''}',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  for (final entry in const [
                    ('PASS', '合格'),
                    ('PARTIAL', '部分合格'),
                    ('FAIL', '不合格'),
                  ])
                    ChoiceChip(
                      label: Text(entry.$2),
                      selected: _decision == entry.$1,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() => _decision = entry.$1),
                    ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              if (_decision != 'FAIL')
                TextField(
                  controller: _passQty,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '本次合格数量',
                    // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing rejects LayoutBuilder helper widgets.
                    helperText: '合格数量会生成仓库待点收任务，尚不直接增加库存。',
                  ),
                ),
              if (_decision != 'PASS') ...[
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: _failQty,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '本次不合格数量'),
                ),
                const SizedBox(height: UtenSpacing.s12),
                DropdownButtonFormField<String>(
                  initialValue: _disposition,
                  decoration: const InputDecoration(labelText: '不合格处置'),
                  items: const [
                    DropdownMenuItem(value: 'REWORK', child: Text('返工')),
                    DropdownMenuItem(value: 'SCRAP', child: Text('报废')),
                    DropdownMenuItem(value: 'REJECT', child: Text('拒收/退回')),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) =>
                            setState(() => _disposition = value ?? 'REWORK'),
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: _reason,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '不合格原因',
                    // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing rejects LayoutBuilder helper widgets.
                    helperText: '至少 2 个字，保留为不可变质量决定证据。',
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
          label: Text(_saving ? '保存中…' : '确认决定'),
        ),
      ],
    );
  }
}

String _fqcStatusLabel(ProductionFqcInspection inspection) =>
    switch (inspection.status) {
      'PENDING' => '待检',
      'PARTIAL' => '部分已决定',
      'RESOLVED' => '已全部决定',
      'CANCELLED' => '来源报工已红冲',
      _ => inspection.status,
    };

String _qty(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');
