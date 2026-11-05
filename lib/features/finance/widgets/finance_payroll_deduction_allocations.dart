import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_source_table.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

const payrollDeductionPurposes = <String, String>{
  'STANDARD_LIABILITY': '应付扣款',
  'STANDARD_INCOME': '收入扣款',
  'EMPLOYEE_SETTLEMENT': '员工往来清偿',
  'EXPENSE_REDUCTION': '冲减普通费用',
  'MANUFACTURING_COST_REDUCTION': '冲减制造费用',
};

/// One row is one explicit share of one immutable original payroll item.
class PayrollDeductionAllocationRow extends EditableGridRow {
  PayrollDeductionAllocationRow(
    this.item,
    Map<String, dynamic> saved,
    this.changed,
  ) : id = saved['id']?.toString() ?? const Uuid().v4(),
      purpose = ValueNotifier(saved['purpose']?.toString()),
      style = ValueNotifier(saved['styleId']?.toString()),
      amount = TextEditingController(text: saved['amount']?.toString() ?? ''),
      reference = TextEditingController(
        text: saved['sourceReference']?.toString() ?? '',
      ),
      source = saved['source'] is Map
          ? Map<String, dynamic>.from(saved['source'] as Map)
          : {
              if (saved['auxiliaryId'] != null)
                'auxiliaryId': saved['auxiliaryId'],
              if (saved['original'] != null) 'original': saved['original'],
            } {
    for (final value in [purpose, style, amount, reference]) {
      value.addListener(changed);
    }
  }
  final Map<String, dynamic> item;
  final String id;
  final VoidCallback changed;
  final ValueNotifier<String?> purpose, style;
  final TextEditingController amount, reference;
  Map<String, dynamic> source;
  String get sourceCaption =>
      source['caption']?.toString() ??
      (source['original'] is Map
          ? ((source['original'] as Map)['kind'] == 'GL_AUXILIARY_BALANCE_POOL'
                ? '已明确该员工原余额池'
                : '已明确原GL分配')
          : '选择该员工真实未结来源');
  Map<String, dynamic> instruction() => {
    'id': id,
    'purpose': purpose.value,
    'styleId': style.value,
    'amount': amount.text.trim(),
    'auxiliaryId': purpose.value == 'EMPLOYEE_SETTLEMENT'
        ? source['auxiliaryId']
        : null,
    'original': purpose.value == 'EMPLOYEE_SETTLEMENT'
        ? source['original']
        : null,
    'sourceReference': reference.text,
  };
  Map<String, dynamic> capture() => {...instruction(), 'source': source};
  void resetSource() {
    source = {};
    changed();
  }

  @override
  void dispose() {
    for (final value in [purpose, style, amount, reference]) {
      value.removeListener(changed);
      value.dispose();
    }
    super.dispose();
  }
}

bool payrollDeductionStyleAllowed(
  Map<String, dynamic> style,
  String? purpose,
) => switch (purpose) {
  'STANDARD_LIABILITY' => style['category'] == 'LIABILITY',
  'STANDARD_INCOME' => style['category'] == 'INCOME',
  'EMPLOYEE_SETTLEMENT' => style['employeeSettlementAllowed'] == true,
  'EXPENSE_REDUCTION' => style['category'] == 'EXPENSE',
  'MANUFACTURING_COST_REDUCTION' =>
    style['category'] == 'ACCOUNT' && style['costAllowed'] == true,
  _ => false,
};

String payrollDeductionAllocationStatus(
  Map<String, dynamic> item,
  List<PayrollDeductionAllocationRow> rows,
) {
  final original = financeAmountUnits(item['amount']?.toString());
  if (original == null) {
    return '原金额待核';
  }
  if (original == BigInt.zero) {
    return '原金额为0';
  }
  BigInt sum = BigInt.zero;
  bool pending = rows.isEmpty;
  for (final row in rows) {
    final value = financeAmountUnits(row.amount.text);
    if (value == null) {
      return '份额尚未填写完整';
    }
    sum += value;
    if (value <= BigInt.zero ||
        row.purpose.value == null ||
        row.style.value == null ||
        row.reference.text.trim().isEmpty ||
        row.purpose.value == 'EMPLOYEE_SETTLEMENT' &&
            (row.source['auxiliaryId'] == null ||
                row.source['original'] == null)) {
      pending = true;
    }
  }
  if (sum != original) {
    return '份额合计与原金额不一致';
  }
  return pending ? '用途、科目或依据待明确' : '原项份额已对应，待服务端核对';
}

