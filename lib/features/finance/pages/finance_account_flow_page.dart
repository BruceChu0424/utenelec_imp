// 账户流水页 (S/Q/R)（finance_report:view）。
//
// 单独卡：报表类型 chip：
//   · 帐户进出流水 (S)   → /finance/reports/account/statement?accountId&dateFrom&dateTo&keyword（滚动余额）
//   · 银行存取明细 (Q)   → /finance/reports/bank/detail（M_Bank 老库 0 行，空表保结构）
//   · 银行存取汇总 (R)   → /finance/reports/bank/summary（空表）
// 右侧 MasterDataTableView。默认日期范围 = 上月今日..今日（defaultReportFrom()）。账户列表来自 FinanceNameService。
//
// 筛选口径（报表类型/账户/日期范围/排序）按账号服务端持久化
// （report.finance.accountFlow，ReportFilterPrefs：docType=view、extra={accountId}）；关键字不持久化。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../report/shared/report_cell.dart';
import '../../report/shared/report_data.dart';
import '../../report/shared/report_date_range.dart';
import '../../report/shared/report_filter_prefs.dart';
import '../../report/shared/report_sort.dart';
import '../providers/finance_name_provider.dart';

enum _FlowView { statement, bankDetail, bankSummary }

class FinanceAccountFlowPage extends ConsumerStatefulWidget {
  const FinanceAccountFlowPage({super.key});

  @override
  ConsumerState<FinanceAccountFlowPage> createState() =>
      _FinanceAccountFlowPageState();
}

