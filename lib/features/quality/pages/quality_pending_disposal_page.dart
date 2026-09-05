// 待检处置（品质任务中心唯一待办入口）——IQC 与 FQC 统一队列。
//
// 2026-09-01 合并：原「待检处置」只收采购/委外收货 IQC，「生产成品质检」FQC 单列
// 一张卡；现按业务要求把 FQC 并入本页——分段导航 = 全部待检单 / 采购收货 /
// 委外回厂 / 自制产成品，分段数字用红色圆徽章（UtenNotificationBadge，工作台同款），
// 搜索框为胶囊圆角（stadium，与 SegmentedButton 分段导航条同形）。
// 页面源码随之从 warehouse feature 移入 quality（2026-08-19 起本页业务归属品质部，
// 路由 /warehouse/inspections 不变，避免外部深链失效）。
//
// 队列表只放单据级概要：IQC 行 = 收货单（双击进处置页，逐行放行/登记不合格），
// FQC 行 = 报工待检任务（双击详情 + 登记决定，可勾选批量全部合格）。
// 权限分别门控：IQC 读 procurement_inspection:view、写 :handle；
// FQC 读 production_quality_inspection:view、决定 :approve + 服务端品质组织校验。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../warehouse/providers/production_finished_inbound_task_count_provider.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/providers/warehouse_quality_result_count_provider.dart';
import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../models/production_fqc_inspection.dart';
import '../repositories/production_fqc_repository.dart';
import '../widgets/production_fqc_dialogs.dart';

class QualityPendingDisposalPage extends ConsumerStatefulWidget {
  const QualityPendingDisposalPage({super.key});

  @override
  ConsumerState<QualityPendingDisposalPage> createState() =>
      _QualityPendingDisposalPageState();
}

