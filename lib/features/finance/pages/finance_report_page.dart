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
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
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
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
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
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载报表失败')));
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
        child: UtenContentContainer(
          child: _loading && _arApRows.isEmpty && _docRows.isEmpty && _acctRows.isEmpty
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    // 分类切换
                    Wrap(
                      spacing: 6,
                      children: [
                        _catChip('应收应付', _ReportCategory.arAp),
                        _catChip('收付款单据', _ReportCategory.docs),
                        _catChip('费用收入', _ReportCategory.expenseIncome),
                        _catChip('账户流水', _ReportCategory.accountFlow),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    // 过滤行
                    Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_cat == _ReportCategory.arAp) ...[
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
                        if (_cat == _ReportCategory.accountFlow)
                          SizedBox(
                            width: 240,
                            child: DropdownButtonFormField<String?>(
                              initialValue: _accountId,
                              isExpanded: true,
                              decoration:
                                  const InputDecoration(isDense: true, labelText: '账户'),
                              items: [
                                for (final e in names.accountEntries.entries)
                                  DropdownMenuItem<String?>(
                                    value: e.key,
                                    child: Text(e.value,
                                        maxLines: 1, overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                              onChanged: (v) {
                                setState(() => _accountId = v);
                                _load();
                              },
                            ),
                          ),
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
                    const SizedBox(height: UtenSpacing.s16),
                    ..._buildRows(theme, names),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _catChip(String label, _ReportCategory c) =>
      ChoiceChip(label: Text(label), selected: _cat == c, onSelected: (_) => _switchCat(c));

  List<Widget> _buildRows(ThemeData theme, FinanceNameService names) {
    switch (_cat) {
      case _ReportCategory.arAp:
        if (_arApRows.isEmpty) return [_empty(theme)];
        return [
          Text(_arApDirection == 'AR' ? '应收汇总' : '应付汇总',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: UtenSpacing.s8),
          Card(
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _arApRows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final r = _arApRows[i];
                return ListTile(
                  dense: true,
                  title: Text(r.partyName ?? '—'),
                  subtitle: Text(
                    [
                      if ((r.ym ?? '').isNotEmpty) '${r.ym}'.substring(0, 10),
                      '${r.entryCnt ?? 0} 笔',
                      if (r.currencyId != null) names.currency(r.currencyId),
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Text('余 ${r.balanceSum?.toStringAsFixed(0) ?? '—'}'),
                );
              },
            ),
          ),
        ];
      case _ReportCategory.docs:
      case _ReportCategory.expenseIncome:
        if (_docRows.isEmpty) return [_empty(theme)];
        final isDocs = _cat == _ReportCategory.docs;
        return [
          Text(isDocs ? '收付款汇总' : '费用收入汇总',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: UtenSpacing.s8),
          Card(
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _docRows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final r = _docRows[i];
                final who = [
                  r.partyName,
                  r.departmentName,
                  r.styleName,
                ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
                return ListTile(
                  dense: true,
                  title: Text(who.isEmpty ? '—' : who),
                  subtitle: Text(
                    [
                      if ((r.ym ?? '').isNotEmpty) '${r.ym}'.substring(0, 10),
                      '${r.cnt ?? 0} 笔',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Text(
                      '¥ ${r.amountLocalSum?.toStringAsFixed(0) ?? '—'}'),
                );
              },
            ),
          ),
        ];
      case _ReportCategory.accountFlow:
        if (_acctRows.isEmpty) return [_empty(theme)];
        return [
          Text('账户流水（${names.account(_accountId)}）',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: UtenSpacing.s8),
          Card(
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _acctRows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final r = _acctRows[i];
                return ListTile(
                  dense: true,
                  title: Text(
                    [
                      (r.billDate ?? '').substring(0, 16),
                      r.billNo ?? '',
                    ].join(' · '),
                  ),
                  subtitle: Text(
                    [
                      r.sourceDocType ?? '',
                      r.counterpartName ?? '',
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Text(
                      '余 ${r.runningBalance?.toStringAsFixed(0) ?? '—'}'),
                );
              },
            ),
          ),
        ];
    }
  }

  Widget _empty(ThemeData theme) => Padding(
        padding: const EdgeInsets.all(UtenSpacing.s24),
        child: Center(
          child: Text('暂无数据',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
}
