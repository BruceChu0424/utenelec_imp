import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
import '../../../shared/providers/master_party_options.dart';
// 应收应付台账页（只读查询，ar_ap_ledger:view）。
//
// direction(AR/AP) + settled(全部/未清/已清) 双向过滤 + 关键词 + 日期范围。
// 列表展示：单据号/来源单号/方向/往来方/到期日/结账方式/金额/备注/状态。
// 名称解析：AR→客户 / AP→供应商（FinanceNameService）。往来方显示用 partyId + direction。
import 'dart:async';
import 'package:collection/collection.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/inputs/uten_multi_value_cell.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/master_server_column_filters.dart';
import '../models/finance_doc.dart';
import '../models/finance_legacy_balance.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/finance_table_facets.dart';

const Map<int, String> financeArApSettlementStyleLabels = {
  1: '现金',
  2: '提货',
  3: '代付',
  4: '支票',
  6: '月结',
  7: '垫付',
  8: '汇款',
  10: '代收',
};

String financeArApSettlementStyleLabel(int? code) =>
    financeArApSettlementStyleLabels[code] ?? '未设置';

String _arApRateText(String? value) {
  final exact = financeExactDecimal(value);
  if (exact == null) return '—';
  final parts = exact.split('.');
  return '${parts.first}.${(parts.length == 1 ? '' : parts[1]).padRight(6, '0')}';
}

class FinanceArApPage extends ConsumerStatefulWidget {
  const FinanceArApPage({super.key});

  @override
  ConsumerState<FinanceArApPage> createState() => _FinanceArApPageState();
}

