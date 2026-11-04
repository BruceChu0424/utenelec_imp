/// Accounting intent does not recategorize an existing style or turn a cost balance into P&L.
enum AccountingExpensePurpose {
  ordinaryExpense('ORDINARY_EXPENSE', '普通费用'),
  manufacturingCost('MANUFACTURING_COST', '制造费用');

  const AccountingExpensePurpose(this.apiValue, this.label);
  final String apiValue, label;
  static AccountingExpensePurpose fromApi(Object? raw) {
    if (raw == null || raw == '') return ordinaryExpense;
    return values.firstWhere(
      (p) => p.apiValue == raw,
      orElse: () => throw FormatException('不支持的支出类型：$raw'),
    );
  }
}
