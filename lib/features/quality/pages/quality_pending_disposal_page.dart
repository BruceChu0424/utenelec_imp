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
// FQC 行 = 品质检查单（V547：同仓一次送检的报工行聚合；双击进检查单办理，逐条
// PASS/FAIL 或全部合格）；V547 前无检查单的历史待检任务按「无检查单」逐条显示。
// 权限分别门控：IQC 读 procurement_inspection:view、写 :handle；
// FQC 读 production_quality_inspection:view、决定 :approve + 服务端品质组织校验。
import 'package:flutter/material.dart';
import '../presentation/procurement_inspection_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../models/production_fqc_inspection.dart';
import '../repositories/production_fqc_repository.dart';
import '../widgets/inspection_report_confirm_dialog.dart';
import '../widgets/production_fqc_dialogs.dart';
import 'quality_batch_approval_page.dart';
import '../../../shared/badges/badge_registry.dart';

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

  /// FQC 待处理品质检查单（V547；无 FQC 查看权限时恒为 null 且不请求）。
  List<ProductionFqcInspectionSheet>? _fqcSheets;

  /// 无检查单的历史 FQC 待处理任务（sheet=NONE），逐条作为「无检查单」行。
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

  /// 表头「状态」快速筛选（2026-09-11 全站补齐）：null = 所有。本页把三个域
  /// 的待检任务**全量**装在 _rows 里、由前端切页，故筛选作用于全集而非当页。
  String? _statusFilter;
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
    // 2026-09-18 批量提交后返回队列的重载：IQC 收货单、FQC 决定能力、检查单、
    // 散任务四个独立读并发发出（原先串行四次往返，提交后的等待被拉长一整圈）。
    // 各域成功才覆盖、失败保留旧数据的口径与串行版一致。
    List<PendingInspectionReceipt>? receipts;
    Future<void> loadReceipts() async {
      if (!_canViewIqc) return;
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

    List<ProductionFqcInspectionSheet>? sheets;
    List<ProductionFqcInspection>? inspections;
    var fqcTotal = 0;
    var fqcTruncated = false;
    var canDecideFqc = false;
    Future<void> loadFqc() async {
      if (!_canViewFqc) return;
      try {
        final repo = ref.read(productionFqcRepositoryProvider);
        final permissions = ref.read(currentPermissionsProvider);
        final mayApprove =
            ref.read(isSuperAdminProvider) ||
            permissions.contains(Perm.productionQualityInspectionApprove);
        // 决定能力 fail closed；失败不拖垮任务读取，与原串行版一致。
        Future<bool> capability() async {
          if (!mayApprove) return false;
          try {
            return await repo.canDecide();
          } catch (_) {
            return false;
          }
        }

        final canDecide = capability();
        // status 默认 'ACTIVE'（仍有待检行），与待检口径一致：
        // 一行一张检查单 + 无检查单的历史任务逐条（与 /count 角标同口径）。
        final sheetResult = await repo.listSheets(size: _fqcFetchSize);
        final looseResult = await repo.list(size: _fqcFetchSize, sheet: 'NONE');
        canDecideFqc = await canDecide;
        sheets = sheetResult.items;
        inspections = looseResult.items;
        fqcTotal = sheetResult.total + looseResult.total;
        fqcTruncated =
            sheetResult.total > sheetResult.items.length ||
            looseResult.total > looseResult.items.length;
      } on ApiException catch (error) {
        errors.add('自制产成品待检：${error.message}');
      } catch (_) {
        errors.add('自制产成品待检任务加载失败');
      }
    }

    final receiptsFuture = loadReceipts();
    await Future.wait([receiptsFuture, loadFqc()]);
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
        if (inspections != null && sheets != null) {
          _fqcSheets = sheets;
          _fqcInspections = inspections;
          _fqcTotal = fqcTotal;
          _fqcTruncated = fqcTruncated;
        }
      } else {
        _fqcSheets = const [];
        _fqcInspections = const [];
        _fqcTotal = 0;
      }
      _canDecideFqc = canDecideFqc;
      _loading = false;
      _error = errors.isEmpty ? null : errors.join('；');
      // 刷新后旧状态筛选值可能已消失：先撤掉再收敛页码（顺序不能反，
      // _totalPages 读的是筛选后的行数）。
      _pruneStatusFilter();
      if (_page > _totalPages) _page = _totalPages;
      // 选择清理口径与 idOf 同源：检查单复合 id + 无检查单任务 id + IQC 收货单复合 id。
      final currentIds = <String>{
        if (_canDecideFqc) ...?(_fqcInspections?.map((item) => item.id)),
        if (_canDecideFqc)
          ...?(_fqcSheets?.map((sheet) => 'sheet:${sheet.id}')),
        if (_canHandleIqc)
          for (final receipt in _receipts ?? const <PendingInspectionReceipt>[])
            'iqc:${receipt.receiptType}:${receipt.receiptId}',
      };
      _selectedIds.removeWhere((id) => !currentIds.contains(id));
    });
  }

  void _applySearch(String value) {
    if (value == _keyword) return;
    setState(() {
      _keyword = value;
      _pruneStatusFilter();
      _page = 1;
    });
  }

  /// 类型筛选（分段按钮与表头筛选共用这一个口径）：null = 全部待检。
  void _selectType(String? type) {
    if (_typeFilter == type && _typeFilterSelected) return;
    setState(() {
      _typeFilter = type;
      _typeFilterSelected = true;
      _pruneStatusFilter();
      _page = 1;
    });
  }

  bool _matchesKeyword(_DisposalRow row) {
    final keyword = _keyword.trim().toLowerCase();
    if (keyword.isEmpty) return true;
    if (row.isSheet) {
      final sheet = row.sheet!;
      final text = [
        sheet.sheetNo,
        sheet.warehouseName,
        sheet.receiverName,
        sheet.reportNos,
        sheet.goodsSummary,
      ].whereType<String>().join(' ').toLowerCase();
      return text.contains(keyword);
    }
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
    if (_fqcSheets != null)
      for (final sheet in _fqcSheets!) _DisposalRow.sheet(sheet),
    if (_fqcInspections != null)
      for (final inspection in _fqcInspections!) _DisposalRow.fqc(inspection),
  ];

  /// 行的状态文案（状态列单元与表头筛选共用同一口径）。
  String _statusLabel(_DisposalRow row) => row.isSheet
      ? (row.sheet!.activeCount < row.sheet!.itemCount ? '部分已决定' : '待检')
      : row.isFqc
      ? fqcStatusLabel(row.inspection!)
      : '待检';

  /// 「状态」表头筛选的桶（按类型/关键字收敛后的行集计数，与眼前所见一致）。
  List<MasterFacetBucket> get _statusFacets {
    final counts = <String, int>{};
    for (final row in _rows) {
      if (_typeFilter != null && row.kind != _typeFilter) continue;
      if (!_matchesKeyword(row)) continue;
      final label = _statusLabel(row);
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return [
      for (final entry in counts.entries)
        MasterFacetBucket(
          value: entry.key,
          count: entry.value,
          label: entry.key,
        ),
    ]..sort((a, b) => a.display.compareTo(b.display));
  }

  /// 刷新/切类型后旧状态值可能已不存在：撤回「所有」，避免用户面对空表却
  /// 看不到激活的筛选（表头筛选单元会 sanitize 回列名）。
  void _pruneStatusFilter() {
    if (_statusFilter == null) return;
    if (!_statusFacets.any((bucket) => bucket.value == _statusFilter)) {
      _statusFilter = null;
    }
  }

  List<_DisposalRow> get _filtered => [
    for (final row in _rows)
      if ((_typeFilter == null || row.kind == _typeFilter) &&
          (_statusFilter == null || _statusLabel(row) == _statusFilter) &&
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

  /// 双击检查单行：进入 FQC 检查单办理页（2026-09-12 弹窗改页，对齐采购 IQC
  /// 处置页范式——摘要卡 + 行级合格/不合格数量 + 提交报告）；返回后重拉队列。
  Future<void> _openSheet(ProductionFqcInspectionSheet sheet) async {
    await context.push(
      RouteName.productionFqcSheetHandling(sheet.id),
      extra: sheet,
    );
    if (!mounted) return;
    refreshBadges(ref);
    await _load();
  }

  /// 双击 FQC 行 / 右键「办理质检」：进入单任务办理页（详情 + 决定 + 检验证据）。
  Future<void> _openFqcDetail(_DisposalRow row) async {
    final inspection = row.inspection!;
    await context.push(
      RouteName.productionFqcInspectionHandling(inspection.id),
      extra: inspection,
    );
    if (!mounted) return;
    refreshBadges(ref);
    await _load();
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
    final sheets = [
      for (final sheet in _fqcSheets ?? const <ProductionFqcInspectionSheet>[])
        if (selectedIds.contains('sheet:${sheet.id}')) sheet,
    ];
    if (receipts.isEmpty && inspections.isEmpty && sheets.isEmpty) {
      context.appWarning('所选任务状态已变化，请刷新后重新选择');
      return;
    }
    final done = await context.push<bool>(
      RouteName.warehouseInspectionBatchApproval,
      extra: QualityBatchApprovalSelection(
        receipts: receipts,
        inspections: inspections,
        sheets: sheets,
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
          type: UtenButtonType.danger,
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
          UtenAppBarActionButton(
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading && _rows.isNotEmpty,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && _receipts == null && _fqcSheets == null
            ? const UtenSkeletonList()
            : _error != null && _receipts == null && _fqcSheets == null
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
    final fqcCount = _fqcSheets == null ? null : _fqcTotal;
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        // 2026-09-15 用户口径：对齐其他列表页的「整页先滚 → 工具条与表头顶到
        // 页面顶 → 表体内滚」联动。错误横幅/提示行随页滚走；分段+搜索工具条
        // 钉在表头上方一起到顶，之后表格（primary:true）接手内滚。
        child: UtenCollapsingHeaderScrollView(
          collapsingHeader: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                _InlineWorkbenchError(message: _error!, onRetry: _load),
              _buildAuxHints(),
              const SizedBox(height: UtenSpacing.s12),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildFilterToolbar(purchaseCount, subcontractCount, fqcCount),
              const SizedBox(height: UtenSpacing.s12),
              Expanded(
                child: MasterDataTableView<_DisposalRow>(
                  key: const Key('iqc-receipt-table'),
                  primary: true,
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
                    // 状态桶按当前类型/关键字口径实时统计（客户端全集，非当页）。
                    'status': _statusFacets,
                  },
                  nullCounts: const {},
                  filters: {'docType': _typeFilter, 'status': _statusFilter},
                  // 类型分段条在表外、空态也一直看得见，用户随时能切回「全部」；
                  // 表里再给一个「清除筛选」是重复入口（状态筛选只有表头有，保留）。
                  externalFilterKeys: const {'docType'},
                  onFilterChanged: (key, value) {
                    if (key == 'status') {
                      setState(() {
                        _statusFilter = value;
                        _page = 1;
                      });
                      return;
                    }
                    if (key != 'docType') return;
                    _selectType(value);
                  },
                  // 2026-09-05 起 IQC 收货单也可多选（此前只有 FQC 可勾）：
                  // 勾选后走「批量审批」汇总页。
                  selectable: _canDecideFqc || _canHandleIqc,
                  idOf: (row) => row.isSheet
                      ? (_canDecideFqc && row.sheet!.active
                            ? 'sheet:${row.sheet!.id}'
                            : null)
                      : row.isFqc
                      ? (_canDecideFqc && row.inspection!.active
                            ? row.inspection!.id
                            : null)
                      : (_canHandleIqc
                            ? 'iqc:${row.receipt!.receiptType}:${row.receipt!.receiptId}'
                            : null),
                  // 行稳定键单独给：IQC 用收货单 id，检查单用单 id，无检查单任务用任务 id。
                  rowKeyOf: (row) => row.isSheet
                      ? row.sheet!.id
                      : row.isFqc
                      ? row.inspection!.id
                      : row.receipt!.receiptId,
                  selectedIds: _selectedIds,
                  onSelectedIdsChanged: (next) => setState(
                    () => _selectedIds
                      ..clear()
                      ..addAll(next),
                  ),
                  batchActionsBuilder: _canDecideFqc || _canHandleIqc
                      ? _batchActions
                      : null,
                  onRowTap: (row) => row.isSheet
                      ? _openSheet(row.sheet!)
                      : row.isFqc
                      ? _openFqcDetail(row)
                      : _openIqcDetail(row.receipt!),
                  rowMenuBuilder: (row) => row.isSheet
                      ? [
                          UtenMenuItem(
                            label: _canDecideFqc
                                ? '办理检查单(${row.sheet!.activeCount} 行待检)'
                                : '查看检查单',
                            icon: Icons.fact_check_outlined,
                            onTap: () => _openSheet(row.sheet!),
                          ),
                        ]
                      : row.isFqc
                      ? [
                          UtenMenuItem(
                            label: _canDecideFqc ? '办理质检' : '查看质检详情',
                            icon: _canDecideFqc
                                ? Icons.rule_rounded
                                : Icons.visibility_outlined,
                            onTap: () => _openFqcDetail(row),
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
      ),
    );
  }

  Widget _buildFilterToolbar(
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
    // 全平台统一筛选工具条：分段 + 胶囊搜索框。计数形态：三个来源段都是
    // 「等我验货」的待检队列 → 红徽章；「全部待检单」不传 count（没有总量段
    // 与之重复红一次）。
    return Semantics(
      header: true,
      label: '共有 ${_rows.length} 条待检任务',
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
              countForm: UtenSegmentCountForm.actionable,
            ),
            UtenFilterSegment(
              value: 'subcontract',
              label: '委外回厂',
              count: subcontractCount,
              countForm: UtenSegmentCountForm.actionable,
            ),
          ],
          if (_canViewFqc)
            UtenFilterSegment(
              value: 'fqc',
              label: '自制产成品',
              count: fqcCount,
              countForm: UtenSegmentCountForm.actionable,
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
    );
  }

  /// 提示行与截断告警：放折叠头（随页滚走），不再常驻占表体高度。
  Widget _buildAuxHints() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
    return '采购/委外收货与自制产成品送检后出现在这里：自制产成品一行一张品质检查单'
        '（同仓一次送检合并），双击进入处置；勾选多张后点「批量审批」——汇总到一个页面'
        '逐行填合格/不合格数量，一次「提交报告」办结。';
  }

  /// 已上架待检的行数：IQC 按收货单、检查单按单、无检查单的历史 FQC 任务按行。
  int _preStockedLineCount(_DisposalRow row) {
    if (row.isSheet) return row.sheet!.preStockedItemCount;
    if (row.isFqc) return row.inspection!.preStocked == null ? 0 : 1;
    return row.receipt!.preStockedItemCount;
  }

  /// 已上架行的标红样式（2026-09-18 起「仓库 / 库位号」两列共用）。
  TextStyle? _preStockedStyle(BuildContext context) => Theme.of(context)
      .textTheme
      .bodyMedium
      ?.copyWith(color: UtenColors.error, fontWeight: FontWeight.w700);

  /// 「仓库」列：IQC 取已上架行的去重仓名（未上架=待检区）；FQC 检查单/历史任务
  /// 取登记成品仓——成品登记时逐行必填仓+库位，位置始终可知。
  String _warehouseText(_DisposalRow row) => row.isSheet
      ? (row.sheet!.warehouseName ?? '—')
      : row.isFqc
      ? (row.inspection!.warehouseName ?? '—')
      : (row.receipt!.preStockedWarehouseNames ?? '待检区');

  /// 「库位号」列：IQC 取已上架行的去重库位清单；FQC 检查单取待检行登记库位
  /// 去重清单(place_summary)；无检查单的历史任务直接用本行登记库位。
  String _placeText(_DisposalRow row) => row.isSheet
      ? (row.sheet!.placeSummary ?? '—')
      : row.isFqc
      ? (row.inspection!.place ?? '—')
      : (row.receipt!.preStockedPlaces ?? '—');

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
      value: (row) => row.isSheet
          ? row.sheet!.sheetNo
          : row.isFqc
          ? (row.inspection!.reportNo ?? row.inspection!.id)
          : (row.receipt!.billNo ?? row.receipt!.receiptId),
    ),
    MasterColumnDef(
      key: 'party',
      label: '供应商 / 成品仓 / 报工',
      width: 230,
      value: (row) => row.isSheet
          ? [
              row.sheet!.warehouseName,
              if (row.sheet!.receiverName?.isNotEmpty == true)
                '收货 ${row.sheet!.receiverName}',
              if (row.sheet!.reportNos?.isNotEmpty == true)
                '报工 ${row.sheet!.reportNos}',
            ].whereType<String>().join(' · ')
          : row.isFqc
          ? '无检查单 · 计划 ${row.inspection!.planNo ?? '—'}'
          : (row.receipt!.supplierName ?? '—'),
    ),
    // 无检查单的 FQC 行此前只有名称 + 颜色，补上编号：队列里同名的自制件与
    // 委外件排在一起，认错货就会把判定登到别的批次上。本表没有独立编号/颜色列，
    // 三属性都进身份格；检查单行是服务端拼好的多货品摘要，无法拆分故原样显示。
    MasterColumnDef(
      key: 'goods',
      label: '货品名称',
      width: 200,
      value: (row) => row.isSheet
          ? (row.sheet!.goodsSummary ?? '—')
          : row.isFqc
          ? (row.inspection!.goodsName ?? '—')
          : '—',
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => row.isFqc
          ? UtenGoodsIdentityCell(name: row.inspection!.goodsName)
          : Text(
              row.isSheet ? (row.sheet!.goodsSummary ?? '—') : '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
    // 本表是混合行：检查单行是「多货品汇总」、收货单行没有单一货品，这两类
    // 在编号/颜色列如实显示「—」，不拿汇总串冒充单件身份。
    MasterColumnDef(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: (row) => row.isFqc
          ? UtenGoodsAttributeCell.text(row.inspection!.goodsCode)
          : null,
      cellBuilder: (_, row) =>
          UtenGoodsAttributeCell(row.isFqc ? row.inspection!.goodsCode : null),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 96,
      value: (row) => row.isFqc
          ? UtenGoodsAttributeCell.text(row.inspection!.colorName)
          : null,
      cellBuilder: (_, row) =>
          UtenGoodsAttributeCell(row.isFqc ? row.inspection!.colorName : null),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: _statusLabel,
    ),
    // 先入库后检(V596 IQC / V597 FQC)：仓库把货先落到库位的单，品质部要到储放区域
    // 检验（2026-09-18 用户口径：直接给「仓库 / 库位号」两列，不用逐单点进明细找位置）。
    MasterColumnDef(
      key: 'warehouse',
      label: '仓库',
      width: 140,
      value: _warehouseText,
      cellBuilder: (context, row) => Text(
        _warehouseText(row),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _preStockedLineCount(row) > 0 ? _preStockedStyle(context) : null,
      ),
    ),
    MasterColumnDef(
      key: 'place',
      label: '库位号',
      width: 150,
      value: _placeText,
      cellBuilder: (context, row) => Text(
        _placeText(row),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _preStockedLineCount(row) > 0 ? _preStockedStyle(context) : null,
      ),
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '待检行数',
      width: 95,
      type: 'number',
      value: (row) => row.isSheet
          ? row.sheet!.activeCount.toString()
          : row.isFqc
          ? '1'
          : row.receipt!.itemCount.toString(),
    ),
    MasterColumnDef(
      key: 'pendingQty',
      label: '待检数量',
      width: 150,
      value: (row) => row.isSheet
          ? (row.sheet!.pendingQtyText ?? '—')
          : row.isFqc
          ? '${fqcQtyText(row.inspection!.remainingQty)}'
                '${row.inspection!.unitName ?? ''}'
          : '—',
    ),
    MasterColumnDef(
      key: 'enteredAt',
      label: '最近到检 / 进入质检',
      width: 160,
      type: 'date',
      value: (row) => row.isSheet
          ? ChinaDateTime.formatInstant(row.sheet!.createdAt)
          : row.isFqc
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

/// 统一待检行：IQC 收货单、FQC 品质检查单（V547）或无检查单的历史 FQC 任务。
class _DisposalRow {
  const _DisposalRow.iqc(PendingInspectionReceipt this.receipt)
    : inspection = null,
      sheet = null;
  const _DisposalRow.fqc(ProductionFqcInspection this.inspection)
    : receipt = null,
      sheet = null;
  const _DisposalRow.sheet(ProductionFqcInspectionSheet this.sheet)
    : receipt = null,
      inspection = null;

  final PendingInspectionReceipt? receipt;
  final ProductionFqcInspection? inspection;
  final ProductionFqcInspectionSheet? sheet;

  bool get isSheet => sheet != null;
  bool get isFqc => inspection != null;

  /// 与分段/表头筛选同一取值域：PURCHASE / SUBCONTRACT / FQC。
  String get kind => isSheet || isFqc
      ? 'FQC'
      : (receipt!.isSubcontract ? 'SUBCONTRACT' : 'PURCHASE');
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
      // 徽章汇总重拉一次: 品质待检与仓库「品质部检查结果」红黄两数随之更新。
      refreshBadges(ref);
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
    // 已选计数由表格悬浮组首位的标准胶囊（UtenSelectionSummaryPill）呈现，
    // 这里只放业务动作，不再自摆一份纯文字计数。
    return [
      UtenButton(
        key: const Key('iqc-submit-report'),
        type: UtenButtonType.danger,
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
          UtenAppBarActionButton(
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading && _items.isNotEmpty,
            onPressed: _loading || _busyDecision ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            _buildBody(),
            // 2026-09-12 用户口径：提交报告执行期间屏幕中间加载动画
            //（跟随网络调用本身，失败/完成后撤下）。
            if (_busyDecision)
              const Positioned.fill(child: UtenBusyOverlay(title: '正在提交检验报告')),
          ],
        ),
      ),
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
    final preStockedItems = [
      for (final item in _items)
        if (item.preStocked != null) item,
    ];
    return UtenContentContainer.wide(
      // 2026-09-24 用户口径：对齐其他页的「整页先滚 → 摘要卡随页收起 → 表格
      // 顶到页面顶 → 表体内滚」联动；先入库标红/摘要卡/错误行都随页滚走。
      child: UtenCollapsingHeaderScrollView(
        collapsingHeader: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 先入库后检(V596)：顶部标红——货品已在库位上，不在待检区。
            if (preStockedItems.isNotEmpty ||
                (_receipt?.hasPreStockedItems == true && _items.isEmpty)) ...[
              UtenInlineNotice(
                key: const Key('iqc-pre-stocked-notice'),
                level: UtenInlineNoticeLevel.error,
                title: '货品已入库，需到对应储放区域检查',
                message: _preStockedNoticeMessage(preStockedItems),
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
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
          ],
        ),
        body: _buildItemTable(),
      ),
    );
  }

  /// 顶部标红正文：逐行列出「货品 → 仓库 / 库位」（最多 3 行，其余看表格）。
  String _preStockedNoticeMessage(List<ProcurementInspectionItem> items) {
    if (items.isEmpty) {
      return '仓库已把本单货品先入库上架，储放位置见下方明细的「储放位置」列。'
          '合格后系统自动按上架位置转正入库；不合格由仓库从库位取出登记退回。';
    }
    final shown = items.take(3).toList(growable: false);
    final lines = [
      for (final item in shown)
        '${item.goodsName ?? item.goodsCode ?? '货品'} → ${item.preStocked!.label}',
      if (items.length > shown.length) '另 ${items.length - shown.length} 行见明细表',
    ].join('；');
    return '本单 ${items.length} 行已先入库上架：$lines。'
        '请到对应储放区域检验；合格后系统自动按上架位置转正入库，不合格由仓库从库位取出登记退回。';
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
            // 单据表头事实也走全站同款表格：一张单只有一行，故字段做列、横排一行，
            // 下方明细表与它同一套列对齐/框选口径（原图标 + 文字的逐行罗列已下线）。
            // 弹层/详情页内嵌表统一 embedded：按内容收缩、无翻页条、不出全屏按钮。
            MasterDataTableView<_ReceiptHeaderRow>(
              key: const Key('iqc-receipt-header-table'),
              embedded: true,
              showColumnChooser: false,
              columns: [
                MasterColumnDef(
                  key: 'supplierName',
                  label: '供应商',
                  width: 180,
                  value: (row) => row.supplierName,
                ),
                MasterColumnDef(
                  key: 'billDate',
                  label: '单据日期',
                  width: 120,
                  type: 'date',
                  value: (row) => row.billDate,
                ),
                MasterColumnDef(
                  key: 'lastReceivedAt',
                  label: '最近到检',
                  width: 150,
                  type: 'date',
                  value: (row) => row.lastReceivedAt,
                ),
                MasterColumnDef(
                  key: 'pending',
                  label: '待检',
                  width: 220,
                  value: (row) => row.pending,
                ),
              ],
              items: [
                _ReceiptHeaderRow(
                  supplierName: receipt.supplierName ?? '—',
                  billDate: receipt.billDate ?? '—',
                  lastReceivedAt: _fmtDateTime(receipt.lastReceivedAt) ?? '—',
                  // 待检量由 inspectionQuantityTotalText 按验收单位分组出文案
                  //（跨单位绝不相加），故这里整串直接落格，不再二次拆算。
                  pending: '${_items.length} 行明细 · 待检量 $_pendingSummary',
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
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
        // 折叠头联动：表体拾取 PrimaryScrollController，页面先滚、表格置顶后内滚。
        primary: true,
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
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
    // 同名不同编号的来料必须分得清再填数量；颜色与验收单位本表已有独立列。
    MasterColumnDef(
      key: 'goods',
      label: '货品名称',
      width: 200,
      value: (item) => item.goodsName ?? item.goodsCode ?? '—',
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, item) => UtenGoodsIdentityCell(name: item.goodsName),
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: (item) => UtenGoodsAttributeCell.text(item.goodsCode),
      cellBuilder: (_, item) => UtenGoodsAttributeCell(item.goodsCode),
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
      width: 190,
      // 单位后直接带上本行的换算事实（原单 1 箱 = 24 个）：合格/不合格列的 ⓘ
      // 已上表头，逐行不同的倍率必须在正文里看得见，否则会有人把箱数当个数填。
      value: (item) => inspectionQuantityUnitCell(context, item),
    ),
    MasterColumnDef(
      key: 'sourceOrderNo',
      label: '来源订货单',
      width: 160,
      value: (item) => item.sourceOrderNo ?? '—',
    ),
    // 先入库后检(V596)：已上架的行标红给出「仓库 / 库位」，去库位找货检验。
    MasterColumnDef(
      key: 'preStocked',
      label: '储放位置',
      width: 200,
      value: (item) => item.preStocked?.label ?? '待检区',
      cellBuilder: (context, item) {
        final location = item.preStocked;
        if (location == null) return const Text('待检区');
        return Text(
          '已入库 · ${location.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: UtenColors.error,
            fontWeight: FontWeight.w700,
          ),
        );
      },
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
      // 2026-09-11：提示 ⓘ 统一挂表头，行内只留报错（行内 ⓘ 把输入框挤窄）。
      info: inspectionQuantityColumnHint(context, passed: true),
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
            decoration: const UtenInputDecoration(
              InputDecoration(isDense: true),
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
      info: inspectionQuantityColumnHint(context, passed: false),
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

/// 处置页表头信息的一行（一张收货单恰好一行）：供表格按列呈现单据级事实。
class _ReceiptHeaderRow {
  const _ReceiptHeaderRow({
    required this.supplierName,
    required this.billDate,
    required this.lastReceivedAt,
    required this.pending,
  });

  final String supplierName;
  final String billDate;
  final String lastReceivedAt;

  /// 「N 行明细 · 待检量 X」——待检量已按验收单位分组成文案。
  final String pending;
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
