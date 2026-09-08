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
import '../presentation/procurement_inspection_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
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
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../warehouse/providers/production_finished_inbound_task_count_provider.dart';
import '../../warehouse/providers/procurement_inbound_count_providers.dart';
import '../../warehouse/providers/warehouse_quality_result_count_provider.dart';
import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../models/production_fqc_inspection.dart';
import '../repositories/production_fqc_repository.dart';
import '../widgets/inspection_report_confirm_dialog.dart';
import '../widgets/production_fqc_dialogs.dart';
import 'quality_batch_approval_page.dart';

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
      // 选择清理口径与 idOf 同源：FQC 任务 id + IQC 收货单复合 id。
      final currentIds = <String>{
        if (_canDecideFqc) ...?(_fqcInspections?.map((item) => item.id)),
        if (_canHandleIqc)
          for (final receipt in _receipts ?? const <PendingInspectionReceipt>[])
            'iqc:${receipt.receiptType}:${receipt.receiptId}',
      };
      _selectedIds.removeWhere((id) => !currentIds.contains(id));
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

  /// 「批量审批」（2026-09-05 用户口径）：多选的 IQC 收货单与 FQC 任务汇总到
  /// 一个页面——逐行填合格/不合格数量（默认全合格）后一次「提交报告」。
  Future<void> _openBatchApproval(Set<String> selectedIds) async {
    if (selectedIds.isEmpty) {
      context.appWarning('请先选择待检任务（IQC 收货单或自制产成品）');
      return;
    }
    final receipts = [
      for (final receipt in _receipts ?? const <PendingInspectionReceipt>[])
        if (selectedIds.contains(
          'iqc:${receipt.receiptType}:${receipt.receiptId}',
        ))
          receipt,
    ];
    final inspections = [
      for (final inspection
          in _fqcInspections ?? const <ProductionFqcInspection>[])
        if (selectedIds.contains(inspection.id)) inspection,
    ];
    if (receipts.isEmpty && inspections.isEmpty) {
      context.appWarning('所选任务状态已变化，请刷新后重新选择');
      return;
    }
    final done = await context.push<bool>(
      RouteName.warehouseInspectionBatchApproval,
      extra: QualityBatchApprovalSelection(
        receipts: receipts,
        inspections: inspections,
      ),
    );
    if (!mounted) return;
    setState(() => _selectedIds.clear());
    if (done == true) await _load();
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final count = selectedIds.length;
    return [
      Tooltip(
        message: count == 0
            ? '请选择待检任务（IQC 收货单 / 自制产成品）'
            : '所选任务汇总到一个页面：逐行填合格/不合格数量后一次提交报告',
        child: UtenButton(
          key: const Key('quality-batch-approval'),
          size: UtenButtonSize.large,
          icon: Icons.fact_check_outlined,
          onPressed: count == 0 ? null : () => _openBatchApproval(selectedIds),
          onDisabledTap: count == 0
              ? () => context.appWarning('请先选择待检任务（IQC 收货单或自制产成品）')
              : null,
          child: Text(count == 0 ? '批量审批' : '批量审批($count)'),
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
                // 2026-09-05 起 IQC 收货单也可多选（此前只有 FQC 可勾）：
                // 勾选后走「批量审批」汇总页。
                selectable: _canDecideFqc || _canHandleIqc,
                idOf: (row) => row.isFqc
                    ? (_canDecideFqc && row.inspection!.active
                          ? row.inspection!.id
                          : null)
                    : (_canHandleIqc
                          ? 'iqc:${row.receipt!.receiptType}:${row.receipt!.receiptId}'
                          : null),
                // 行稳定键单独给：IQC 用收货单 id，FQC 用任务 id。
                rowKeyOf: (row) =>
                    row.isFqc ? row.inspection!.id : row.receipt!.receiptId,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: (next) => setState(
                  () => _selectedIds
                    ..clear()
                    ..addAll(next),
                ),
                batchActionsBuilder: _canDecideFqc || _canHandleIqc
                    ? _batchActions
                    : null,
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
        '勾选多张任务后点「批量审批」——汇总到一个页面逐行填合格/不合格数量，'
        '一次「提交报告」办结。';
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

  /// 逐行可编辑的检验报告状态（合格默认=剩余待检、不合格默认=0），
  /// 键为 inspection item id；_load 重建（旧控制器先 dispose）。
  final Map<String, _InspectionReportRow> _reportRows = {};
  bool _loading = true;
  bool _busyDecision = false;
  String? _error;
  Set<String> _selectedItemIds = const {};
  int _requestVersion = 0;

  bool get _canHandle {
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        permissions.contains(Perm.procurementInspectionHandle);
  }

  @override
  void dispose() {
    for (final row in _reportRows.values) {
      row.dispose();
    }
    super.dispose();
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
        for (final row in _reportRows.values) {
          row.dispose();
        }
        _reportRows
          ..clear()
          ..addEntries([
            for (final item in openRows)
              MapEntry(item.id, _InspectionReportRow(item)),
          ]);
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
    return inspectionQuantityTotalText(
      context,
      _items.map((item) => (item, item.remainingBaseQty ?? 0)),
    );
  }

  /// 「提交报告」（2026-09-05 用户口径：唯一动作按钮）：所选行合格/不合格数量
  /// 一次提交——总结确认弹窗（仿计划部下达采购）后走 decide-batch 单事务。
  Future<void> _submitReport() async {
    if (_busyDecision) return;
    final selected = _selectedItems;
    if (selected.isEmpty) {
      UtenNotify.warning(context, '请先勾选要提交的明细行');
      return;
    }
    if (selected.length > 100) {
      UtenNotify.warning(context, '一次最多提交 100 条明细');
      return;
    }
    for (final item in selected) {
      final problem = _reportRows[item.id]?.validate();
      if (problem != null) {
        UtenNotify.warning(
          context,
          '${item.goodsName ?? item.goodsCode ?? '明细'}：$problem',
        );
        return;
      }
    }
    final rows = [for (final item in selected) _reportRows[item.id]!];
    final passTotalText = inspectionQuantityTotalText(
      context,
      rows.map((row) => (row.item, row.passValue)),
    );
    final failTotalText = inspectionQuantityTotalText(
      context,
      rows.map((row) => (row.item, row.failValue)),
    );
    final hasFail = rows.any((row) => row.failValue > 0);
    final reason = await showInspectionReportConfirmDialog(
      context,
      lineCount: rows.length,
      passTotalText: inspectionQuantityTotalText(
        context,
        rows.map((row) => (row.item, row.passValue)),
      ),
      failTotalText: inspectionQuantityTotalText(
        context,
        rows.map((row) => (row.item, row.failValue)),
      ),
      requireReason: hasFail,
      lines: [
        for (final row in rows)
          InspectionReportConfirmLine(
            label: [
              row.item.goodsName,
              row.item.goodsCode,
              row.item.colorName,
            ].where((text) => text?.isNotEmpty == true).join(' · '),
            passText: _fmt(row.passValue),
            failText: _fmt(row.failValue),
            dim: inspectionQuantityUnit(context, row.item),
          ),
      ],
    );
    if (reason == null || !mounted) return;
    setState(() => _busyDecision = true);
    try {
      await ref
          .read(procurementInspectionRepositoryProvider)
          .decideBatch(
            receiptType: widget.receiptType,
            receiptId: widget.receiptId,
            reason: reason.isEmpty ? null : reason,
            items: [
              for (final row in rows)
                ProcurementInspectionDecideItem(
                  inspectionItemId: row.item.id,
                  expectedRemainingBaseQty: row.item.remainingBaseQty ?? 0,
                  passBaseQty: row.passValue,
                  failBaseQty: row.failValue,
                  idempotencyKey: row.idempotencyKey,
                ),
            ],
          );
      if (!mounted) return;
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
          '检验报告已提交（合格 $passTotalText'
          '${hasFail ? '、不合格 $failTotalText' : ''}）；'
          '合格部分已转仓库待入库，尚未增加可用库存',
        );
      }
    } on ApiException catch (error) {
      if (mounted) {
        UtenNotify.error(context, '提交被拒：${error.message}；请刷新后按最新待检量重填');
      }
    } catch (_) {
      if (mounted) {
        UtenNotify.error(context, '提交检验报告失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _busyDecision = false);
    }
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    return [
      Padding(
        padding: const EdgeInsets.only(right: UtenSpacing.s12),
        child: Text(
          '已选 ${selectedIds.length} 项',
          key: const Key('iqc-report-selected-count'),
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      UtenButton(
        key: const Key('iqc-submit-report'),
        size: UtenButtonSize.large,
        icon: Icons.fact_check_outlined,
        isLoading: _busyDecision,
        onPressed: selectedIds.isEmpty || _busyDecision ? null : _submitReport,
        onDisabledTap: selectedIds.isEmpty
            ? () => UtenNotify.warning(context, '请先勾选要提交的明细行')
            : null,
        child: const Text('提交报告'),
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
    // A deep link can still load exact receipt items after the pending queue no
    // longer contains its summary. The queue is not the detail data authority.
    final receipt =
        _receipt ??
        PendingInspectionReceipt(
          receiptType: widget.receiptType,
          receiptId: widget.receiptId,
        );
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
                        ? '行内直接修改合格数量/不合格数量（默认全合格），勾选后点'
                              '「提交报告」一次办结；含不合格数量时结论原因必填。'
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
        // 2026-09-05 起行内直接编辑合格/不合格数量，唯一动作是底部「提交报告」；
        // 单行弹窗（登记不合格/部分合格/批量合格放行）与右键菜单一并下线。
        canOpenRow: _isOpenItem,
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
      label: '验收单位',
      width: 90,
      value: (item) => inspectionQuantityUnit(context, item),
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
      key: 'passQty',
      label: '合格数量',
      width: 120,
      type: 'number',
      value: (item) => _reportRows[item.id]?.pass.text ?? '0',
      cellBuilder: (context, item) {
        final row = _reportRows[item.id];
        if (row == null) return const Text('—');
        return Semantics(
          textField: true,
          label: '${item.goodsName ?? '明细'} 本次合格数量',
          child: TextField(
            key: ValueKey('iqc-report-pass-${item.id}'),
            controller: row.pass,
            enabled: _canHandle && !_busyDecision,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            decoration: UtenInputDecoration(
              const InputDecoration(isDense: true),
              info: inspectionQuantityHint(context, item, passed: true),
            ),
          ),
        );
      },
    ),
    MasterColumnDef(
      key: 'failQty',
      label: '不合格数量',
      width: 120,
      type: 'number',
      value: (item) => _reportRows[item.id]?.fail.text ?? '0',
      cellBuilder: (context, item) {
        final row = _reportRows[item.id];
        if (row == null) return const Text('—');
        return Semantics(
          textField: true,
          label: '${item.goodsName ?? '明细'} 本次不合格数量',
          child: TextField(
            key: ValueKey('iqc-report-fail-${item.id}'),
            controller: row.fail,
            enabled: _canHandle && !_busyDecision,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            decoration: UtenInputDecoration(
              InputDecoration(
                isDense: true,
                error: row.validate() == null
                    ? null
                    : UtenFieldMessage.error(row.validate()!),
              ),
              info: inspectionQuantityHint(context, item, passed: false),
            ),
          ),
        );
      },
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

/// 检验报告一行的可编辑状态：合格默认=剩余待检、不合格默认=0；
/// 幂等键随行生成一次，同页重试复用。
class _InspectionReportRow {
  _InspectionReportRow(this.item)
    : pass = TextEditingController(text: _fmt(item.remainingBaseQty ?? 0)),
      fail = TextEditingController(text: '0');

  final ProcurementInspectionItem item;
  final TextEditingController pass;
  final TextEditingController fail;
  final String idempotencyKey = 'iqc-report-${const Uuid().v4()}';

  double get passValue => double.tryParse(pass.text.trim()) ?? 0;
  double get failValue => double.tryParse(fail.text.trim()) ?? 0;

  /// null = 校验通过；否则为错误文案。
  String? validate() {
    final remaining = item.remainingBaseQty ?? 0;
    if (passValue < 0 || failValue < 0) return '数量不能为负';
    if (passValue + failValue <= 0) return '合格与不合格不能同时为 0';
    if (passValue + failValue > remaining + 1e-9) {
      return '合计不能超过剩余待检 ${_fmt(remaining)}';
    }
    return null;
  }

  void dispose() {
    pass.dispose();
    fail.dispose();
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