/// The directory keeps all original employees/items distinct; one item's shares use the native editable grid.
class FinancePayrollDeductionSection extends StatelessWidget {
  const FinancePayrollDeductionSection({
    super.key,
    required this.items,
    required this.grids,
    required this.styles,
    required this.enabled,
    required this.onChanged,
    required this.onPickSource,
    this.netAlready = false,
    this.reusedAccrual = false,
  });
  final List<Map<String, dynamic>> items, styles;
  final Map<String, UtenEditableGridController<PayrollDeductionAllocationRow>>
  grids;
  final bool enabled, netAlready, reusedAccrual;
  final VoidCallback onChanged;
  final Future<Map<String, dynamic>?> Function(PayrollDeductionAllocationRow)
  onPickSource;
  Future<void> _open(BuildContext context, Map<String, dynamic> item) async {
    if (netAlready) {
      return;
    }
    final grid = grids[item['id'].toString()];
    if (grid == null) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AllocationDialog(
        item: item,
        grid: grid,
        styles: styles,
        enabled: enabled && !reusedAccrual,
        onChanged: onChanged,
        onPickSource: onPickSource,
      ),
    );
    onChanged();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('按每名员工的每条原扣款分别对应，可拆分多个份额。原工资和扣款总额只读。'),
      if (netAlready) const Text('既有分录已经拆分扣款，本次只清偿已入账的实发净额。原扣款保留只读，不再核销旧借款。'),
      if (reusedAccrual) const Text('本批已有真实计提，沿用其冻结用途、科目与份额。再次付款不重复计提或扣回原借款。'),
      SizedBox(
        height: 350,
        child: financeSourceTable(
          tableKey: 'finance-payroll-original-deduction-items',
          columns: [
            financeSourceColumn('employeeCode', '员工编号', width: 130),
            financeSourceColumn('employeeName', '员工姓名', width: 140),
            financeSourceColumn(
              'name',
              '原扣款项目',
              width: 190,
              value: (r) => '${r['code'] ?? ''} ${r['name'] ?? ''}',
            ),
            financeSourceColumn('description', '原说明', width: 260),
            financeSourceColumn('amount', '原扣款金额', width: 180, type: 'money'),
            financeSourceColumn(
              'allocationState',
              '份额核对',
              width: 260,
              value: (r) => netAlready
                  ? '既有分录已拆分扣款'
                  : payrollDeductionAllocationStatus(
                      r,
                      grids[r['id']]?.rows ?? [],
                    ),
            ),
            MasterColumnDef<Map<String, dynamic>>(
              key: 'allocationAction',
              label: '对应扣款',
              info: netAlready ? null : '双击原扣款行核对用途及拆分份额',
              width: 140,
              value: (_) => netAlready ? '只读' : '查看/对应份额',
              columnSearchEnabled: false,
              cellBuilder: (_, item) => UtenButton(
                type: UtenButtonType.secondary,
                onPressed: netAlready ? null : () => _open(context, item),
                child: Text(enabled && !reusedAccrual ? '对应份额' : '查看份额'),
              ),
            ),
          ],
          rows: items,
          idOf: (r) => r['id'].toString(),
          onOpen: netAlready ? null : (r) => _open(context, r),
          showColumnChooser: false,
        ),
      ),
    ],
  );
}

class _AllocationDialog extends ConsumerStatefulWidget {
  const _AllocationDialog({
    required this.item,
    required this.grid,
    required this.styles,
    required this.enabled,
    required this.onChanged,
    required this.onPickSource,
  });
  final Map<String, dynamic> item;
  final UtenEditableGridController<PayrollDeductionAllocationRow> grid;
  final List<Map<String, dynamic>> styles;
  final bool enabled;
  final VoidCallback onChanged;
  final Future<Map<String, dynamic>?> Function(PayrollDeductionAllocationRow)
  onPickSource;
  @override
  ConsumerState<_AllocationDialog> createState() => _AllocationState();
}

class _AllocationState extends ConsumerState<_AllocationDialog> {
  late final int _epoch = ref.read(exportContextEpochProvider);
  late final ApiClient _api = ref.read(apiClientProvider);
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool _picking = false;
  @override
  void initState() {
    super.initState();
    widget.grid.addListener(_changed);
  }

