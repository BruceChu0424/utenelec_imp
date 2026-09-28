// 销售报价单财务核价流程字段(ADR-134 / SPEC §6.2)。
//
// 报价单状态机: 0 草稿(财务退回时带退回原因) / 2 待财务核价 / 1 财务已核价 / -1 作废。
// 服务端随报价列表行与详情一起下发:
//   · statusBucket —— 与分段计数同一分桶键(DRAFT / PENDING_FINANCE / FINANCE_REJECTED /
//     APPROVED / REVERSED), 前端只在缺失时按 status + 退回原因兜底推算;
//   · allowedActions —— 当前登录人此刻能做的动作(编辑/删除/提交/撤回/重新修改/转订货/
//     作废/去核价), 按钮只按它显隐, 页面不再本地拼权限(permissions-15);
//   · reviewRevision —— 乐观锁版本, 提交/撤回/重新修改都带回给服务端核对;
//   · revisions —— 核价记录(提交/撤回/财务修改/退回/确认/重新修改), 可选。
//
// 本文件只解析, 不含任何界面文字; 状态文字在 widgets/sales_quote_status_chip.dart 经 arb 输出。

/// 报价单的动作(与服务端 allowedActions 逐项对应)。
enum SalesQuoteAction {
  edit('edit'),
  delete('delete'),
  submit('submit'),
  withdraw('withdraw'),
  reopen('reopen'),
  convert('convert'),
  reverse('reverse'),
  financeReview('financeReview');

  const SalesQuoteAction(this.code);

  /// 服务端动作码(大小写与下划线不敏感, 见 [normalizeQuoteActionCode])。
  final String code;
}

/// 动作码归一: 去掉下划线/连字符并转小写, 让 `FINANCE_REVIEW` 与 `financeReview` 等价。
String normalizeQuoteActionCode(String code) =>
    code.replaceAll(RegExp(r'[_\-\s]'), '').toLowerCase();

/// 核价记录的动作类型(sales_quote_revision_logs.action)。
abstract final class SalesQuoteRevisionAction {
  static const submit = 'SUBMIT';
  static const withdraw = 'WITHDRAW';
  static const financeEdit = 'FINANCE_EDIT';
  static const returnToSales = 'RETURN';
  static const confirm = 'CONFIRM';
  static const reopen = 'REOPEN';
  static const financeReopen = 'FINANCE_REOPEN';
}

/// 一条核价记录。
class SalesQuoteRevision {
  const SalesQuoteRevision({
    required this.action,
    this.actionLabel,
    this.revision,
    this.actorName,
    this.reason,
    this.summary,
    this.createdAt,
  });

  /// [SalesQuoteRevisionAction] 之一; 未知值原样保留(界面按「其它记录」显示)。
  final String action;

  /// 服务端给人看的中文动作名(QuoteRevisionDto.actionLabel)；未知动作码时作显示兜底。
  final String? actionLabel;
  final int? revision;
  final String? actorName;

  /// 退回原因(RETURN)或其它说明。
  final String? reason;

  /// 服务端给出的一句话变化摘要(例如「改了 3 行折扣」), 可空。
  final String? summary;
  final String? createdAt;

  factory SalesQuoteRevision.fromJson(Map<String, dynamic> json) =>
      SalesQuoteRevision(
        action: (_text(json['action']) ?? '').toUpperCase(),
        actionLabel: _text(json['actionLabel']),
        revision: _int(json['revision']),
        actorName: _text(json['actorName'] ?? json['operatorName']),
        reason: _text(json['reason']),
        summary: _text(json['summary']),
        createdAt: _text(json['createdAt'] ?? json['occurredAt']),
      );

  /// 解析 revisions 数组; 非数组或元素不是对象时跳过, 不抛错。
  static List<SalesQuoteRevision> listFromJson(Object? raw) => raw is List
      ? raw
            .whereType<Map<Object?, Object?>>()
            .map((e) => SalesQuoteRevision.fromJson(e.cast<String, dynamic>()))
            .toList(growable: false)
      : const [];
}

/// 报价单的财务核价流程快照(列表行与详情共用)。
class SalesQuoteWorkflow {
  const SalesQuoteWorkflow({
    this.statusBucket,
    this.financeReturnReason,
    this.financeReturnedAt,
    this.financeReturnedByName,
    this.submittedAt,
    this.submittedByName,
    this.financeConfirmedAt,
    this.financeConfirmedByName,
    this.financeRemark,
    this.reviewRevision = 0,
    this.convertedOrderId,
    this.convertedOrderNo,
    this.allowedActions = const {},
    this.hasAllowedActions = false,
    this.revisions = const [],
  });

  static const empty = SalesQuoteWorkflow();

  /// 服务端分桶键(见 sales_doc.dart 的 SalesQuoteStage); 老载荷没有时为 null。
  final String? statusBucket;
  final String? financeReturnReason;
  final String? financeReturnedAt;
  final String? financeReturnedByName;
  final String? submittedAt;
  final String? submittedByName;
  final String? financeConfirmedAt;
  final String? financeConfirmedByName;

  /// 财务写给销售看的备注(选填)。
  final String? financeRemark;

  /// 乐观锁版本: 提交/撤回/重新修改时原样带回。
  final int reviewRevision;
  final String? convertedOrderId;
  final String? convertedOrderNo;

  /// 归一后的动作码集合([normalizeQuoteActionCode])。
  final Set<String> allowedActions;

  /// 载荷里是否带了 allowedActions 键: 没带(旧服务端)时按钮一律不显示, 不猜。
  final bool hasAllowedActions;
  final List<SalesQuoteRevision> revisions;

  bool allows(SalesQuoteAction action) =>
      allowedActions.contains(normalizeQuoteActionCode(action.code));

  bool get isConverted =>
      (convertedOrderId?.isNotEmpty ?? false) ||
      (convertedOrderNo?.isNotEmpty ?? false);

  factory SalesQuoteWorkflow.fromJson(Map<String, dynamic> json) {
    final rawActions = json['allowedActions'];
    return SalesQuoteWorkflow(
      statusBucket: _text(json['statusBucket'])?.toUpperCase(),
      financeReturnReason: _text(json['financeReturnReason']),
      financeReturnedAt: _text(json['financeReturnedAt']),
      financeReturnedByName: _text(json['financeReturnedByName']),
      submittedAt: _text(json['submittedAt']),
      submittedByName: _text(json['submittedByName']),
      financeConfirmedAt: _text(json['financeConfirmedAt']),
      financeConfirmedByName: _text(json['financeConfirmedByName']),
      financeRemark: _text(json['financeRemark']),
      reviewRevision: _int(json['reviewRevision']) ?? 0,
      convertedOrderId: _text(json['convertedOrderId']),
      convertedOrderNo: _text(json['convertedOrderNo']),
      hasAllowedActions: rawActions is List,
      allowedActions: rawActions is List
          ? {
              for (final action in rawActions)
                if (action != null) normalizeQuoteActionCode(action.toString()),
            }
          : const {},
      revisions: SalesQuoteRevision.listFromJson(json['revisions']),
    );
  }
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? _int(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
