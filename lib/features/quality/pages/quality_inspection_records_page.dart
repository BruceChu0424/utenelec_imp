import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/quality_inspection_record.dart';
import '../repositories/quality_inspection_record_repository.dart';

class QualityInspectionRecordsPage extends ConsumerStatefulWidget {
  const QualityInspectionRecordsPage({super.key, this.initialDomain});

  final QualityInspectionRecordDomain? initialDomain;

  @override
  ConsumerState<QualityInspectionRecordsPage> createState() =>
      _QualityInspectionRecordsPageState();
}

/// 检验结果四态桶（服务端 decision 参数）。
const _decisionFacets = [
  MasterFacetBucket(value: 'PASS', count: 0, label: '合格'),
  MasterFacetBucket(value: 'PARTIAL', count: 0, label: '部分合格'),
  MasterFacetBucket(value: 'FAIL', count: 0, label: '不合格'),
  MasterFacetBucket(value: 'CANCELLED', count: 0, label: '已撤销'),
];

/// 检验类型桶（仅 IQC：PURCHASE 采购来料 / SUBCONTRACT 委外回厂；FQC 恒为生产成品，不出桶）。
const _sourceTypeFacets = [
  MasterFacetBucket(value: 'PURCHASE', count: 0, label: '采购来料'),
  MasterFacetBucket(value: 'SUBCONTRACT', count: 0, label: '委外回厂'),
];

/// 当前效力三档桶：与 effectLabel 展示口径一一对应（当前有效/历史失效/撤销有效）。
const _effectiveFacets = [
  MasterFacetBucket(value: 'ACTIVE', count: 0, label: '当前有效'),
  MasterFacetBucket(value: 'EXPIRED', count: 0, label: '历史失效'),
  MasterFacetBucket(value: 'CANCELLED', count: 0, label: '撤销有效'),
];

/// 不良处置桶（仅 FQC：决定事件三码 + 撤销事件两码；IQC 恒无处置码，不出桶）。
const _dispositionFacets = [
  MasterFacetBucket(value: 'REWORK', count: 0, label: '返工'),
  MasterFacetBucket(value: 'SCRAP', count: 0, label: '报废'),
  MasterFacetBucket(value: 'REJECT', count: 0, label: '拒收/退回'),
  MasterFacetBucket(value: 'SOURCE_REPORT_REVERSED', count: 0, label: '来源报工红冲'),
  MasterFacetBucket(value: 'REGISTRATION_REVERSED', count: 0, label: '送检登记撤回'),
];

