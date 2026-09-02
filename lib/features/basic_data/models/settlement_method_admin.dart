// 结算方式管理页模型（对应后端 SettlementMethodAdminItem，V453）。
//
// 账期策略与 SupplierPaymentTermService.calculateDueDate 同口径：
//   到期日 = 基准(RECEIPT_DATE/STATEMENT_END) → 规则(NET_DAYS/EOM_PLUS_DAYS/
//   FIXED_DAY_OF_MONTH) 推导；QC/发票/对账确认基准等待专用事件，到期日保持未定。
//   供应商正数 tday 覆盖方式默认天数；CASH 系统角色固定收货日到期。

/// 结算方式管理行（含禁用行与账期策略）。
class SettlementMethodAdminItem {
  const SettlementMethodAdminItem({
    required this.id,
    this.legacyId,
    this.code,
    required this.name,
    this.status,
    this.systemRole,
    required this.termsBase,
    required this.dueRule,
    required this.defaultDueDays,
    this.fixedDayOfMonth,
    required this.monthsAhead,
    this.remark,
  });

  final String id;
  final int? legacyId;
  final String? code;
  final String name;
  final String? status;
  final String? systemRole; // CASH/MONTHLY；非空=系统角色锁定，账期不可在线改
  final String termsBase;
  final String dueRule;
  final int defaultDueDays;
  final int? fixedDayOfMonth;
  final int monthsAhead;
  final String? remark;

  factory SettlementMethodAdminItem.fromJson(Map<String, dynamic> json) =>
      SettlementMethodAdminItem(
        id: json['id'] as String,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        code: json['code'] as String?,
        name: (json['name'] ?? '') as String,
        status: json['status'] as String?,
        systemRole: json['systemRole'] as String?,
        termsBase: json['termsBase'] as String? ?? 'RECEIPT_DATE',
        dueRule: json['dueRule'] as String? ?? 'NET_DAYS',
        defaultDueDays: (json['defaultDueDays'] as num?)?.toInt() ?? 0,
        fixedDayOfMonth: (json['fixedDayOfMonth'] as num?)?.toInt(),
        monthsAhead: (json['monthsAhead'] as num?)?.toInt() ?? 0,
        remark: json['remark'] as String?,
      );

  bool get lockedBySystemRole => systemRole != null && systemRole!.isNotEmpty;
}

const settlementTermsBaseLabels = <String, String>{
  'RECEIPT_DATE': '收货/进仓日',
  'QC_ACCEPTANCE_DATE': '质检验收日(待开放)',
  'STATEMENT_END': '月末',
  'STATEMENT_CONFIRM_DATE': '对账确认日(待开放)',
  'INVOICE_DATE': '发票日(待开放)',
};

const settlementDueRuleLabels = <String, String>{
  'NET_DAYS': '基准 + N 天',
  'EOM_PLUS_DAYS': '月末 + N 天',
  'FIXED_DAY_OF_MONTH': '固定日',
};

String settlementTermsBaseLabel(String? v) =>
    settlementTermsBaseLabels[v] ?? (v ?? '—');

String settlementDueRuleLabel(String? v) =>
    settlementDueRuleLabels[v] ?? (v ?? '—');

/// 账期口径一句话摘要（与 SupplierPaymentTermService 推导一致；
/// 供应商正数结算天数优先于方式默认天数，由提示文案补充说明）。
String settlementTermsSummary(SettlementMethodAdminItem m) {
  if (m.lockedBySystemRole && m.systemRole == 'CASH') return '现金：收货/进仓当天到期';
  final base = settlementTermsBaseLabel(m.termsBase);
  final futureBase =
      m.termsBase == 'QC_ACCEPTANCE_DATE' ||
      m.termsBase == 'STATEMENT_CONFIRM_DATE' ||
      m.termsBase == 'INVOICE_DATE';
  if (futureBase) {
    return '$base触发后按${settlementDueRuleLabel(m.dueRule)}计算；事件处理器开放前到期日保持未定';
  }
  switch (m.dueRule) {
    case 'NET_DAYS':
      return m.defaultDueDays == 0
          ? '$base当天到期'
          : '$base + ${m.defaultDueDays} 天';
    case 'EOM_PLUS_DAYS':
      return '${m.defaultDueDays == 0 ? '月末' : '月末 + ${m.defaultDueDays} 天'}'
          '${m.monthsAhead > 0 ? '（跨 ${m.monthsAhead} 月）' : ''}';
    case 'FIXED_DAY_OF_MONTH':
      return '基准月+${m.monthsAhead}月的 ${m.fixedDayOfMonth ?? '?'} 日（不足顺延下月）';
    default:
      return '—';
  }
}

/// 系统角色徽标文案。
String settlementSystemRoleLabel(String? role) => switch (role) {
  'CASH' => '现金 · 系统锁定',
  'MONTHLY' => '月结 · 系统锁定',
  _ => '—',
};
