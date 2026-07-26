// 钱流报表页（finance_report:view）—— 4 大类报表按需切换 + 日期范围过滤。
//
// 替换原占位页（类名/路径不变，app_router 的 import 仍可用）。
// 4 类（对应后端 /api/finance/reports/*）：
//  A. 应收应付类：arApSummary（Z 总览/B 应收/D 应付，direction 切换）
//  B. 收付款单据类：receiptsSummary / paymentsSummary（F/H，按往来方汇总）
//  C. 费用收入类：expensesSummary / incomesSummary（N/P，按部门/项目汇总）
//  D. 账户流水类：accountStatement（S，需选账户；滚动余额）
// 名称解析：客户/供应商/账户 用 FinanceNameService。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';

enum _ReportCategory { arAp, docs, expenseIncome, accountFlow }

class FinanceReportPage extends ConsumerStatefulWidget {
  const FinanceReportPage({super.key});

  @override
  ConsumerState<FinanceReportPage> createState() => _FinanceReportPageState();
}

class _FinanceReportPageState extends ConsumerState<FinanceReportPage> {
  _ReportCategory _cat = _ReportCategory.arAp;
  DateTime _from = DateTime(DateTime.now().year);
  DateTime _to = DateTime.now();

  // A. 应收应付：direction 切换。
  String? _arApDirection = 'AR';

  // D. 账户流水：选账户。
  String? _accountId;