class _QualityInspectionRecordsPageState
    extends ConsumerState<QualityInspectionRecordsPage> {
  QualityInspectionRecordPage? _data;
  QualityInspectionRecordDomain? _domain;
  String? _decision;
  String? _sourceType;
  String? _effective;
  String? _disposition;
  String _keyword = '';
  QualityInspectionDateRange? _dateRange;
  bool _loading = true;
  String? _error;
  int _requestVersion = 0;

  // 2026-09-25 单号列统一：来源/关联/检查单号表头排序 + 值筛选（服务端白名单/facets）。
  String? _sortColumn;
  bool _sortAscending = true;
  Map<String, List<MasterFacetBucket>> _docNoFacets = const {};
  String? _sourceNoFilter;
  String? _referenceNoFilter;
  String? _sheetNoFilter;

  @override
  void initState() {
    super.initState();
    _domain = _resolveInitialDomain();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(page: 1));
  }

  List<QualityInspectionRecordDomain> get _allowedDomains {
    final permissions = ref.read(currentPermissionsProvider);
    final superAdmin = ref.read(isSuperAdminProvider);
    return [
      if (superAdmin || permissions.contains(Perm.procurementInspectionView))
        QualityInspectionRecordDomain.iqc,
      if (superAdmin ||
          permissions.contains(Perm.productionQualityInspectionView))
        QualityInspectionRecordDomain.fqc,
    ];
  }

  QualityInspectionRecordDomain? _resolveInitialDomain() {
    final allowed = _allowedDomains;
    if (allowed.isEmpty) return null;
    final requested = widget.initialDomain;
    return requested != null && allowed.contains(requested)
        ? requested
        : allowed.first;
  }

  Future<void> _load({int? page}) async {
    final domain = _domain;
    if (domain == null) return;
    final requestVersion = ++_requestVersion;
    final requestedPage = page ?? _data?.page ?? 1;
    final requestedDecision = _decision;
    final requestedSourceType = _sourceType;
    final requestedEffective = _effective;
    final requestedDisposition = _disposition;
    final requestedKeyword = _keyword;
    final requestedRange = _dateRange;
    // 2026-09-25 单号列统一：单号排序/值筛选（sheetNo 仅 FQC 有列值）。
    final requestedSort = _sortColumn;
    final requestedOrder = _sortColumn == null
        ? null
        : (_sortAscending ? 'asc' : 'desc');
    final requestedSourceNo = _sourceNoFilter;
    final requestedReferenceNo = _referenceNoFilter;
    final requestedSheetNo = domain == QualityInspectionRecordDomain.fqc
        ? _sheetNoFilter
        : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(qualityInspectionRecordRepositoryProvider);
      final result = await repository.list(
        domain: domain,
        decision: requestedDecision,
        keyword: requestedKeyword,
        dateRange: requestedRange,
        sourceType: requestedSourceType,
        effective: requestedEffective,
        disposition: requestedDisposition,
        page: requestedPage,
        sort: requestedSort,
        order: requestedOrder,
        sourceNo: requestedSourceNo,
        referenceNo: requestedReferenceNo,
        sheetNo: requestedSheetNo,
      );
      // 单号 facets 与列表同上下文（不含单号自身筛选）；失败不阻断列表。
      Map<String, List<MasterFacetBucket>> facets = const {};
      try {
        facets = await repository.facets(
          domain: domain,
          decision: requestedDecision,
          keyword: requestedKeyword,
          dateRange: requestedRange,
          sourceType: requestedSourceType,
          effective: requestedEffective,
          disposition: requestedDisposition,
        );
      } catch (_) {
        facets = const {};
      }
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _docNoFacets = facets;
        _data = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '检测记录加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _selectDomain(QualityInspectionRecordDomain domain) async {
    if (_domain == domain) return;
    setState(() {
      _domain = domain;
      _decision = null;
      // 表头筛选与域强相关（IQC 无不良处置、FQC 来源恒为生产），换域一并清空；
      // 单号值筛选/排序同理（IQC 无检查单号列值），一并复位。
      _sourceType = null;
      _effective = null;
      _disposition = null;
      _sortColumn = null;
      _sourceNoFilter = null;
      _referenceNoFilter = null;
      _sheetNoFilter = null;
      _docNoFacets = const {};
      _data = null;
      _error = null;
    });
    await _load(page: 1);
  }

  Future<void> _selectDecision(String? decision) async {
    final normalized = decision?.trim().toUpperCase();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (_decision == next) return;
    setState(() => _decision = next);
    await _load(page: 1);
  }

  /// 表头三列筛选（sourceType/effective/disposition，2026-09-16）：值统一大写，
  /// 空 = 清除；下推后端同名参数并回第 1 页。
  Future<void> _selectColumnFilter(String key, String? value) async {
    final normalized = value?.trim().toUpperCase();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    var changed = false;
    setState(() {
      switch (key) {
        case 'sourceType':
          changed = _sourceType != next;
          _sourceType = next;
        case 'effective':
          changed = _effective != next;
          _effective = next;
        case 'disposition':
          changed = _disposition != next;
          _disposition = next;
      }
    });
    if (changed) await _load(page: 1);
  }

  /// 单号列值筛选（2026-09-25 单号列统一）：单号是文本原值、不转大写，
  /// 空 = 清除；服务端精确匹配并回第 1 页。
  Future<void> _selectDocNoFilter(String key, String? value) async {
    final next = value?.trim();
    final normalized = next == null || next.isEmpty ? null : next;
    var changed = false;
    setState(() {
      switch (key) {
        case 'sourceNo':
          changed = _sourceNoFilter != normalized;
          _sourceNoFilter = normalized;
        case 'referenceNo':
          changed = _referenceNoFilter != normalized;
          _referenceNoFilter = normalized;
        case 'sheetNo':
          changed = _sheetNoFilter != normalized;
          _sheetNoFilter = normalized;
      }
    });
    if (changed) await _load(page: 1);
  }

  Future<void> _applyKeyword(String value) async {
    final normalized = value.trim();
    if (_keyword == normalized) return;
    _keyword = normalized;
    await _load(page: 1);
  }

  Future<void> _pickDateRange() async {
    final today = ChinaDateTime.today();
    final current = _dateRange;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.utc(2020),
      lastDate: today,
      initialDateRange: current == null
          ? null
          : DateTimeRange(start: current.start, end: current.end),
      helpText: '选择检验决定日期范围',
      saveText: '应用',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dateRange = QualityInspectionDateRange(
        start: ChinaDateTime.asWallTime(picked.start),
        end: ChinaDateTime.asWallTime(picked.end),
      );
    });
    await _load(page: 1);
  }

  Future<void> _clearDateRange() async {
    if (_dateRange == null) return;
    setState(() => _dateRange = null);
    await _load(page: 1);
  }

  Future<void> _openDetail(QualityInspectionRecord record) async {
    await showUtenAdaptivePanel<void>(
      context: context,
      drawerWidth: 960,
      compactHeightFactor: 0.95,
      builder: (_) => _QualityInspectionRecordDetailPanel(record: record),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(RouteName.qualityInspectionRecords, _load);
    final allowedDomains = _allowedDomains;
    return Scaffold(
      appBar: UtenAppBar(
        title: '检测记录',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.qualityTaskCenter),
        ),
        actions: [
          UtenAppBarActionButton(
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _loading && _data != null,
            onPressed: _loading || _domain == null
                ? null
                : () => _load(page: 1),
          ),
        ],
      ),
      body: SafeArea(
        child: _domain == null || allowedDomains.isEmpty
            ? const UtenEmpty(
                icon: Icons.lock_outline_rounded,
                message: '您暂无检测记录查看权限',
                description: '请联系品质主管开通来料检验或生产成品质检查看权限。',
              )
            : _loading && _data == null
            ? const UtenSkeletonList()
            : _error != null && _data == null
            ? UtenEmpty.error(
                message: _error,
                description: '已有检验记录都完好保存在系统里，重新加载不会改动它们。',
                actionLabel: '重新加载',
                onAction: () => _load(page: 1),
              )
            : _buildContent(allowedDomains),
      ),
    );
  }

  Widget _buildContent(List<QualityInspectionRecordDomain> allowedDomains) {
    final data =
        _data ??
        const QualityInspectionRecordPage(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 0,
          metrics: [],
        );
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        // 大小屏共用一张表：统一走 MasterDataTableView，窄屏横向滚动（卡片形态已退役）。
        child: Builder(
          builder: (context) {
            // 2026-10-01 用户口径（对齐待检处置/研发任务中心）：删除顶部指标卡
            //（合格/不合格等计数）与筛选行下的常驻说明框，只留筛选 + 表格；
            // 检验结果筛选走表头 decision 桶，错误横幅仅在刷新失败时出现。
            final filters = _buildFilters(allowedDomains);
            final inlineError = _error == null || _data == null
                ? const SizedBox.shrink()
                : _InlineRecordError(message: _error!, onRetry: _load);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 顶部筛选区：大字号下可能超过视口，封顶后自滚，
                // 表格至少保留 160 逻辑像素（空态/行集都能露出来）。
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 640),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        filters,
                        if (_error != null && _data != null) ...[
                          const SizedBox(height: UtenSpacing.s12),
                          inlineError,
                        ],
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                    ),
                  ),
                ),
                Expanded(child: _buildTable(data)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildFilters(List<QualityInspectionRecordDomain> allowedDomains) {
    // 全平台统一筛选工具条：检验域分段 + 胶囊搜索框（尾挂总数文案）；
    // 决定日期筛选保留在工具条下一行。
    final theme = Theme.of(context);
    final range = _dateRange;
    final dateLabel = range == null
        ? '决定日期'
        : '${ChinaDateTime.formatDate(range.start)} 至 '
              '${ChinaDateTime.formatDate(range.end)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFilterToolbar<QualityInspectionRecordDomain>(
          segmentsKey: const Key('quality-inspection-record-domain-filter'),
          searchKey: const Key('quality-inspection-record-search'),
          segments: [
            for (final domain in allowedDomains)
              UtenFilterSegment(value: domain, label: domain.label),
          ],
          selected: {_domain!},
          onSelectionChanged: _selectDomain,
          searchHint: '搜索来源单号 / 计划 / 货品 / 供应商 / 检验员',
          initialSearchValue: _keyword,
          onSearchChanged: _applyKeyword,
          trailing: Text(
            '共 ${_data?.total ?? 0} 条 · 双击查看完整证据',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: OutlinedButton.icon(
                key: const Key('quality-inspection-record-date-filter'),
                onPressed: _pickDateRange,
                icon: const Icon(Icons.date_range_outlined),
                label: Text(dateLabel),
              ),
            ),
            if (range != null)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: TextButton.icon(
                  onPressed: _clearDateRange,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('清除日期'),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTable(
    QualityInspectionRecordPage data,
  ) => MasterDataTableView<QualityInspectionRecord>(
    tableKey:
        'features.quality.pages.quality_inspection_records_page.QualityInspectionRecordsPageState._buildTable.1',
    key: const Key('quality-inspection-record-table'),
    // 2026-09-29「大小屏共用一张表」：<840（原卡片阈值）切内建卡片形态。
    columns: _columns,
    items: data.items,
    // 表头筛选固定枚举桶（2026-09-16，count=0 表示不强调计数）：
    // 检验结果四态；检验类型仅 IQC（PURCHASE/SUBCONTRACT，FQC 恒为生产成品）；
    // 当前效力三档（与 effectLabel 展示口径一致）；不良处置仅 FQC（IQC 恒无处置码）。
    facets: {
      'decision': _decisionFacets,
      if (_domain == QualityInspectionRecordDomain.iqc)
        'sourceType': _sourceTypeFacets,
      'effective': _effectiveFacets,
      if (_domain == QualityInspectionRecordDomain.fqc)
        'disposition': _dispositionFacets,
      // 2026-09-25 单号列统一：单号值来自服务端 facets（与列表同一过滤上下文）。
      'sourceNo': _docNoFacets['sourceNo'] ?? const [],
      'referenceNo': _docNoFacets['referenceNo'] ?? const [],
      'sheetNo': _docNoFacets['sheetNo'] ?? const [],
    },
    nullCounts: const {},
    filters: {
      'decision': _decision,
      'sourceType': _sourceType,
      'effective': _effective,
      'disposition': _disposition,
      'sourceNo': _sourceNoFilter,
      'referenceNo': _referenceNoFilter,
      'sheetNo': _sheetNoFilter,
    },
    onFilterChanged: (key, value) async {
      if (key == 'decision') {
        await _selectDecision(value);
      } else if (key == 'sourceNo' ||
          key == 'referenceNo' ||
          key == 'sheetNo') {
        await _selectDocNoFilter(key, value);
      } else {
        await _selectColumnFilter(key, value);
      }
    },
    // 2026-09-25 单号列统一：表头排序走服务端白名单
    //（sourceNo/referenceNo/sheetNo）。
    sortColumn: _sortColumn,
    sortAscending: _sortAscending,
    onSortChange: (column, ascending) {
      setState(() {
        _sortColumn = column;
        _sortAscending = ascending;
      });
      _load(page: 1);
    },
    idOf: (record) => record.recordId,
    onRowTap: _openDetail,
    rowMenuBuilder: (record) => [
      UtenMenuItem(
        label: '查看检测记录详情',
        icon: Icons.visibility_outlined,
        onTap: () => _openDetail(record),
      ),
    ],
    isLoading: _loading,
    loadingMore: _loading && _data != null,
    error: _data == null ? _error : null,
    onRetry: () => _load(page: data.page),
    emptyMessage: '当前筛选下没有检测记录',
    currentPage: data.page,
    totalPages: data.totalPages,
    paginationScope: (
      _domain,
      _decision,
      _sourceType,
      _effective,
      _disposition,
      _keyword,
      _dateRange?.start,
      _dateRange?.end,
    ),
    onPageChange: (page) => _load(page: page),
  );

  List<MasterColumnDef<QualityInspectionRecord>> get _columns => [
    MasterColumnDef(
      key: 'decision',
      label: '检验结果',
      width: 72,
      value: (record) => record.decisionLabel,
      // 2026-09-27 用户口径「表格状态列整格底色」；ADR-169 重定：合格=绿 /
      // 部分合格=橙（风险中间态，2026-10-08 用户锚定「部分合格=橙」）/
      // 不合格=红 / 已撤销=中性灰。
      cellColor: (context, record) =>
          utenStatusBadgeCellColor(switch (record.decision) {
            'PASS' => UtenStatusBadgeType.success,
            'PARTIAL' => UtenStatusBadgeType.orange,
            'FAIL' => UtenStatusBadgeType.danger,
            _ => UtenStatusBadgeType.neutral,
          }),
    ),
    MasterColumnDef(
      key: 'effective',
      label: '当前效力',
      width: 105,
      value: (record) => record.effectLabel,
    ),
    MasterColumnDef(
      key: 'sourceType',
      label: '检验类型',
      width: 120,
      value: (record) => record.sourceTypeLabel,
    ),
    MasterColumnDef(
      key: 'sourceNo',
      label: '来源单号',
      width: 180,
      // 2026-09-25 单号列统一：可排序（服务端白名单）+ 值筛选（facets）。
      sortable: true,
      value: (record) => _text(record.sourceNo),
    ),
    MasterColumnDef(
      key: 'referenceNo',
      label: '关联单号',
      width: 180,
      sortable: true,
      value: (record) => _text(record.referenceNo),
    ),
    MasterColumnDef(
      key: 'sheetNo',
      label: '检查单号',
      width: 170,
      // 检查单号仅 FQC 有列值（IQC 行恒空），排序也只在 FQC 域开放。
      sortable: _domain == QualityInspectionRecordDomain.fqc,
      value: (record) => _text(record.sheetNo),
    ),
    MasterColumnDef(
      key: 'partnerName',
      label: '供应商',
      width: 180,
      value: (record) => _text(record.partnerName),
    ),
    // 2026-09-14 全站列序统一：名称 → 编号 → 颜色。
    MasterColumnDef(
      key: 'goodsName',
      label: '货品名称',
      width: 240,
      value: (record) => _text(record.goodsName),
      // 卡片形态标题列。
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '编号',
      width: 140,
      value: (record) => _text(record.goodsCode),
      // 卡片副行已带编号，明细区不重复出。
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 110,
      value: (record) => _text(record.colorName),
    ),
    MasterColumnDef(
      key: 'passQty',
      label: '本次合格',
      width: 110,
      type: 'number',
      value: (record) => _qty(record.passQty),
    ),
    MasterColumnDef(
      key: 'failQty',
      label: '本次不合格',
      width: 120,
      type: 'number',
      value: (record) => _qty(record.failQty),
    ),
    MasterColumnDef(
      key: 'disposition',
      label: '不良处置',
      width: 120,
      value: (record) => record.dispositionLabel,
    ),
    MasterColumnDef(
      key: 'inspectorName',
      label: '检验员',
      width: 120,
      value: (record) => _text(record.inspectorName),
    ),
    MasterColumnDef(
      key: 'decidedAt',
      label: '决定时间',
      width: 170,
      value: (record) => ChinaDateTime.formatInstant(record.decidedAt),
    ),
  ];
}

class _QualityInspectionRecordDetailPanel extends ConsumerStatefulWidget {
  const _QualityInspectionRecordDetailPanel({required this.record});

  final QualityInspectionRecord record;

  @override
  ConsumerState<_QualityInspectionRecordDetailPanel> createState() =>
      _QualityInspectionRecordDetailPanelState();
}

class _QualityInspectionRecordDetailPanelState
    extends ConsumerState<_QualityInspectionRecordDetailPanel> {
  QualityInspectionRecord? _record;
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
      final record = await ref
          .read(qualityInspectionRecordRepositoryProvider)
          .detail(
            domain: widget.record.domain,
            recordId: widget.record.recordId,
          );
      if (!mounted) return;
      setState(() {
        _record = record;
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
        _error = '检测记录详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: ValueKey('quality-inspection-record-${widget.record.recordId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '检测记录详情',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              UtenAppBarActionButton(
                label: '关闭',
                icon: Icons.close_rounded,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _error != null
              ? UtenEmpty.error(
                  message: _error,
                  actionLabel: '重新加载',
                  onAction: _load,
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: _buildDetail(_record!),
                ),
        ),
      ],
    );
  }

  Widget _buildDetail(QualityInspectionRecord record) {
    final theme = Theme.of(context);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: record.effective
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: UtenRadius.mdAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                UtenStatusBadge(
                  label: record.decisionLabel,
                  type: _decisionBadgeType(record.decision),
                  icon: _decisionIcon(record.decision),
                  size: UtenStatusBadgeSize.large,
                ),
                UtenStatusBadge(
                  label: record.effectLabel,
                  type: record.effective
                      ? UtenStatusBadgeType.info
                      : UtenStatusBadgeType.neutral,
                ),
                Text(
                  '${record.domain.label} · ${record.sourceTypeLabel}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (!record.effective) ...[
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '该决定是不可变历史证据，但来源已红冲/取消，不代表当前可用库存或当前成品放行。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s16),
          _DetailSection(
            title: '来源与货品',
            child: _DetailFieldTable(
              tableKey: const Key('quality-inspection-record-detail-source'),
              fields: [
                _DetailField('来源单号', _text(record.sourceNo)),
                _DetailField('来源日期', _date(record.sourceDate)),
                _DetailField('关联单号', _text(record.referenceNo)),
                _DetailField('供应商', _text(record.partnerName)),
                _DetailField('仓库', _text(record.warehouseName)),
                _DetailField(
                  '货品',
                  [
                    record.goodsCode,
                    record.goodsName,
                  ].whereType<String>().join(' '),
                ),
                _DetailField('颜色', _text(record.colorName)),
                _DetailField('单位', _text(record.unitName)),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          _DetailSection(
            title: '本次决定与当前状态',
            child: _DetailFieldTable(
              tableKey: const Key('quality-inspection-record-detail-decision'),
              fields: [
                _DetailField('检验结果', record.decisionLabel),
                _DetailField('不良处置', record.dispositionLabel),
                _DetailField('原因', _text(record.reason)),
                _DetailField(
                  '检验员',
                  _text(record.inspectorName, fallback: '系统'),
                ),
                _DetailField(
                  '决定时间',
                  ChinaDateTime.formatInstant(record.decidedAt),
                ),
                _DetailField('当前状态', record.currentStatusLabel),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          _DetailSection(title: '检验数量', child: _buildQuantityTable(record)),
          const SizedBox(height: UtenSpacing.s16),
          _DetailSection(
            title: '追溯标识',
            child: _DetailFieldTable(
              tableKey: const Key('quality-inspection-record-detail-trace'),
              fields: [
                _DetailField('记录 UUID', record.recordId),
                _DetailField('检验 UUID', record.inspectionId),
                _DetailField('来源 UUID', _text(record.sourceId)),
                _DetailField('来源行 UUID', _text(record.sourceItemId)),
                _DetailField('供应商 UUID', _text(record.partnerId)),
                _DetailField('仓库 UUID', _text(record.warehouseId)),
                _DetailField('货品 UUID', _text(record.goodsId)),
                _DetailField('颜色 UUID', _text(record.colorId)),
                _DetailField('单位 UUID', _text(record.unitId)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 检验数量表：一行一个口径，「本次决定」与「当前累计」分列对照。
  ///
  /// 合计条只加「本次合格 + 本次不合格」——同一单位、同一笔决定，相加才是这次
  /// 判定掉的总量；当前累计列是同一批量的口径快照（送检 = 累计合格 + 累计不合格
  /// + 剩余待检），纵向求和等于把同一批货重复计数，故不做列合计。
  Widget _buildQuantityTable(QualityInspectionRecord record) {
    final unit = _text(record.unitName);
    final decidedQty = _qty(record.passQty + record.failQty);
    return MasterDataTableView<_DetailQuantityRow>(
      tableKey:
          'features.quality.pages.quality_inspection_records_page.QualityInspectionRecordDetailPanelState._buildQuantityTable.1',
      key: const Key('quality-inspection-record-detail-quantity'),
      embedded: true,
      showColumnChooser: false,
      columns: [
        MasterColumnDef(
          key: 'item',
          label: '检测项',
          width: 110,
          value: (row) => row.item,
        ),
        MasterColumnDef(
          key: 'current',
          label: '本次决定',
          width: 110,
          type: 'number',
          value: (row) => row.current == null ? '—' : _qty(row.current!),
          exactValueOf: (row) => row.current?.toString(),
        ),
        MasterColumnDef(
          key: 'cumulative',
          label: '当前累计',
          width: 110,
          type: 'number',
          value: (row) => _qty(row.cumulative),
          exactValueOf: (row) => row.cumulative.toString(),
        ),
        MasterColumnDef(
          key: 'unit',
          label: '单位',
          width: 80,
          value: (row) => row.unit,
        ),
      ],
      items: [
        _DetailQuantityRow(
          item: '合格',
          current: record.passQty,
          cumulative: record.currentPassedQty,
          unit: unit,
        ),
        _DetailQuantityRow(
          item: '不合格',
          current: record.failQty,
          cumulative: record.currentFailedQty,
          unit: unit,
        ),
        // 送检量与剩余待检是批量级事实，不随单笔决定变化，故本次列留空占位。
        _DetailQuantityRow(
          item: '送检',
          current: null,
          cumulative: record.inspectedQty,
          unit: unit,
        ),
        _DetailQuantityRow(
          item: '剩余待检',
          current: null,
          cumulative: record.currentRemainingQty,
          unit: unit,
        ),
      ],
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      summaryBar: UtenTotalsSummaryBar(
        density: true,
        compact: true,
        entries: [
          UtenTotalEntry(
            '本次判定合计',
            unit == '—' ? decidedQty : '$decidedQty $unit',
          ),
        ],
      ),
    );
  }
}

/// 详情分区外壳：标题 + 一张内嵌表格。弹层里的明细一律走全站同款
/// MasterDataTableView，不再用 Row 逐项罗列。
class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: UtenSpacing.s8),
        child,
      ],
    ),
  );
}

/// 详情里的一条「项目 / 内容」事实（表格的一行）。
class _DetailField {
  const _DetailField(this.label, this.value);

  final String label;
  final String value;
}

/// 「项目 / 内容」两列内嵌表。
///
/// 弹层是无界高度场景，故 embedded（按内容收缩、无翻页条、默认不出全屏按钮）；
/// 只读展示不传 selectable，表格自带的文字框选保留复制能力（UUID 要能选中复制）。
class _DetailFieldTable extends StatelessWidget {
  const _DetailFieldTable({required this.tableKey, required this.fields});

  final Key tableKey;
  final List<_DetailField> fields;

  @override
  Widget build(BuildContext context) => MasterDataTableView<_DetailField>(
    tableKey:
        'features.quality.pages.quality_inspection_records_page.DetailFieldTable.build.1',
    key: tableKey,
    embedded: true,
    showColumnChooser: false,
    columns: [
      MasterColumnDef(
        key: 'label',
        label: '项目',
        width: 120,
        value: (field) => field.label,
      ),
      MasterColumnDef(
        key: 'value',
        label: '内容',
        width: 320,
        value: (field) => field.value.isEmpty ? '—' : field.value,
      ),
    ],
    items: fields,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
  );
}

/// 检验数量表的一行：同一口径的「本次决定」与「当前累计」两个数并排。
class _DetailQuantityRow {
  const _DetailQuantityRow({
    required this.item,
    required this.current,
    required this.cumulative,
    required this.unit,
  });

  final String item;
  final double? current;
  final double cumulative;
  final String unit;
}

class _InlineRecordError extends StatelessWidget {
  const _InlineRecordError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '刷新失败：$message；当前仍显示上次成功结果。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

IconData _decisionIcon(String decision) => switch (decision) {
  'PASS' => Icons.check_rounded,
  'PARTIAL' => Icons.rule_rounded,
  'FAIL' => Icons.close_rounded,
  'CANCELLED' => Icons.history_rounded,
  _ => Icons.fact_check_outlined,
};

UtenStatusBadgeType _decisionBadgeType(String decision) => switch (decision) {
  'PASS' => UtenStatusBadgeType.success,
  'PARTIAL' => UtenStatusBadgeType.orange,
  'FAIL' => UtenStatusBadgeType.danger,
  'CANCELLED' => UtenStatusBadgeType.neutral,
  _ => UtenStatusBadgeType.info,
};

String _qty(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

String _text(String? value, {String fallback = '—'}) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? fallback : normalized;
}

String _date(DateTime? value) =>
    value == null ? '—' : ChinaDateTime.formatDate(value);