class _QualityPendingDisposalPageState
    extends ConsumerState<QualityPendingDisposalPage> {
  static const int _pageSize = 10;

  /// FQC 待检队列一次拉取上限；超出时计数仍用服务端 total，行内提示截断事实。
  static const int _fqcFetchSize = 500;

  /// IQC 待检收货单（无 IQC 查看权限时恒为 null 且不请求）。
  List<PendingInspectionReceipt>? _receipts;

  /// FQC 待处理（PENDING/PARTIAL）任务（无 FQC 查看权限时恒为 null 且不请求）。
  List<ProductionFqcInspection>? _fqcInspections;
  int _fqcTotal = 0;
  bool _fqcTruncated = false;
  bool _loading = false;
  String? _error;

  /// 搜索关键字（IQC：收货单号/供应商；FQC：报工单/生产计划/货品），300ms 防抖。
  String _keyword = '';

  /// 类型筛选（分段按钮与表头筛选共用）：null = 全部；PURCHASE / SUBCONTRACT / FQC。
  /// 进页面不预选（不选=不过滤），点分段后才算选中。
  String? _typeFilter;
  bool _typeFilterSelected = false;
  int _page = 1;
  int _requestVersion = 0;

  /// FQC 决定能力 = 审批权限 + 服务端品质组织校验（canDecide）。
  bool _canDecideFqc = false;
  final Set<String> _selectedIds = <String>{};
  bool _batchPassing = false;
  String? _batchSelectionFingerprint;
  String? _batchIdempotencyKey;

  bool get _canViewIqc {
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        permissions.contains(Perm.procurementInspectionView);
  }

  bool get _canViewFqc {
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        permissions.contains(Perm.productionQualityInspectionView);
  }

  bool get _canHandleIqc {
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        permissions.contains(Perm.procurementInspectionHandle);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final request = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    final errors = <String>[];
    List<PendingInspectionReceipt>? receipts;
    if (_canViewIqc) {
      try {
        receipts = await ref
            .read(procurementInspectionRepositoryProvider)
            .pendingReceipts();
      } on ApiException catch (error) {
        errors.add('待检收货单：${error.message}');
      } catch (_) {
        errors.add('待检收货单加载失败');
      }
    }
    List<ProductionFqcInspection>? inspections;
    var fqcTotal = 0;
    var fqcTruncated = false;
    var canDecideFqc = false;
    if (_canViewFqc) {
      try {
        final permissions = ref.read(currentPermissionsProvider);
        final mayApprove =
            ref.read(isSuperAdminProvider) ||
            permissions.contains(Perm.productionQualityInspectionApprove);
        if (mayApprove) {
          try {
            // Fail closed for the write actions; task reading stays available.
            canDecideFqc = await ref
                .read(productionFqcRepositoryProvider)
                .canDecide();
          } catch (_) {
            canDecideFqc = false;
          }
        }
        // status 默认 'ACTIVE'（PENDING/PARTIAL），与待检口径一致。
        final result = await ref
            .read(productionFqcRepositoryProvider)
            .list(size: _fqcFetchSize);
        inspections = result.items;
        fqcTotal = result.total;
        fqcTruncated = result.total > result.items.length;
      } on ApiException catch (error) {
        errors.add('自制产成品待检：${error.message}');
      } catch (_) {
        errors.add('自制产成品待检任务加载失败');
      }
    }
    if (!mounted || request != _requestVersion) return;
    setState(() {
      // 成功才覆盖；失败保留旧数据并叠加行内错误（不把失败伪装成空队列）。
      // 无对应权限的域恒为空列表——骨架屏/整页错误判定只看「有权域从未成功」。
      if (_canViewIqc) {
        if (receipts != null) _receipts = receipts;
      } else {
        _receipts = const [];
      }
      if (_canViewFqc) {
        if (inspections != null) {
          _fqcInspections = inspections;
          _fqcTotal = fqcTotal;
          _fqcTruncated = fqcTruncated;
        }
      } else {
        _fqcInspections = const [];
        _fqcTotal = 0;
      }
      _canDecideFqc = canDecideFqc;
      _loading = false;
      _error = errors.isEmpty ? null : errors.join('；');
      if (_page > _totalPages) _page = _totalPages;
      final fqcIds =
          _fqcInspections?.map((item) => item.id).toSet() ?? const <String>{};
      _selectedIds.removeWhere((id) => !fqcIds.contains(id));
    });
    ref.invalidate(procurementInspectionPendingCountProvider);
    ref.invalidate(productionFqcPendingCountProvider);
  }

  void _applySearch(String value) {
    if (value == _keyword) return;
    setState(() {
      _keyword = value;
      _page = 1;
    });
  }

  /// 类型筛选（分段按钮与表头筛选共用这一个口径）：null = 全部待检。
  void _selectType(String? type) {
    if (_typeFilter == type && _typeFilterSelected) return;
    setState(() {
      _typeFilter = type;
      _typeFilterSelected = true;
      _page = 1;
    });
  }

  bool _matchesKeyword(_DisposalRow row) {
    final keyword = _keyword.trim().toLowerCase();
    if (keyword.isEmpty) return true;
    if (row.isFqc) {
      final text = [
        row.inspection!.reportNo,
        row.inspection!.planNo,
        row.inspection!.goodsCode,
        row.inspection!.goodsName,
        row.inspection!.colorName,
      ].whereType<String>().join(' ').toLowerCase();
      return text.contains(keyword);
    }
    final receipt = row.receipt!;
    return (receipt.billNo ?? '').toLowerCase().contains(keyword) ||
        (receipt.supplierName ?? '').toLowerCase().contains(keyword);
  }

  List<_DisposalRow> get _rows => [
    if (_receipts != null)
      for (final receipt in _receipts!) _DisposalRow.iqc(receipt),
    if (_fqcInspections != null)
      for (final inspection in _fqcInspections!) _DisposalRow.fqc(inspection),
  ];

  List<_DisposalRow> get _filtered => [
    for (final row in _rows)
      if ((_typeFilter == null || row.kind == _typeFilter) &&
          _matchesKeyword(row))
        row,
  ];

  int get _totalPages {
    final pages = (_filtered.length + _pageSize - 1) ~/ _pageSize;
    return pages < 1 ? 1 : pages;
  }

  List<_DisposalRow> get _pageItems {
    final start = (_page - 1) * _pageSize;
    if (start >= _filtered.length) return const [];
    var end = start + _pageSize;
    if (end > _filtered.length) end = _filtered.length;
    return _filtered.sublist(start, end);
  }

  /// 双击 IQC 行：进入本单处置页（明细多选表格在处置页里）。
  Future<void> _openIqcDetail(PendingInspectionReceipt receipt) async {
    await context.push(
      RouteName.warehouseInspectionDetail(
        receipt.receiptType,
        receipt.receiptId,
      ),
      extra: receipt,
    );
    if (!mounted) return;
    // 处置页返回后重拉队列（本单可能已结案）并同步角标。
    await _load();
  }

  /// 双击 FQC 行：详情弹窗 →（可决定账号）登记检验决定。
  Future<void> _openFqcDetail(_DisposalRow row) async {
    final inspection = row.inspection!;
    final decisionTarget = await showDialog<ProductionFqcInspection>(
      context: context,
      builder: (_) => ProductionFqcDetailDialog(
        key: ValueKey('production-fqc-detail-${inspection.id}'),
        inspectionId: inspection.id,
        canApprove: _canDecideFqc,
      ),
    );
    if (decisionTarget == null || !mounted) return;
    await _openFqcDecision(decisionTarget);
  }

  Future<void> _openFqcDecision(ProductionFqcInspection inspection) async {
    final result = await showDialog<ProductionFqcDecisionResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProductionFqcDecisionDialog(inspection: inspection),
    );
    if (result == null || !mounted) return;
    _applyFqcDecisionResult(result.inspection);
    ref.invalidate(productionFqcPendingCountProvider);
    ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
    if (mounted) {
      context.appSuccess(result.replay ? '该质检决定已安全重放' : '质检决定已保存');
    }
    await _load();
  }

  /// 决定成功先本地落位（决定行保留为 PARTIAL 或移除 RESOLVED），刷新失败也不回滚。
  void _applyFqcDecisionResult(ProductionFqcInspection updated) {
    final list = _fqcInspections;
    if (list == null) return;
    final index = list.indexWhere((item) => item.id == updated.id);
    if (index < 0) return;
    final next = [...list];
    if (updated.active) {
      next[index] = updated;
    } else {
      next.removeAt(index);
      _fqcTotal = _fqcTotal > 0 ? _fqcTotal - 1 : 0;
      _selectedIds.remove(updated.id);
    }
    setState(() => _fqcInspections = next);
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
        _applyFqcDecisionResult(inspection);
      }
      setState(() {
        _selectedIds.clear();
        _batchSelectionFingerprint = null;
        _batchIdempotencyKey = null;
      });
      ref.invalidate(productionFqcPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      if (mounted) {
        context.appSuccess(
          result.replay
              ? '该批次已完成，已安全重放 ${result.processedCount} 项结果'
              : '已将 ${result.processedCount} 项质检任务批量登记为全部合格',
        );
      }
      await _load();
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
        message: count == 0 ? '请选择待检或部分已决定的自制产成品任务' : '将所选任务全部剩余待检数量原子登记为合格',
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

  @override
  Widget build(BuildContext context) {
    // 返回本页（从处置页/其他页回退）时重拉两域队列，角标同源刷新。
    ref.onPageResume(RouteName.warehouseInspections, _load);
    return Scaffold(
      appBar: UtenAppBar(
        title: '待检处置',
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
              isLoading: _loading && _rows.isNotEmpty,
              onPressed: _loading ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && _receipts == null && _fqcInspections == null
            ? const UtenSkeletonList()
            : _error != null && _receipts == null && _fqcInspections == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : _buildList(),
      ),
    );
  }

  Widget _buildList() {
    final pageItems = _pageItems;
    // 计数直接取全量口径（不是当前页推算），与后端 pendingCount 同源；
    // 表头筛选与分段按钮共用 _typeFilter。
    final purchaseCount = _receipts
        ?.where((receipt) => !receipt.isSubcontract)
        .length;
    final subcontractCount = _receipts
        ?.where((receipt) => receipt.isSubcontract)
        .length;
    final fqcCount = _fqcInspections == null ? null : _fqcTotal;
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(purchaseCount, subcontractCount, fqcCount),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              _InlineWorkbenchError(message: _error!, onRetry: _load),
            ],
            const SizedBox(height: UtenSpacing.s12),
            Expanded(
              child: MasterDataTableView<_DisposalRow>(
                key: const Key('iqc-receipt-table'),
                columns: _columns,
                items: pageItems,
                facets: {
                  'docType': [
                    if (_canViewIqc) ...[
                      MasterFacetBucket(
                        value: 'PURCHASE',
                        count: purchaseCount ?? 0,
                        label: '采购收货',
                      ),
                      MasterFacetBucket(
                        value: 'SUBCONTRACT',
                        count: subcontractCount ?? 0,
                        label: '委外回厂',
                      ),
                    ],
                    if (_canViewFqc)
                      MasterFacetBucket(
                        value: 'FQC',
                        count: fqcCount ?? 0,
                        label: '自制产成品',
                      ),
                  ],
                },
                nullCounts: const {},
                filters: {'docType': _typeFilter},
                onFilterChanged: (key, value) {
                  if (key != 'docType') return;
                  _selectType(value);
                },
                selectable: _canDecideFqc,
                idOf: (row) => row.isFqc && row.inspection!.active
                    ? row.inspection!.id
                    : null,
                // 勾选门控与 idOf 同源（IQC 行返回 null 不可勾选），
                // 行稳定键单独给：IQC 用收货单 id，FQC 用任务 id。
                rowKeyOf: (row) =>
                    row.isFqc ? row.inspection!.id : row.receipt!.receiptId,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: (next) => setState(
                  () => _selectedIds
                    ..clear()
                    ..addAll(next),
                ),
                batchActionsBuilder: _canDecideFqc ? _batchActions : null,
                onRowTap: (row) => row.isFqc
                    ? _openFqcDetail(row)
                    : _openIqcDetail(row.receipt!),
                rowMenuBuilder: (row) => row.isFqc
                    ? [
                        UtenMenuItem(
                          label: '查看质检详情',
                          icon: Icons.visibility_outlined,
                          onTap: () => _openFqcDetail(row),
                        ),
                        if (row.inspection!.active && _canDecideFqc)
                          UtenMenuItem(
                            label: '登记检验决定',
                            icon: Icons.rule_rounded,
                            onTap: () => _openFqcDecision(row.inspection!),
                          ),
                      ]
                    : [
                        UtenMenuItem(
                          label: _canHandleIqc
                              ? '检验本单(${row.receipt!.itemCount} 行待检)'
                              : '查看待检明细',
                          icon: Icons.fact_check_outlined,
                          onTap: () => _openIqcDetail(row.receipt!),
                        ),
                      ],
                isLoading: _loading,
                error: pageItems.isEmpty ? _error : null,
                onRetry: _load,
                emptyMessage: _emptyMessage,
                currentPage: _page,
                totalPages: _totalPages,
                onPageChange: (next) => setState(() => _page = next),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(
    int? purchaseCount,
    int? subcontractCount,
    int? fqcCount,
  ) {
    final selected = switch (_typeFilter) {
      'PURCHASE' => 'purchase',
      'SUBCONTRACT' => 'subcontract',
      'FQC' => 'fqc',
      _ => 'all',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          label: '共有 ${_rows.length} 条待检任务',
          // 全平台统一筛选工具条：分段(红圆计数徽章) + 胶囊搜索框。
          // 「全部待检单」不挂徽章——徽章只挂各来源分段的可办数量。
          child: UtenFilterToolbar<String>(
            segmentsKey: const Key('iqc-type-segments'),
            searchKey: const Key('iqc-search'),
            segments: [
              const UtenFilterSegment(value: 'all', label: '全部待检单'),
              if (_canViewIqc) ...[
                UtenFilterSegment(
                  value: 'purchase',
                  label: '采购收货',
                  count: purchaseCount,
                ),
                UtenFilterSegment(
                  value: 'subcontract',
                  label: '委外回厂',
                  count: subcontractCount,
                ),
              ],
              if (_canViewFqc)
                UtenFilterSegment(
                  value: 'fqc',
                  label: '自制产成品',
                  count: fqcCount,
                ),
            ],
            selected: _typeFilterSelected ? {selected} : const {},
            onSelectionChanged: (value) => _selectType(switch (value) {
              'purchase' => 'PURCHASE',
              'subcontract' => 'SUBCONTRACT',
              'fqc' => 'FQC',
              _ => null,
            }),
            searchHint: '搜索单号 / 供应商 / 货品',
            initialSearchValue: _keyword,
            onSearchChanged: _applySearch,
            trailing: Text(
              '共 ${_filtered.length} 条 · 双击办理',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                _hintText,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        if (_fqcTruncated) ...[
          const SizedBox(height: UtenSpacing.s8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    '自制产成品待检任务共 $_fqcTotal 条，超过单次拉取上限，'
                    '仅显示前 $_fqcFetchSize 条；请先处理当前任务后刷新。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String get _hintText {
    if (!_canHandleIqc && !_canDecideFqc) {
      return '当前为只读查看；IQC 处置需要 procurement_inspection:handle 权限，'
          '自制产成品决定需要 production_quality_inspection:approve 权限。';
    }
    return '采购/委外收货与自制产成品送检后出现在这里：双击进入处置；'
        'IQC 常规合格可多行一次放行，自制产成品可勾选批量全部合格；'
        '部分合格或不合格逐项登记。';
  }

  List<MasterColumnDef<_DisposalRow>> get _columns => [
    MasterColumnDef(
      key: 'docType',
      label: '单据类型',
      width: 110,
      value: (row) => switch (row.kind) {
        'SUBCONTRACT' => '委外回厂',
        'FQC' => '自制产成品',
        _ => '采购收货',
      },
    ),
    MasterColumnDef(
      key: 'billNo',
      label: '单号',
      width: 175,
      value: (row) => row.isFqc
          ? (row.inspection!.reportNo ?? row.inspection!.id)
          : (row.receipt!.billNo ?? row.receipt!.receiptId),
    ),
    MasterColumnDef(
      key: 'party',
      label: '供应商 / 生产计划',
      width: 210,
      value: (row) => row.isFqc
          ? (row.inspection!.planNo ?? '—')
          : (row.receipt!.supplierName ?? '—'),
    ),
    MasterColumnDef(
      key: 'goods',
      label: '货品',
      width: 230,
      value: (row) => row.isFqc
          ? [
              row.inspection!.goodsName,
              if (row.inspection!.colorName?.isNotEmpty == true)
                '(${row.inspection!.colorName})',
            ].whereType<String>().join()
          : '—',
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (row) => row.isFqc ? fqcStatusLabel(row.inspection!) : '待检',
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '待检行数',
      width: 95,
      type: 'number',
      value: (row) => row.isFqc ? '1' : row.receipt!.itemCount.toString(),
    ),
    MasterColumnDef(
      key: 'pendingQty',
      label: '待检数量',
      width: 120,
      value: (row) => row.isFqc
          ? '${fqcQtyText(row.inspection!.remainingQty)}'
                '${row.inspection!.unitName ?? ''}'
          : '—',
    ),
    MasterColumnDef(
      key: 'enteredAt',
      label: '最近到检 / 进入质检',
      width: 160,
      type: 'date',
      value: (row) => row.isFqc
          ? ChinaDateTime.formatInstant(row.inspection!.createdAt)
          : (_fmtDateTime(row.receipt!.lastReceivedAt) ?? '—'),
    ),
  ];

  String get _emptyMessage {
    if (_keyword.trim().isNotEmpty) return '没有匹配「$_keyword」的待检单';
    if (_typeFilter == 'PURCHASE') return '暂无采购收货待检单';
    if (_typeFilter == 'SUBCONTRACT') return '暂无委外回厂待检单';
    if (_typeFilter == 'FQC') return '暂无自制产成品待检任务';
    return '暂无待检单';
  }
}

/// 统一待检行：IQC 收货单或 FQC 报工待检任务。
class _DisposalRow {
  const _DisposalRow.iqc(PendingInspectionReceipt this.receipt)
    : inspection = null;
  const _DisposalRow.fqc(ProductionFqcInspection this.inspection)
    : receipt = null;

  final PendingInspectionReceipt? receipt;
  final ProductionFqcInspection? inspection;

  bool get isFqc => inspection != null;

  /// 与分段/表头筛选同一取值域：PURCHASE / SUBCONTRACT / FQC。
  String get kind =>
      isFqc ? 'FQC' : (receipt!.isSubcontract ? 'SUBCONTRACT' : 'PURCHASE');
}

/// 单张收货单的 IQC 处置页：明细多选表格 + 批量合格放行 / 单行检验弹窗。
///
/// 处置只收敛本单明细；本单无剩余待检明细时切换为完成态，返回任务中心
/// 继续下一单（不再自动跳单，两级页面各司其职）。
class ProcurementInspectionDetailPage extends ConsumerStatefulWidget {
  const ProcurementInspectionDetailPage({
    super.key,
    required this.receiptType,
    required this.receiptId,
    this.extra,
  });

  final String receiptType;
  final String receiptId;

  /// 任务中心卡片携带的收货单快照（单号/供应商即时显示）；深链直达时为空，
  /// 页面会从待检队列反查补齐；收货单已不在队列时以完成/不存在态呈现。
  final Object? extra;

  @override
  ConsumerState<ProcurementInspectionDetailPage> createState() =>
      _ProcurementInspectionDetailPageState();
}

class _ProcurementInspectionDetailPageState
    extends ConsumerState<ProcurementInspectionDetailPage> {
  PendingInspectionReceipt? _receipt;
  List<ProcurementInspectionItem> _items = const [];
  bool _loading = true;
  bool _busyDecision = false;
  String? _error;
  Set<String> _selectedItemIds = const {};
  final Map<String, String> _decisionKeys = {};
  int _requestVersion = 0;

  bool get _canHandle {
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        permissions.contains(Perm.procurementInspectionHandle);
  }

  PendingInspectionReceipt? get _snapshot =>
      widget.extra is PendingInspectionReceipt
      ? widget.extra! as PendingInspectionReceipt
      : null;

  @override
  void initState() {
    super.initState();
    _receipt = _snapshot;
    _load();
  }

  bool _isOpenItem(ProcurementInspectionItem item) {
    final remaining = item.remainingBaseQty ?? 0;
    return remaining > 0 &&
        item.status != 'RESOLVED' &&
        item.status != 'REVERSED';
  }

  Future<void> _load() async {
    final request = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(procurementInspectionRepositoryProvider);
      var summary = _receipt;
      final snapshotStale =
          summary == null ||
          summary.receiptType != widget.receiptType ||
          summary.receiptId != widget.receiptId;
      if (snapshotStale) {
        final rows = await repo.pendingReceipts();
        summary = rows
            .where(
              (row) =>
                  row.receiptType == widget.receiptType &&
                  row.receiptId == widget.receiptId,
            )
            .firstOrNull;
      }
      final rows = await repo.items(widget.receiptType, widget.receiptId);
      if (!mounted || request != _requestVersion) return;
      final openRows = rows.where(_isOpenItem).toList(growable: false);
      setState(() {
        if (summary != null) _receipt = summary;
        _items = openRows;
        _selectedItemIds = const {};
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || request != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _requestVersion) return;
      setState(() {
        _error = '待检明细加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  List<ProcurementInspectionItem> get _selectedItems => [
    for (final item in _items)
      if (_selectedItemIds.contains(item.id)) item,
  ];

  String get _pendingSummary {
    final names = ref.read(masterNameServiceProvider);
    return measurementTotalsText(
      _items.map(
        (item) => MeasuredAmount(
          value: item.remainingBaseQty ?? 0,
          unitId: item.unitId,
          unitName: names.unit(item.unitId),
        ),
      ),
    );
  }

  String _idempotencyKeyFor(
    ProcurementInspectionItem item,
    String action,
    double? qty,
    String? reason,
  ) {
    final canonical = [
      '${widget.receiptType}:${widget.receiptId}',
      item.id,
      action,
      qty?.toString() ?? 'ALL',
      reason?.trim() ?? '',
    ].join('|');
    return _decisionKeys.putIfAbsent(canonical, () => const Uuid().v4());
  }

  Future<String?> _submitSingle(
    ProcurementInspectionItem item,
    String action,
    double? qty,
    String? reason,
  ) async {
    final key = _idempotencyKeyFor(item, action, qty, reason);
    setState(() => _busyDecision = true);
    try {
      await ref
          .read(procurementInspectionRepositoryProvider)
          .dispose(
            receiptType: widget.receiptType,
            receiptId: widget.receiptId,
            inspectionItemId: item.id,
            action: action,
            baseQty: qty,
            reason: reason,
            idempotencyKey: key,
          );
      if (!mounted) return null;
      setState(() {
        _items = [
          for (final row in _items)
            if (row.id != item.id) row,
        ];
        _selectedItemIds = const {};
      });
      await _load();
      ref.invalidate(procurementInspectionPendingCountProvider);
      if (action == 'PASS') {
        ref.invalidate(warehouseQualityResultPendingCountProvider);
      }
      if (mounted) {
        UtenNotify.success(
          context,
          action == 'PASS' ? '合格决定已保存；已转仓库待入库，尚未增加可用库存' : '不合格决定已保存',
        );
      }
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      if (mounted) setState(() => _busyDecision = false);
    }
  }

  Future<String?> _submitBatchPass(String? reason) async {
    final selected = _selectedItems;
    if (selected.isEmpty) return '请先选择待检明细';
    if (selected.length > 100) return '一次最多合格放行 100 条明细';
    final commands = [
      for (final item in selected)
        ProcurementInspectionBatchPassItem(
          inspectionItemId: item.id,
          expectedRemainingBaseQty: item.remainingBaseQty ?? 0,
          idempotencyKey: _idempotencyKeyFor(
            item,
            'PASS',
            item.remainingBaseQty,
            reason,
          ),
        ),
    ];
    setState(() => _busyDecision = true);
    try {
      await ref
          .read(procurementInspectionRepositoryProvider)
          .passBatch(
            receiptType: widget.receiptType,
            receiptId: widget.receiptId,
            items: commands,
            reason: reason,
          );
      if (!mounted) return null;
      final completedIds = selected.map((item) => item.id).toSet();
      setState(() {
        _items = [
          for (final row in _items)
            if (!completedIds.contains(row.id)) row,
        ];
        _selectedItemIds = const {};
      });
      await _load();
      ref.invalidate(procurementInspectionPendingCountProvider);
      ref.invalidate(warehouseQualityResultPendingCountProvider);
      if (mounted) {
        UtenNotify.success(
          context,
          '已原子合格放行 ${selected.length} 条明细；已转仓库待入库，尚未增加可用库存',
        );
      }
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      if (mounted) setState(() => _busyDecision = false);
    }
  }

  Future<void> _openItemDecision(
    ProcurementInspectionItem item, {
    String initialAction = 'PASS',
    bool requireQuantity = false,
  }) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: !_busyDecision,
      builder: (dialogContext) => _InspectionDecisionDialog(
        item: item,
        unitName: ref.read(masterNameServiceProvider).unit(item.unitId),
        initialAction: initialAction,
        requireQuantity: requireQuantity,
        onSubmit: (action, qty, reason) =>
            _submitSingle(item, action, qty, reason),
      ),
    );
  }

  Future<void> _openBatchPass() async {
    final selected = _selectedItems;
    if (selected.isEmpty) {
      UtenNotify.warning(context, '请先选择要合格放行的明细');
      return;
    }
    await showDialog<bool>(
      context: context,
      barrierDismissible: !_busyDecision,
      builder: (dialogContext) =>
          _BatchPassDialog(items: selected, onSubmit: _submitBatchPass),
    );
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final selected = _selectedItems;
    final single = selected.length == 1 ? selected.single : null;
    return [
      UtenButton(
        key: const Key('iqc-single-fail'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        onPressed: single == null || _busyDecision
            ? null
            : () => _openItemDecision(single, initialAction: 'FAIL'),
        child: const Text('登记不合格(单行)'),
      ),
      UtenButton(
        key: const Key('iqc-single-partial-pass'),
        type: UtenButtonType.tonal,
        size: UtenButtonSize.large,
        onPressed: single == null || _busyDecision
            ? null
            : () => _openItemDecision(single, requireQuantity: true),
        child: const Text('部分合格(单行)'),
      ),
      UtenButton(
        key: const Key('iqc-batch-pass'),
        size: UtenButtonSize.large,
        isLoading: _busyDecision,
        onPressed:
            selectedIds.isEmpty || selectedIds.length > 100 || _busyDecision
            ? null
            : _openBatchPass,
        child: Text('批量合格放行(${selectedIds.length})'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final receipt = _receipt;
    return Scaffold(
      appBar: UtenAppBar(
        title: '检验处置 · ${receipt?.billNo ?? widget.receiptId}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && _items.isNotEmpty,
              onPressed: _loading || _busyDecision ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    // 无快照且拿不到摘要：加载中 / 加载失败 / 不存在（或已处理完）三态。
    if (_receipt == null && _items.isEmpty) {
      if (_loading) {
        return const UtenSkeletonList();
      }
      if (_error != null) {
        return UtenEmpty.error(
          message: _error,
          actionLabel: '重新加载',
          onAction: _load,
        );
      }
      return UtenEmpty(
        icon: Icons.verified_outlined,
        message: '待检单不存在或已处理完成',
        description: '该收货单可能已被其他品质同事处理完毕，或链接已过期。',
        actionLabel: '返回任务中心',
        onAction: () =>
            popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
      );
    }
    // 本单明细全部处置完成：完成态替代工作区。
    if (_items.isEmpty && !_loading && _error == null) {
      return UtenEmpty(
        icon: Icons.verified_outlined,
        message: '本单待检已全部处理完成',
        description: '合格切片已转仓库待入库任务；仓库核对实物和库位后才增加库存。',
        actionLabel: '返回任务中心',
        onAction: () =>
            popOrBackTo(context, defaultPath: RouteName.warehouseInspections),
      );
    }
    final theme = Theme.of(context);
    return UtenContentContainer.wide(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSummaryCard(theme),
          if (_error != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            _InlineWorkbenchError(message: _error!, onRetry: _load),
          ],
          if (_busyDecision) ...[
            const SizedBox(height: UtenSpacing.s8),
            const LinearProgressIndicator(key: Key('iqc-decision-progress')),
          ],
          const SizedBox(height: UtenSpacing.s8),
          Expanded(child: _buildItemTable()),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(ThemeData theme) {
    final receipt = _receipt!;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: receipt.isSubcontract ? '委外回厂' : '采购收货',
                  type: receipt.isSubcontract
                      ? UtenStatusBadgeType.accent
                      : UtenStatusBadgeType.info,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    receipt.billNo ?? receipt.receiptId,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            _InfoLine(
              icon: Icons.storefront_outlined,
              label: '供应商',
              value: receipt.supplierName ?? '—',
            ),
            _InfoLine(
              icon: Icons.event_outlined,
              label: '单据日期',
              value: receipt.billDate ?? '—',
            ),
            _InfoLine(
              icon: Icons.schedule_outlined,
              label: '最近到检',
              value: _fmtDateTime(receipt.lastReceivedAt) ?? '—',
            ),
            _InfoLine(
              icon: Icons.inventory_outlined,
              label: '待检',
              value: '${_items.length} 行明细 · 待检量 $_pendingSummary',
            ),
            const Divider(height: UtenSpacing.s24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    _canHandle
                        ? '勾选多行可一次批量合格放行；双击行或右键菜单做单行检验、部分合格与不合格。'
                        : '当前为只读查看；品质处置需要 procurement_inspection:handle 权限。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemTable() {
    return AbsorbPointer(
      absorbing: _busyDecision,
      child: MasterDataTableView<ProcurementInspectionItem>(
        key: ValueKey('iqc-item-table-${widget.receiptId}'),
        columns: _itemColumns,
        items: _items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        selectable: _canHandle,
        idOf: (item) => _isOpenItem(item) ? item.id : null,
        selectedIds: _selectedItemIds,
        onSelectedIdsChanged: (next) => setState(() => _selectedItemIds = next),
        batchActionsBuilder: _canHandle ? _batchActions : null,
        onRowTap: _canHandle ? _openItemDecision : null,
        canOpenRow: _isOpenItem,
        rowMenuBuilder: _canHandle
            ? (item) => [
                UtenMenuItem(
                  label: '检验本行',
                  icon: Icons.fact_check_outlined,
                  onTap: () => _openItemDecision(item),
                ),
                UtenMenuItem(
                  label: '部分合格',
                  icon: Icons.rule_rounded,
                  onTap: () => _openItemDecision(item, requireQuantity: true),
                ),
                UtenMenuItem(
                  label: '登记不合格',
                  icon: Icons.block_rounded,
                  onTap: () => _openItemDecision(item, initialAction: 'FAIL'),
                ),
              ]
            : null,
        canShowRowMenu: _isOpenItem,
        isLoading: _loading,
        error: _items.isEmpty ? _error : null,
        onRetry: _load,
        emptyMessage: _loading ? '正在加载待检明细' : '本单已无待检明细',
        showFullscreenToggle: false,
      ),
    );
  }

  List<MasterColumnDef<ProcurementInspectionItem>> get _itemColumns => [
    MasterColumnDef(
      key: 'goods',
      label: '货品',
      width: 220,
      value: (item) => [
        item.goodsName,
        if (item.goodsCode?.isNotEmpty == true) '(${item.goodsCode})',
      ].whereType<String>().join(),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 100,
      value: (item) => item.colorName ?? '—',
    ),
    MasterColumnDef(
      key: 'unit',
      label: '单位',
      width: 90,
      value: (item) => ref.read(masterNameServiceProvider).unit(item.unitId),
    ),
    MasterColumnDef(
      key: 'sourceOrderNo',
      label: '来源订货单',
      width: 160,
      value: (item) => item.sourceOrderNo ?? '—',
    ),
    MasterColumnDef(
      key: 'receivedBaseQty',
      label: '到检量',
      width: 100,
      type: 'number',
      value: (item) => _fmt(item.receivedBaseQty ?? 0),
    ),
    MasterColumnDef(
      key: 'passedBaseQty',
      label: '已合格',
      width: 100,
      type: 'number',
      value: (item) => _fmt(item.passedBaseQty ?? 0),
    ),
    MasterColumnDef(
      key: 'failedBaseQty',
      label: '不合格',
      width: 100,
      type: 'number',
      value: (item) => _fmt(item.failedBaseQty ?? 0),
    ),
    MasterColumnDef(
      key: 'remainingBaseQty',
      label: '剩余待检',
      width: 110,
      type: 'number',
      value: (item) => _fmt(item.remainingBaseQty ?? 0),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 90,
      value: (item) => switch (item.status) {
        'PARTIAL' => '部分处置',
        'RESOLVED' => '已结案',
        'REVERSED' => '已撤销',
        _ => '待检',
      },
    ),
  ];
}

class _InspectionDecisionDialog extends StatefulWidget {
  const _InspectionDecisionDialog({
    required this.item,
    required this.unitName,
    required this.initialAction,
    required this.requireQuantity,
    required this.onSubmit,
  });

  final ProcurementInspectionItem item;
  final String unitName;
  final String initialAction;
  final bool requireQuantity;
  final Future<String?> Function(String action, double? qty, String? reason)
  onSubmit;

  @override
  State<_InspectionDecisionDialog> createState() =>
      _InspectionDecisionDialogState();
}

class _InspectionDecisionDialogState extends State<_InspectionDecisionDialog> {
  late String _action = widget.initialAction;
  final TextEditingController _qty = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  String? _qtyError;
  String? _reasonError;
  String? _submitError;
  bool _saving = false;

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pass = _action == 'PASS';
    final qtyText = _qty.text.trim();
    final reason = _reason.text.trim();
    double? qty;
    String? qtyError;
    if (qtyText.isNotEmpty) {
      qty = double.tryParse(qtyText);
      if (qty == null ||
          qty <= 0 ||
          qty > (widget.item.remainingBaseQty ?? 0)) {
        qtyError = '须为正数且不超过剩余 ${_fmt(widget.item.remainingBaseQty ?? 0)}';
      }
    } else if (widget.requireQuantity) {
      qtyError = '部分合格必须填写本次合格数量';
    }
    final reasonError = !pass && reason.isEmpty ? '不合格原因必填' : null;
    if (qtyError != null || reasonError != null) {
      setState(() {
        _qtyError = qtyError;
        _reasonError = reasonError;
      });
      return;
    }
    setState(() {
      _saving = true;
      _submitError = null;
      _qtyError = null;
      _reasonError = null;
    });
    final error = await widget.onSubmit(
      _action,
      qty,
      reason.isEmpty ? null : reason,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _submitError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pass = _action == 'PASS';
    final goodsLabel = [
      widget.item.goodsName,
      widget.item.goodsCode,
      widget.item.colorName,
    ].where((text) => text?.isNotEmpty == true).join(' · ');
    return AlertDialog(
      title: const Text('检验本行'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenReviewerResponsibilityNotice(
                actionLabel: pass ? '合格放行' : '不合格处置',
                description: '系统将记录审核员、结论、数量与时间，请依据本行实物检验结果确认。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                goodsLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '剩余待检 ${_fmt(widget.item.remainingBaseQty ?? 0)} '
                '${widget.unitName}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'PASS',
                    label: Text('合格', key: Key('iqc-action-pass')),
                  ),
                  ButtonSegment(
                    value: 'FAIL',
                    label: Text('不合格', key: Key('iqc-action-fail')),
                  ),
                ],
                selected: {_action},
                onSelectionChanged: _saving
                    ? null
                    : (selection) => setState(() {
                        _action = selection.first;
                        _reasonError = null;
                        _submitError = null;
                      }),
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _qty,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  label: fieldLabel(
                    '${pass ? '合格数量' : '不合格数量'}（${widget.unitName}）',
                    theme,
                    info: widget.requireQuantity
                        ? '必填；部分处置后本行继续保留'
                        : '留空 = 全部剩余待检量',
                  ),
                  error: _qtyError == null
                      ? null
                      : UtenFieldMessage.error(_qtyError!),
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                controller: _reason,
                enabled: !_saving,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: pass ? '放行说明(选填)' : '不合格原因(必填)',
                  error: _reasonError == null
                      ? null
                      : UtenFieldMessage.error(_reasonError!),
                ),
              ),
              if (_submitError != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _submitError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
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
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          isLoading: _saving,
          type: pass ? UtenButtonType.primary : UtenButtonType.danger,
          onPressed: _saving ? null : _submit,
          child: Text(pass ? '确认合格' : '确认不合格'),
        ),
      ],
    );
  }
}

class _BatchPassDialog extends StatefulWidget {
  const _BatchPassDialog({required this.items, required this.onSubmit});

  final List<ProcurementInspectionItem> items;
  final Future<String?> Function(String? reason) onSubmit;

  @override
  State<_BatchPassDialog> createState() => _BatchPassDialogState();
}

class _BatchPassDialogState extends State<_BatchPassDialog> {
  final TextEditingController _reason = TextEditingController();
  String? _submitError;
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _submitError = null;
    });
    final reason = _reason.text.trim();
    final error = await widget.onSubmit(reason.isEmpty ? null : reason);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _submitError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('批量合格放行 ${widget.items.length} 条'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const UtenReviewerResponsibilityNotice(
                actionLabel: '批量合格放行',
                description: '本次仅处理当前收货单中已勾选的明细；任一行状态变化都会整批回滚。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '将按各行当前全部剩余待检量放行：',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              for (final item in widget.items.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                  child: Text(
                    '• ${item.goodsName ?? item.goodsCode ?? item.id} · '
                    '${_fmt(item.remainingBaseQty ?? 0)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (widget.items.length > 6)
                Text(
                  '另有 ${widget.items.length - 6} 条',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                controller: _reason,
                enabled: !_saving,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(labelText: '统一放行说明(选填)'),
              ),
              if (_submitError != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _submitError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
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
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          isLoading: _saving,
          onPressed: _saving ? null : _submit,
          child: const Text('确认整批合格'),
        ),
      ],
    );
  }
}

class _InlineWorkbenchError extends StatelessWidget {
  const _InlineWorkbenchError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(width: 80, child: Text('$label：')),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

String _fmt(double value) {
  final text = value.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
  return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
}

/// OffsetDateTime 序列化值 → 'yyyy-MM-dd HH:mm'；解析不了原样返回。
String? _fmtDateTime(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final text = iso.replaceFirst('T', ' ');
  return text.length > 16 ? text.substring(0, 16) : text;
}