  List<ArApSummaryRow> _arApRows = const [];
  List<FinanceDocReportRow> _docRows = const [];
  List<AccountStatementRow> _acctRows = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(financeNameServiceProvider).ensureLoaded().then((_) => _load());
    });
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = ref.read(financeReportRepositoryProvider);
    try {
      switch (_cat) {
        case _ReportCategory.arAp:
          final r = await repo.arApSummary(
            direction: _arApDirection,
            dateFrom: _fmt(_from),
            dateTo: _fmt(_to),
          );
          if (!mounted) return;
          setState(() => _arApRows = r);
        case _ReportCategory.docs:
          // 收 + 付 汇总合并展示。
          final rec = await repo.docSummary('receipts',
              dateFrom: _fmt(_from), dateTo: _fmt(_to));
          final pay = await repo.docSummary('payments',
              dateFrom: _fmt(_from), dateTo: _fmt(_to));
          if (!mounted) return;
          setState(() => _docRows = [...rec, ...pay]);
        case _ReportCategory.expenseIncome:
          final exp = await repo.docSummary('expenses',
              dateFrom: _fmt(_from), dateTo: _fmt(_to));
          final inc = await repo.docSummary('incomes',
              dateFrom: _fmt(_from), dateTo: _fmt(_to));
          if (!mounted) return;
          setState(() => _docRows = [...exp, ...inc]);
        case _ReportCategory.accountFlow:
          // 默认选第一个账户。
          final entries = ref.read(financeNameServiceProvider).accountEntries;
          final acct = _accountId ??
              (entries.isNotEmpty ? entries.keys.first : null);
          if (acct == null) {
            if (!mounted) return;
            setState(() => _acctRows = const []);
            break;
          }
          final r = await repo.accountStatement(accountId: acct);
          if (!mounted) return;
          setState(() => _acctRows = r);
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('finance report load failed: $e');
      // 原先 catch(_) 吞异常只弹通用文案，无法定位 403/500/解析错。
      // 现把真实 code + message 透出（ApiException.code=FORBIDDEN/INTERNAL/NETWORK/...）。
      final msg = e is ApiException
          ? '${e.code} · ${e.message}'
          : '加载报表失败：$e';
      context.appError(msg);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _switchCat(_ReportCategory c) {
    if (c == _cat) return;
    setState(() {
      _cat = c;
      _arApRows = const [];
      _docRows = const [];
      _acctRows = const [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '钱流报表',
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.finance)),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 页面头：Icon + 标题（筛选挪到左侧栏/顶部）
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(Icons.assessment_outlined,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text('钱流报表',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                // 桌面：左筛选侧栏（类别 + 方向/账户 + 日期）+ 右报表内容；手机：垂直堆叠
                Expanded(
                  child: UtenListTwoPane(
                    filterPane: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _filterLabel('报表类别'),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _catChip('应收应付', _ReportCategory.arAp),
                              _catChip('收付款单据', _ReportCategory.docs),
                              _catChip('费用收入', _ReportCategory.expenseIncome),
                              _catChip('账户流水', _ReportCategory.accountFlow),
                            ],
                          ),
                          if (_cat == _ReportCategory.arAp) ...[
                            const SizedBox(height: UtenSpacing.s12),
                            _filterLabel('方向'),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                ChoiceChip(
                                  label: const Text('应收'),
                                  selected: _arApDirection == 'AR',
                                  onSelected: (_) {
                                    setState(() => _arApDirection = 'AR');
                                    _load();
                                  },
                                ),
                                ChoiceChip(
                                  label: const Text('应付'),
                                  selected: _arApDirection == 'AP',
                                  onSelected: (_) {
                                    setState(() => _arApDirection = 'AP');
                                    _load();
                                  },
                                ),
                              ],
                            ),
                          ],
                          if (_cat == _ReportCategory.accountFlow) ...[
                            const SizedBox(height: UtenSpacing.s12),
                            SizedBox(
                              width: double.infinity,
                              child: DropdownButtonFormField<String?>(
                                initialValue: _accountId,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                    isDense: true, labelText: '账户'),
                                items: [
                                  for (final e in names.accountEntries.entries)
                                    DropdownMenuItem<String?>(
                                      value: e.key,
                                      child: Text(e.value,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                    ),
                                ],
                                onChanged: (v) {
                                  setState(() => _accountId = v);
                                  _load();
                                },
                              ),
                            ),
                          ],
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
                                    firstDate: DateTime(2010),
                                    lastDate: DateTime(2100),
                                  );
                                  if (p != null) {
                                    setState(() => _from = p);
                                    _load();
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
                                    firstDate: DateTime(2010),
                                    lastDate: DateTime(2100),
                                  );
                                  if (p != null) {
                                    setState(() => _to = p);
                                    _load();
                                  }
                                },
                                icon: const Icon(Icons.event_outlined, size: 18),
                                label: Text('止 ${_fmt(_to)}'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    tablePane: _buildReportArea(theme, names),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _catChip(String label, _ReportCategory c) =>
      ChoiceChip(label: Text(label), selected: _cat == c, onSelected: (_) => _switchCat(c));

  /// 报表内容区：加载中且无数据时居中转圈，否则 标题 + Expanded(Excel 表)。
  /// MasterDataTableView 内部含 Expanded，必须放进有界高度的 Expanded 父级。
  Widget _buildReportArea(ThemeData theme, FinanceNameService names) {
    if (_loading &&
        _arApRows.isEmpty &&
        _docRows.isEmpty &&
        _acctRows.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final title = _catTitle(names);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(UtenSpacing.s12, UtenSpacing.s4,
                UtenSpacing.s12, UtenSpacing.s4),
            child: Text(title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
        Expanded(child: _tableForCat(names)),
      ],
    );
  }

  String? _catTitle(FinanceNameService names) {
    switch (_cat) {
      case _ReportCategory.arAp:
        return _arApRows.isEmpty
            ? null
            : '${_arApDirection == 'AR' ? '应收汇总' : '应付汇总'}（共 ${_arApRows.length} 条）';
      case _ReportCategory.docs:
        return _docRows.isEmpty
            ? null
            : '收付款汇总（共 ${_docRows.length} 条）';
      case _ReportCategory.expenseIncome:
        return _docRows.isEmpty
            ? null
            : '费用收入汇总（共 ${_docRows.length} 条）';
      case _ReportCategory.accountFlow:
        return _acctRows.isEmpty
            ? null
            : '账户流水（${names.account(_accountId)}，共 ${_acctRows.length} 条）';
    }
  }

  Widget _tableForCat(FinanceNameService names) {
    switch (_cat) {
      case _ReportCategory.arAp:
        return _arApTable(names);
      case _ReportCategory.docs:
      case _ReportCategory.expenseIncome:
        return _docTable();
      case _ReportCategory.accountFlow:
        return _acctTable();
    }
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

  /// 应收应付汇总表。
  Widget _arApTable(FinanceNameService names) {
    return MasterDataTableView<ArApSummaryRow>(
      columns: <MasterColumnDef<ArApSummaryRow>>[
        MasterColumnDef(
            key: 'ym', label: '月份', width: 110, value: (r) => _ym10(r.ym)),
        MasterColumnDef(
            key: 'party', label: '往来方', width: 220, value: (r) => r.partyName),
        MasterColumnDef(
            key: 'cnt',
            label: '笔数',
            width: 90,
            value: (r) => (r.entryCnt ?? 0).toString()),
        MasterColumnDef(
            key: 'cur',
            label: '币种',
            width: 90,
            value: (r) =>
                r.currencyId == null ? null : names.currency(r.currencyId)),
        MasterColumnDef(
            key: 'bal',
            label: '余额',
            width: 140,
            value: (r) => r.balanceSum?.toStringAsFixed(2)),
      ],
      items: _arApRows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (_) {},
    );
  }

  /// 收付款 / 费用收入汇总表（按往来方/部门/类别 × 月）。
  Widget _docTable() {
    return MasterDataTableView<FinanceDocReportRow>(
      columns: <MasterColumnDef<FinanceDocReportRow>>[
        MasterColumnDef(
            key: 'ym', label: '月份', width: 110, value: (r) => _ym10(r.ym)),
        MasterColumnDef(
            key: 'party', label: '往来方', width: 200, value: (r) => r.partyName),
        MasterColumnDef(
            key: 'dept', label: '部门', width: 140, value: (r) => r.departmentName),
        MasterColumnDef(
            key: 'style', label: '类别', width: 120, value: (r) => r.styleName),
        MasterColumnDef(
            key: 'cnt',
            label: '笔数',
            width: 90,
            value: (r) => (r.cnt ?? 0).toString()),
        MasterColumnDef(
            key: 'amt',
            label: '金额',
            width: 140,
            value: (r) => r.amountLocalSum?.toStringAsFixed(2)),
      ],
      items: _docRows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (_) {},
    );
  }

  /// 账户流水表（滚动余额）。
  Widget _acctTable() {
    return MasterDataTableView<AccountStatementRow>(
      columns: <MasterColumnDef<AccountStatementRow>>[
        MasterColumnDef(
            key: 'date', label: '日期', width: 140, value: (r) => _dt16(r.billDate)),
        MasterColumnDef(
            key: 'billNo', label: '单据号', width: 140, value: (r) => r.billNo),
        MasterColumnDef(
            key: 'src', label: '来源', width: 120, value: (r) => r.sourceDocType),
        MasterColumnDef(
            key: 'counter',
            label: '对手方',
            width: 160,
            value: (r) => r.counterpartName),
        MasterColumnDef(
            key: 'bal',
            label: '余额',
            width: 140,
            value: (r) => r.runningBalance?.toStringAsFixed(2)),
      ],
      items: _acctRows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (_) {},
    );
  }

  /// 年月（yyyy-MM-dd）安全截断：短串原样返回，避免 substring(0,10) 越界。
  static String _ym10(String? s) {
    if (s == null || s.isEmpty) return '';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  /// 日期时间安全截断到「yyyy-MM-dd HH:mm」：先判长度再 substring
  /// （原 (billDate??'').substring(0,16) 在空串上报 RangeError）。
  static String _dt16(String? s) {
    if (s == null || s.isEmpty) return '';
    final t = s.replaceAll('T', ' ');
    return t.length >= 16 ? t.substring(0, 16) : t;
  }

  // 报表行统一以 MasterDataTableView 渲染（见 _arApTable/_docTable/_acctTable），
  // 不再使用 ListTile/Card。
}