class _FinanceArApPageState extends ConsumerState<FinanceArApPage>
    with ScopedPagedReadViewMixin<FinanceArApPage> {
  PagedResult<ArApLedgerItem>? _page;
  int _pageNum = 1;
  final _tableRows = MasterDataTableRowsController<ArApLedgerItem>();
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();
  String _keyword = '';
  // 方向决定应收/应付用语与往来方字典；清结状态只在表头筛选。
  String? _direction; // null=全部 / AR / AP
  bool _directionSelected = false;
  String? _sourceDocType;
  String? _partyId;
  String? _currencyId; // 币别表头筛选（currencies/dict 桶 value=字典 id）
  bool? _settled; // null=全部 / false=未清 / true=已清
  // 列排序 + 2026-09-25 单号列统一（单据号/来源单号/关联销售单号表头值筛选 +
  // 服务端桶 + 防串台代数）：共享状态见 MasterServerColumnFilters；
  // 排序 null = 不排序（走后端默认 billDate DESC）。
  final _columnFilters = MasterServerColumnFilters();
  Map<String, dynamic>? _activeQuery;
  int _criteriaRevision = 0;
  static const _originalAmountColumns = {
    'amountOriginal',
    'amountReceivedOriginal',
    'amountWriteOffOriginal',
    'amountBalanceOriginal',
    'prepaymentAppliedOriginal',
  };

  @override
  void initState() {
    super.initState();
    listenReadOwner(ref, () {
      _loadRequests.begin();
      _columnFilters.reset();
      _activeQuery = null;
      _criteriaRevision++;
      _tableRows.update(const []);
      setState(() {
        _page = null;
        _loading = false;
        _error = null;
        _partyId = null;
        _currencyId = null;
        _keyword = '';
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(financeNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  /// 当前筛选组装（_load 与单号桶共用；单号列自身的筛选值不进桶拉取）。
  ArApFilter _arApFilter({bool withDocNoFilters = true}) => ArApFilter(
    keyword: _keyword.trim().isEmpty ? null : _keyword,
    direction: _direction,
    sourceDocType: _sourceDocType,
    partyId: _partyId,
    currencyId: _currencyId,
    settled: _settled,
    billNo: withDocNoFilters ? _columnFilters['billNo'] : null,
    sourceDocNo: withDocNoFilters ? _columnFilters['sourceDocNo'] : null,
    salesOrderNos: withDocNoFilters ? _columnFilters['salesOrderNos'] : null,
    columnQuery: Map.unmodifiable(_columnFilters.values),
  );

  @override
  void scopedPagedReadOwnerChanged() {
    _loadRequests.begin();
    _columnFilters.reset();
    _activeQuery = null;
    _criteriaRevision++;
    _tableRows.update(const []);
    if (!mounted) return;
    setState(() {
      _page = null;
      _loading = false;
      _error = scopedPagedReadRejection?.message;
    });
  }

  Map<String, dynamic> get _cacheQuery => {
    'repository': ref.read(arApLedgerRepositoryProvider),
    'keyword': _keyword,
    'direction': _direction,
    'sourceDocType': _sourceDocType,
    'partyId': _partyId,
    'currencyId': _currencyId,
    'settled': _settled,
    'columns': Map.of(_columnFilters.values),
    'sort': _columnFilters.sortColumn,
    'ascending': _columnFilters.sortAscending,
  };

  Future<void> _navigatePage(int page) => _load(page, useCache: true);

  Future<void> _load(int page, {bool useCache = false}) async {
    final cacheQuery = _cacheQuery;
    final repo = ref.read(arApLedgerRepositoryProvider);
    final filter = _arApFilter();
    final sort = _columnFilters.sortColumn;
    final order = sort == null
        ? null
        : (_columnFilters.sortAscending ? 'asc' : 'desc');

    final generation = _loadRequests.begin();
    setState(() {
      if (!const DeepCollectionEquality().equals(_activeQuery, cacheQuery)) {
        _activeQuery = cacheQuery;
        _criteriaRevision++;
        _page = null;
        _tableRows.update(const []);
      }
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    // 单号桶随列表口径重取（2026-09-25 单号列统一）。
    unawaited(_loadDocNoFacets());
    try {
      final r = await readScopedPage<ArApLedgerItem>(
        page,
        query: cacheQuery,
        currentQuery: () => _cacheQuery,
        useCache: useCache,
        fetchPage: (target) =>
            repo.list(page: target, filter: filter, sort: sort, order: order),
      );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      unawaited(
        ref
            .read(financeNameServiceProvider)
            .loadPartyNames(
              clientIds: partyReferenceIds([
                ...r.items.map((item) => item.clientId),
                if (_direction != 'AP') _partyId,
              ]),
              supplierIds: partyReferenceIds([
                ...r.items.map((item) => item.supplierId),
                if (_direction != 'AR') _partyId,
              ]),
            ),
      );
      setState(() {
        _page = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载台账失败';
        _loading = false;
      });
    }
  }

  /// 单号桶（单据号/来源单号）随过滤上下文重取（失败静默保持旧桶）。
  Future<void> _loadDocNoFacets() => _columnFilters.loadFacets(
    () => ref.read(arApLedgerRepositoryProvider).facets(filter: _arApFilter()),
    onLoaded: () {
      if (mounted) setState(() {});
    },
    isCurrent: captureReadOwner(ref),
  );

  List<MasterColumnDef<ArApLedgerItem>> _columns(FinanceNameService names) {
    String directionLabel({
      required String ar,
      required String ap,
      required String mixed,
    }) => switch (_direction) {
      'AR' => ar,
      'AP' => ap,
      _ => mixed,
    };

    String dateLabel(String? value) {
      if (value == null || value.isEmpty) return '—';
      return value.length <= 10 ? value : value.substring(0, 10);
    }

    String partyLabel(ArApLedgerItem it) {
      if (it.direction == 'AR') {
        return it.clientName ?? names.client(it.clientId);
      }
      if (it.direction == 'AP') {
        return it.supplierName ?? names.supplier(it.supplierId);
      }
      return '—';
    }

    return <MasterColumnDef<ArApLedgerItem>>[
      MasterColumnDef(
        // 2026-09-25 单号列统一：可排序 + 表头值筛选（服务端 billNo 白名单/桶）。
        key: 'billNo',
        sortable: true,
        label: '单据号',
        width: 150,
        value: (it) => it.billNo,
      ),
      MasterColumnDef(
        key: 'direction',
        columnSearchEnabled: false,
        facetSearchEnabled: true,
        label: '方向',
        width: 80,
        value: (it) =>
            it.direction == 'AR' ? '应收' : (it.direction == 'AP' ? '应付' : '—'),
      ),
      MasterColumnDef(
        key: 'sourceDocType',
        columnSearchEnabled: false,
        facetSearchEnabled: true,
        label: '来源类型',
        width: 120,
        value: (it) => financeArApSourceTypeLabel(it.sourceDocType),
      ),
      MasterColumnDef(
        key: 'openItemKind',
        columnSearchEnabled: false,
        facetSearchEnabled: true,
        label: '往来项目',
        width: 110,
        value: (it) => financeArApOpenItemKindLabel(it.openItemKind),
      ),
      MasterColumnDef(
        key: 'legacySourceResolution',
        columnSearchEnabled: true,
        facetSearchEnabled: true,
        label: '历史原单匹配',
        width: 190,
        value: (it) =>
            financeLegacySourceResolutionLabel(it.legacySourceResolutionStatus),
      ),
      if (_direction != 'AP')
        MasterColumnDef(
          // 2026-09-25 单号列统一：关联销售单号表头值筛选（聚合列，服务端 EXISTS 精确匹配）。
          key: 'salesOrderNos',
          columnSearchEnabled: true,
          info: '查找完整销售单来源组；命中后保留该台账全部来源，不截成单个匹配项',
          label: '销售订单号',
          width: 190,
          // value（筛选/导出）保留全量；屏幕格走多值截断+弹窗口径（2026-10-29）。
          value: (it) =>
              it.salesOrderNos.isEmpty ? '—' : it.salesOrderNos.join('、'),
          cellBuilder: (context, it) =>
              UtenMultiValueCell(values: it.salesOrderNos, title: '销售订单号'),
        ),
      MasterColumnDef(
        // 2026-09-25 单号列统一：可排序 + 表头值筛选（服务端 sourceDocNo 白名单/桶）。
        key: 'sourceDocNo',
        sortable: true,
        label: '来源单号',
        width: 160,
        value: (it) => it.sourceDocNo,
      ),
      MasterColumnDef(
        key: 'party',
        columnSearchEnabled: true,
        facetSearchEnabled: true,
        label: directionLabel(ar: '客户', ap: '供应商', mixed: '往来方'),
        width: 200,
        value: partyLabel,
      ),
      MasterColumnDef(
        key: 'billDate',
        label: '立帐日',
        width: 120,
        type: 'date',
        sortable: true,
        columnSearchEnabled: true,
        value: (it) => dateLabel(it.billDate),
      ),
      MasterColumnDef(
        key: 'dueDate',
        columnSearchEnabled: true,
        sortable: true,
        label: '到期日',
        width: 120,
        type: 'date',
        value: (it) => dateLabel(it.dueDate),
      ),
      MasterColumnDef(
        key: 'settlementStyleLegacy',
        columnSearchEnabled: true,
        facetSearchEnabled: true,
        label: '结账方式',
        width: 100,
        value: (it) =>
            it.settlementStyleLabel ??
            financeArApSettlementStyleLabel(it.settlementStyleLegacy),
      ),
      MasterColumnDef(
        key: 'currency',
        columnSearchEnabled: false,
        facetSearchEnabled: true,
        label: '币别',
        width: 90,
        value: (it) =>
            financeCurrencyDisplayLabel(
              name: it.currencyName,
              code: it.currencyCode,
            ) ??
            '—',
      ),
      MasterColumnDef(
        key: 'exchangeRate',
        columnSearchEnabled: true,
        sortable: true,
        exactValueOf: (it) =>
            it.exchangeRateText ?? financeDecimalText(it.exchangeRate),
        info: '按该笔立账时保存的原始汇率检索；汇率不合计',
        label: '立账汇率',
        width: 100,
        type: 'number',
        value: (it) => _arApRateText(
          it.exchangeRateText ?? financeDecimalText(it.exchangeRate),
        ),
      ),
      // 金额「数值 币种」后缀（2026-10-10 口径）：原币列随行 currencyName/Code，
      // 人民币列恒「元」；行缺币种或金额非数字（—/***)时不拼单位。
      MasterColumnDef(
        key: 'amountOriginal',
        columnSearchEnabled: _currencyId != null,
        sortable: _currencyId != null,
        exactValueOf: (it) =>
            it.amountOriginalText ?? financeDecimalText(it.amountOriginal),
        info: '先选择币种，再按原币原始金额检索或排序；未知金额不作零',
        label: directionLabel(ar: '应收款金额', ap: '应付款金额', mixed: '立账金额'),
        width: 160,
        type: 'money',
        value: (it) => financeMoneyWithUnitSuffix(
          it.amountOriginalText ?? financeDecimalText(it.amountOriginal),
          currencyName: it.currencyName,
          currencyCode: it.currencyCode,
        ),
      ),
      MasterColumnDef(
        key: 'amountReceivedOriginal',
        columnSearchEnabled: _currencyId != null,
        sortable: _currencyId != null,
        exactValueOf: (it) =>
            it.amountReceivedOriginalText ??
            financeDecimalText(it.amountReceivedOriginal),
        info: '原币金额检索及排序需先选择币种',
        label: directionLabel(ar: '已收款金额', ap: '已付款金额', mixed: '已结算金额'),
        width: 160,
        type: 'money',
        value: (it) => financeMoneyWithUnitSuffix(
          it.amountReceivedOriginalText ??
              financeDecimalText(it.amountReceivedOriginal),
          currencyName: it.currencyName,
          currencyCode: it.currencyCode,
        ),
      ),
      MasterColumnDef(
        key: 'amountWriteOffOriginal',
        columnSearchEnabled: _currencyId != null,
        sortable: _currencyId != null,
        exactValueOf: (it) =>
            it.amountWriteOffOriginalText ??
            financeDecimalText(it.amountWriteOffOriginal),
        info: '原币金额检索及排序需先选择币种',
        label: '冲销金额',
        width: 150,
        type: 'money',
        value: (it) => financeMoneyWithUnitSuffix(
          it.amountWriteOffOriginalText ??
              financeDecimalText(it.amountWriteOffOriginal),
          currencyName: it.currencyName,
          currencyCode: it.currencyCode,
        ),
      ),
      if (_direction != 'AP')
        MasterColumnDef(
          key: 'prepaymentAppliedOriginal',
          columnSearchEnabled: _currencyId != null,
          sortable: _currencyId != null && _direction == 'AR',
          exactValueOf: (it) =>
              it.direction == 'AR' ? it.prepaymentAppliedOriginal : null,
          info: '应收台账的已抵原币金额；需先选择币种，不将供应商抵销当成客户预收',
          label: '预收已抵',
          width: 150,
          type: 'money',
          value: (it) => it.direction != 'AR'
              ? '—'
              : financeMoneyWithUnitSuffix(
                  it.prepaymentAppliedOriginal,
                  currencyName: it.currencyName,
                  currencyCode: it.currencyCode,
                ),
        ),
      MasterColumnDef(
        key: 'amountBalanceOriginal',
        columnSearchEnabled: _currencyId != null,
        sortable: _currencyId != null,
        exactValueOf: (it) =>
            it.amountBalanceOriginalText ??
            financeDecimalText(it.amountBalanceOriginal),
        info: '按原币当前未结金额检索，先选择币种；不按可见页重新累计余额',
        label: directionLabel(ar: '未收金额', ap: '未付金额', mixed: '未结金额'),
        width: 160,
        type: 'money',
        value: (it) => financeMoneyWithUnitSuffix(
          it.amountBalanceOriginalText ??
              financeDecimalText(it.amountBalanceOriginal),
          currencyName: it.currencyName,
          currencyCode: it.currencyCode,
        ),
      ),
      MasterColumnDef(
        key: 'amountBalance',
        columnSearchEnabled: true,
        exactValueOf: (it) =>
            it.amountBalanceText ?? financeDecimalText(it.amountBalance),
        info: '本币未结金额，保留账面原始精度，不按可见页求和',
        label: directionLabel(ar: '未收人民币', ap: '未付人民币', mixed: '未结人民币'),
        width: 160,
        type: 'money',
        sortable: true,
        value: (it) => financeLocalMoneyWithUnitSuffix(
          it.amountBalanceText ?? financeDecimalText(it.amountBalance),
        ),
      ),
      MasterColumnDef(
        key: 'settled',
        columnSearchEnabled: false,
        facetSearchEnabled: true,
        label: '状态',
        width: 120,
        value: (it) {
          final direction = it.direction == 'AR'
              ? '应收'
              : it.direction == 'AP'
              ? '应付'
              : '往来';
          return '$direction${it.settled ? '已清' : '未清'}';
        },
        cellColor: (context, it) => utenStatusBadgeCellColor(
          it.settled
              ? UtenStatusBadgeType.success
              : UtenStatusBadgeType.warning,
        ),
      ),
      MasterColumnDef(
        key: 'remark',
        label: '备注',
        width: 180,
        value: (it) => it.remark,
      ),
    ];
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _columnFilters.handleSortChanged(column, ascending, onChanged: _refilter);
  }

  void _onColumnFilterChanged(String key, String? value) {
    // 2026-09-25 单号列统一：单号类表头值筛选（清空回 null=不过滤）走共享状态。
    if (key == 'billNo' ||
        key == 'sourceDocNo' ||
        key == 'salesOrderNos' ||
        key.startsWith('search.') ||
        const {
          'openItemKind',
          'legacySourceResolution',
          'settlementStyleLegacy',
        }.contains(key)) {
      _columnFilters.handleFilterChanged(key, value, onChanged: _refilter);
      return;
    }
    setState(() {
      switch (key) {
        case 'direction':
          _direction = value;
          _directionSelected = true;
          _partyId = null;
          _clearInapplicableColumns();
          break;
        case 'sourceDocType':
          _sourceDocType = value;
          break;
        case 'party':
          _partyId = value;
          break;
        case 'currency':
          _currencyId = value;
          if (value == null) {
            for (final column in _originalAmountColumns) {
              _columnFilters.setValue('search.$column', null);
            }
            if (_originalAmountColumns.contains(_columnFilters.sortColumn)) {
              _columnFilters.sortColumn = null;
              _columnFilters.sortAscending = true;
            }
          }
          break;
        case 'settled':
          _settled = value == null ? null : value == 'true';
          break;
      }
    });
    _load(1);
  }

  /// 服务端列筛选/排序落地后：setState 刷新表头 + 重拉回第 1 页。
  void _refilter() {
    if (mounted) setState(() {});
    _load(1);
  }

  void _clearInapplicableColumns() {
    if (_direction == 'AP') {
      for (final key in const [
        'salesOrderNos',
        'search.salesOrderNos',
        'search.prepaymentAppliedOriginal',
      ]) {
        _columnFilters.setValue(key, null);
      }
      if (_columnFilters.sortColumn == 'prepaymentAppliedOriginal') {
        _columnFilters.sortColumn = null;
        _columnFilters.sortAscending = true;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = ref.watch(financeNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '应收应付台账',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          UtenRefreshButton(
            busy: _loading,
            // 刷新当前可见页，同时更新字典。
            onRefresh: () async {
              await Future.wait([
                ref.read(financeNameServiceProvider).ensureLoaded(),
                _load(_tableRows.visiblePage ?? _pageNum),
              ]);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            // 方向保留为主业务视图，清结状态由彩色状态列与表头承接。
            child: UtenCollapsingHeaderScrollView(
              collapsingHeader: Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                child: UtenFilterToolbar<String?>(
                  compactBreakpoint: UtenBreakpoints.mediumStart,
                  segments: const [
                    UtenFilterSegment<String?>(value: null, label: '全部'),
                    UtenFilterSegment<String?>(value: 'AR', label: '应收'),
                    UtenFilterSegment<String?>(value: 'AP', label: '应付'),
                  ],
                  selected: _directionSelected ? {_direction} : const {},
                  onSelectionChanged: (value) {
                    setState(() {
                      _direction = value;
                      _directionSelected = true;
                      _partyId = null;
                      _clearInapplicableColumns();
                    });
                    _load(1);
                  },
                  searchHint: '搜索单据号 / 来源单号',
                  initialSearchValue: _keyword,
                  onSearchChanged: (value) {
                    setState(() => _keyword = value);
                    _load(1);
                  },
                  onSearchSubmitted: (value) {
                    setState(() => _keyword = value);
                    _load(1);
                  },
                ),
              ),
              body: MasterDataTableView<ArApLedgerItem>(
                rowsController: _tableRows,
                expensiveRowMounts: false,
                primary: true,
                tableKey:
                    'features.finance.pages.finance_ar_ap_page.FinanceArApPageState.build.1',
                columns: _columns(names),
                serverColumnSearchKeys: const {
                  'billNo',
                  'sourceDocNo',
                  'salesOrderNos',
                  'party',
                  'billDate',
                  'dueDate',
                  'settlementStyleLegacy',
                  'exchangeRate',
                  'amountOriginal',
                  'amountReceivedOriginal',
                  'amountWriteOffOriginal',
                  'prepaymentAppliedOriginal',
                  'amountBalanceOriginal',
                  'amountBalance',
                  'remark',
                  'legacySourceResolution',
                },
                headerFilterScopeDescription:
                    '检索当前台账范围的完整结果；原币金额需先选择币种，本币金额单独保留',
                items: _page?.items ?? const [],
                facets: {
                  // 单号桶与列表同一过滤口径（2026-09-25 单号列统一）。
                  'billNo': _columnFilters.bucketOf('billNo'),
                  'sourceDocNo': _columnFilters.bucketOf('sourceDocNo'),
                  'direction': financeArApDirectionFacets,
                  'sourceDocType': financeArApSourceTypeFacets,
                  'openItemKind': [
                    for (final kind in const [
                      'RECEIVABLE',
                      'PAYABLE',
                      'CREDIT',
                      'CLAIM_CREDIT',
                      'PREPAYMENT',
                      'CUSTOMER_PREPAYMENT',
                      'LEGACY_UNVERIFIED',
                    ])
                      MasterFacetBucket(
                        value: kind,
                        label: financeArApOpenItemKindLabel(kind),
                        count: 0,
                      ),
                  ],
                  'legacySourceResolution': [
                    for (final status in const [
                      'EXACT_SOURCE',
                      'AMBIGUOUS_SOURCE',
                      'MISSING_OR_CONFLICTING_SOURCE',
                      'UNVERIFIED_SOURCE_KIND',
                    ])
                      MasterFacetBucket(
                        value: status,
                        label: financeLegacySourceResolutionLabel(status),
                        count: 0,
                      ),
                    const MasterFacetBucket(
                      value: 'UNSET',
                      label: '—（未提供匹配状态）',
                      count: 0,
                    ),
                  ],
                  'settlementStyleLegacy': [
                    for (final style
                        in financeArApSettlementStyleLabels.entries)
                      MasterFacetBucket(
                        value: style.key.toString(),
                        label: style.value,
                        count: 0,
                      ),
                    const MasterFacetBucket(
                      value: 'UNSET',
                      label: '未设置',
                      count: 0,
                    ),
                  ],
                  'party': selectedPartyFacet(
                    _partyId,
                    (id) => _direction == 'AP'
                        ? names.supplier(id)
                        : _direction == 'AR'
                        ? names.client(id)
                        : names.clientEntries[id] ?? names.supplierEntries[id],
                  ),
                  'settled': financeArApSettledFacets,
                  'currency': masterDictionaryFacets({
                    ...names.currencyEntries,
                    for (final currency in _columnFilters.bucketOf('currency'))
                      currency.value: currency.display,
                  }),
                },
                facetPageLoaders: {
                  'party': _direction == 'AP'
                      ? supplierPartyFacetLoader(ref)
                      : _direction == 'AR'
                      ? clientPartyFacetLoader(ref)
                      : combinedPartyFacetLoader(ref),
                },
                facetSearchScope: partyFacetSearchScope(ref, (
                  'finance-ar-ap-party',
                  _direction,
                  _criteriaRevision,
                )),
                nullCounts: const {},
                filters: {
                  ..._columnFilters.values,
                  'direction': _direction,
                  'sourceDocType': _sourceDocType,
                  'party': _partyId,
                  'currency': _currencyId,
                  'settled': _settled?.toString(),
                },
                onFilterChanged: _onColumnFilterChanged,
                sortColumn: _columnFilters.sortColumn,
                sortAscending: _columnFilters.sortAscending,
                onSortChange: _onSortChange,
                isLoading: _loading && _page == null,
                loadingMore: _loading && _page != null,
                error: _error,
                onRetry: () => _load(_tableRows.visiblePage ?? _pageNum),
                emptyMessage: '暂无台账记录',
                currentPage: _page?.page ?? 1,
                totalPages: _page?.totalPages ?? 1,
                paginationScope: _criteriaRevision,
                onPageChange: _navigatePage,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