  @override
  void dispose() {
    widget.grid.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    widget.onChanged();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _source(PayrollDeductionAllocationRow row) async {
    if (!_current || !widget.enabled || _picking) {
      return;
    }
    setState(() => _picking = true);
    try {
      final source = await widget.onPickSource(row);
      if (_current && source != null) {
        row.source = source;
        _changed();
      }
    } finally {
      if (_current) {
        setState(() => _picking = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(exportContextEpochProvider) == _epoch && _current;
    final editable = current && widget.enabled && !_picking;
    return UtenDialogFrame(
      maxWidth: 1260,
      child: SizedBox(
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const UtenDialogHeader(title: Text('原工资扣款份额对应')),
            if (!current)
              const Expanded(
                child: Center(child: Text('身份或权限已变化，原输入已保留，请关闭后重新进入。')),
              )
            else
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${widget.item['employeeCode']} ${widget.item['employeeName']}　${widget.item['code']} ${widget.item['name']}',
                      ),
                      Text(
                        '原扣款金额：${financeMoneyText(widget.item['amount']?.toString())}',
                      ),
                      Text('原说明：${widget.item['description'] ?? ''}'),
                      AnimatedBuilder(
                        animation: Listenable.merge([
                          for (final row in widget.grid.rows) ...[
                            row.purpose,
                            row.style,
                            row.amount,
                            row.reference,
                          ],
                        ]),
                        builder: (_, _) => Text(
                          payrollDeductionAllocationStatus(
                            widget.item,
                            widget.grid.rows,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          child:
                              UtenEditableGrid<PayrollDeductionAllocationRow>(
                                controller: widget.grid,
                                stickyHeader: false,
                                showAddRow: editable,
                                showRowDelete: editable,
                                addRowLabel: '拆分另一份额',
                                createBlankRow: () =>
                                    PayrollDeductionAllocationRow(
                                      widget.item,
                                      {},
                                      widget.onChanged,
                                    ),
                                columns: [
                                  EditableGridColumn(
                                    key: 'purpose',
                                    label: '本份额用途',
                                    width: 200,
                                    textOf: (r) =>
                                        payrollDeductionPurposes[r
                                            .purpose
                                            .value] ??
                                        '',
                                    listenableOf: (r) => r.purpose,
                                    cellBuilder: (_, r) => UtenDropdownField(
                                      value: r.purpose.value,
                                      items: [
                                        for (final e
                                            in payrollDeductionPurposes.entries)
                                          UtenDropdownItem(
                                            value: e.key,
                                            label: e.value,
                                          ),
                                      ],
                                      enabled: editable,
                                      onChanged: (v) {
                                        r.purpose.value = v;
                                        r.style.value = null;
                                        r.resetSource();
                                        _changed();
                                      },
                                    ),
                                  ),
                                  EditableGridColumn(
                                    key: 'style',
                                    label: '明确会计科目',
                                    width: 260,
                                    textOf: (r) =>
                                        widget.styles
                                            .where(
                                              (s) => s['id'] == r.style.value,
                                            )
                                            .firstOrNull?['name']
                                            ?.toString() ??
                                        '',
                                    listenableOf: (r) => r.style,
                                    cellBuilder: (_, r) => UtenDropdownField(
                                      value: r.style.value,
                                      items: [
                                        for (final s in widget.styles)
                                          if (payrollDeductionStyleAllowed(
                                            s,
                                            r.purpose.value,
                                          ))
                                            UtenDropdownItem(
                                              value: s['id'].toString(),
                                              label:
                                                  '${s['code']} ${s['name']}',
                                            ),
                                      ],
                                      enabled: editable,
                                      onChanged: (v) {
                                        r.style.value = v;
                                        r.resetSource();
                                        _changed();
                                      },
                                    ),
                                  ),
                                  EditableGridColumn(
                                    key: 'amount',
                                    label: '本份额原金额',
                                    width: 210,
                                    textOf: (r) => r.amount.text,
                                    listenableOf: (r) => r.amount,
                                    cellBuilder: (_, r) => UtenInput(
                                      controller: r.amount,
                                      enabled: editable,
                                    ),
                                  ),
                                  EditableGridColumn(
                                    key: 'source',
                                    label: '员工往来清偿来源',
                                    width: 270,
                                    textOf: (r) => r.sourceCaption,
                                    cellBuilder: (_, r) =>
                                        r.purpose.value == 'EMPLOYEE_SETTLEMENT'
                                        ? UtenButton(
                                            type: UtenButtonType.secondary,
                                            onPressed:
                                                editable &&
                                                    r.style.value != null
                                                ? () => _source(r)
                                                : null,
                                            child: Text(r.sourceCaption),
                                          )
                                        : const Text('按本原扣款明确归属'),
                                  ),
                                  EditableGridColumn(
                                    key: 'reference',
                                    label: '本份额确认依据',
                                    width: 300,
                                    textOf: (r) => r.reference.text,
                                    listenableOf: (r) => r.reference,
                                    cellBuilder: (_, r) => UtenInput(
                                      controller: r.reference,
                                      enabled: editable,
                                    ),
                                  ),
                                ],
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerRight,
                child: UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: _picking ? null : () => Navigator.pop(context),
                  child: const Text('保留份额并返回'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