class _FinanceAccountFlowPageState
    extends ConsumerState<FinanceAccountFlowPage> {
  _FlowView _view = _FlowView.statement;
  String? _accountId;
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  String _keyword = '';
  int _page = 1;
  final int _size = 50;

  // 列排序态：_sortKey=当前排序列 key（null=不排序）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  ReportData? _data;
  bool _loading = false;

  /// 用户是否已动手改过筛选（服务端偏好同步晚到时，已动手则不回灌，避免覆盖在输状态）。
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyPrefs(ref.read(financeAccountFlowReportPrefsProvider));
      ref.read(financeNameServiceProvider).ensureLoaded().then((_) {
        final entries = ref.read(financeNameServiceProvider).accountEntries;
        // 偏好恢复的账户优先；无恢复值才默认第一个
        if (entries.isNotEmpty) {
          setState(() {
            if (_accountId == null || !entries.containsKey(_accountId)) {
              _accountId = entries.keys.first;
            }
          });
        }
        _load();
      });
    });
  }

  /// 应用偏好快照（空快照=未存过，保留页面默认）。
  void _applyPrefs(ReportFilterPrefs p) {
    if (p.isEmpty) return;
    setState(() {
      final v = p.docType;
      if (v != null) {
        _view = _FlowView.values.firstWhere(
          (e) => e.name == v,
          orElse: () => _view,
        );
      }
      _accountId = p.extra['accountId']?.toString();
      // 日期范围不回灌：进页始终用默认日期范围（上月今日..今日），避免历史持久化
      // 的过时日期范围把新数据滤空（销售报表已踩此坑，见 sales_report_page.dart）。
      _sortKey = p.sortKey;
      _sortAsc = p.sortAsc;
    });
  }

  /// 当前筛选口径快照（不含关键字/分页）。
  ReportFilterPrefs _snapshot() => ReportFilterPrefs(
    docType: _view.name,
    sortKey: _sortKey,
    sortAsc: _sortAsc,
    extra: {if (_accountId != null) 'accountId': _accountId},
  );

  /// 任何筛选变更后调用：标记已动手 + 防抖持久化到服务端。
  void _persistPrefs() {
    _dirty = true;
    ref
        .read(financeAccountFlowReportPrefsProvider.notifier)
        .update(_snapshot());
  }

  String get _endpoint => switch (_view) {
    _FlowView.statement => '/finance/reports/account/statement',
    _FlowView.bankDetail => '/finance/reports/bank/detail',
    _FlowView.bankSummary => '/finance/reports/bank/summary',
  };

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final query = <String, dynamic>{
        if (_view == _FlowView.statement) ...{
          if (_accountId != null) 'accountId': _accountId,
          'dateFrom': _fmt(_from),
          'dateTo': _fmt(_to),
          if (_keyword.isNotEmpty) 'keyword': _keyword,
        },
        'page': _page,
        'size': _size,
        ...sortQueryParams(_sortKey, _sortAsc),
      };
      final json = await api.get(_endpoint, query: query);
      if (!mounted) return;
      setState(() {
        _data = parseReportResponse(json, _page);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      context.appError('加载流水失败：$e');
      setState(() => _loading = false);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 表头排序回调：column=null 取消排序回到默认；否则按该列升/降序重新请求后端。
  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
      _page = 1;
    });
    _persistPrefs();
    _load();
  }

  /// 导出报表 key（仅 S 帐户进出流水纳入导出；Q/R 银行存取款老库 0 行空表，不纳入）。
  String get _exportReport => 'account/statement';

  /// 导出查询参数（与 _load 一致，不含 page/size）。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_accountId != null) 'accountId': _accountId,
    'dateFrom': _fmt(_from),
    'dateTo': _fmt(_to),
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    ...sortQueryParams(_sortKey, _sortAsc),
  };

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  /// 仅 S 帐户进出流水（与导出口径一致）。
  Future<UtenPrintTable> _printLoader() async {
    final api = ref.read(apiClientProvider);
    final json = await api.get(
      '/finance/reports/account/statement',
      query: <String, dynamic>{..._exportQuery, 'page': 1, 'size': 2000},
    );
    final data = parseReportResponse(json, 1);
    return UtenPrintTable(
      headers: [for (final c in data.columns) c.label],
      rows: [
        for (final r in data.rows)
          [for (final c in data.columns) formatReportCell(c, r) ?? ''],
      ],
    );
  }

  /// 当前视图标题（build 与表格工具条共用）。
  String get _title => switch (_view) {
    _FlowView.statement => '帐户进出流水帐',
    _FlowView.bankDetail => '银行存取款明细表',
    _FlowView.bankSummary => '银行存取款汇总表',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _title;
    // 服务端偏好同步晚到：仅在用户未动手时回灌并重查（避免覆盖在输状态）。
    ref.listen(financeAccountFlowReportPrefsProvider, (prev, next) {
      if (!_dirty && prev != next && !next.isEmpty && mounted) {
        _applyPrefs(next);
        _page = 1;
        _load();
      }
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: title,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            // 「顶部折叠 + 表格吸顶内滚」：标题行随上滑收起腾出空间，
            // 筛选/表格区占满剩余空间、表体内部滚动（与单据列表页统一）。
            child: UtenCollapsingHeaderScrollView(
              collapsingHeader: Padding(
                padding: const EdgeInsets.only(
                  bottom: UtenSpacing.s8,
                  left: UtenSpacing.s4,
                  right: UtenSpacing.s4,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.account_balance_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    if (_data != null)
                      Text(
                        '共 ${_data!.total} 条',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              body: UtenListTwoPane(
                filterPane: _buildFilterPane(theme),
                tablePane: _buildTable(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterPane(ThemeData theme) {
    final names = ref.watch(financeNameServiceProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: SingleChildScrollView(
        // primary:false：筛选区是页面局部滚动件，不与外层折叠联动争抢
        // PrimaryScrollController（避免与表体 primary 列表形成多 ScrollPosition 冲突）。
        primary: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _filterLabel('报表类型'),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: const Text('帐户进出流水'),
                  selected: _view == _FlowView.statement,
                  onSelected: (_) => _changeView(_FlowView.statement),
                ),
                ChoiceChip(
                  label: const Text('银行存取明细'),
                  selected: _view == _FlowView.bankDetail,
                  onSelected: (_) => _changeView(_FlowView.bankDetail),
                ),
                ChoiceChip(
                  label: const Text('银行存取汇总'),
                  selected: _view == _FlowView.bankSummary,
                  onSelected: (_) => _changeView(_FlowView.bankSummary),
                ),
              ],
            ),
            if (_view == _FlowView.statement) ...[
              const SizedBox(height: UtenSpacing.s12),
              _filterLabel('账户'),
              SizedBox(
                width: double.infinity,
                child: DropdownButtonFormField<String?>(
                  initialValue: _accountId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '选择账户',
                  ),
                  items: [
                    for (final e in names.accountEntries.entries)
                      DropdownMenuItem<String?>(
                        value: e.key,
                        child: Text(
                          e.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _accountId = v;
                      _page = 1;
                    });
                    _persistPrefs();
                    _load();
                  },
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              _filterLabel('日期范围'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      final p = await showDatePicker(
                        context: context,
                        initialDate: _from,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (p != null) {
                        setState(() => _from = p);
                        _persistPrefs();
                      }
                    },
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text('起 ${_fmt(_from)}'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final p = await showDatePicker(
                        context: context,
                        initialDate: _to,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (p != null) {
                        setState(() => _to = p);
                        _persistPrefs();
                      }
                    },
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text('止 ${_fmt(_to)}'),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              _filterLabel('搜索'),
              UtenSearchBar(
                hint: '搜索单号/对方',
                initialValue: _keyword,
                onChanged: (v) => _keyword = v,
              ),
              const SizedBox(height: UtenSpacing.s12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    _page = 1;
                    _load();
                  },
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: const Text('查询'),
                ),
              ),
            ],
            if (_view != _FlowView.statement) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '银行存取款单老库未启用（0 行），报表为空（结构已就位，启用后自动出数）。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _changeView(_FlowView v) {
    if (v == _view) return;
    setState(() {
      _view = v;
      _page = 1;
      _data = null;
    });
    _persistPrefs();
    _load();
  }

  Widget _buildTable() {
    if (_view == _FlowView.statement && _accountId == null) {
      return const Center(child: Text('请先选择账户'));
    }
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final data = _data;
    if (data == null) {
      return const Center(child: Text('点击「查询」加载'));
    }
    final columns = data.columns
        .map(
          (c) => MasterColumnDef<Map<String, dynamic>>(
            key: c.key,
            label: c.label,
            width: (c.width ?? 120).toDouble(),
            type: c.type,
            sortable: isSortableReportType(c.type),
            value: (row) => formatReportCell(c, row),
          ),
        )
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
      primary: true,
      columns: columns,
      items: data.rows,
      // 仅 S 帐户进出流水支持预览打印/导出；Q/R 银行存取款为空表（M_Bank 0 行），不显示。
      toolbarActions: [
        if (_view == _FlowView.statement) ...[
          UtenPrintPreviewButton(
            title: _title,
            subtitle: '日期 ${_fmt(_from)} ~ ${_fmt(_to)}（最多前 2000 行）',
            loader: _printLoader,
            exportEndpoint: '/finance/reports/export',
            exportPermission: Perm.financeReportExport,
            exportReport: _exportReport,
            exportQuery: _exportQuery,
            exportFilename: _title,
            type: UtenButtonType.primary,
            size: UtenButtonSize.large,
          ),
          UtenExportButton(
            endpoint: '/finance/reports/export',
            requiredPermission: Perm.financeReportExport,
            report: _exportReport,
            queryParams: _exportQuery,
            filename: _title,
            type: UtenButtonType.primary,
            size: UtenButtonSize.large,
          ),
        ],
      ],
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      sortColumn: _sortKey,
      sortAscending: _sortAsc,
      onSortChange: _onSortChange,
      isLoading: _loading,
      emptyMessage: _view == _FlowView.statement ? '暂无流水数据' : '银行存取款未启用（空表）',
      currentPage: data.page,
      totalPages: data.totalPages,
      onPageChange: (p) {
        _page = p;
        _load();
      },
    );
  }

  Widget _filterLabel(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
