import '../../../shared/formatters/exact_decimal.dart';
// 报销单模型
// 文档：docs/04-数据模型/实体字典.md#ExpenseClaim

import '../../../core/utils/china_datetime.dart';
import '../../../shared/attachments/attachment.dart';
import 'expense_claim_event.dart';
import 'expense_invoice.dart';
import 'expense_item.dart';

/// 同一份节点契约用于申请人进度、部门/财务/总经办待办及纸面签批。
enum ExpenseApprovalStage {
  department('DEPARTMENT', '部门负责人审核'),
  financeInitial('FINANCE_INITIAL', '财务初核'),
  financeReview('FINANCE_REVIEW', '财务复核'),
  executive('EXECUTIVE', '总经办批准');

  const ExpenseApprovalStage(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static ExpenseApprovalStage? fromApi(Object? value) {
    if (value == null || value.toString().isEmpty) return null;
    return values.where((stage) => stage.apiValue == value).firstOrNull;
  }
}

/// 报销单状态
enum ExpenseClaimStatus {
  /// 草稿
  draft,

  /// 已提交（等待审批）
  submitted,

  /// 审批中
  reviewing,

  /// 已通过（等待打款）
  approved,

  /// 已驳回（可修订后重新提交，V608）
  rejected,

  /// 已打款
  paid,
}

extension ExpenseClaimStatusValue on ExpenseClaimStatus {
  String get label => switch (this) {
    ExpenseClaimStatus.draft => '草稿',
    ExpenseClaimStatus.submitted => '待审批',
    ExpenseClaimStatus.reviewing => '审批中',
    ExpenseClaimStatus.approved => '已通过',
    ExpenseClaimStatus.rejected => '已驳回',
    ExpenseClaimStatus.paid => '已付款',
  };

  String get apiValue => name.toUpperCase();

  static ExpenseClaimStatus fromApi(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    return switch (normalized) {
      'DRAFT' => ExpenseClaimStatus.draft,
      'SUBMITTED' => ExpenseClaimStatus.submitted,
      'REVIEWING' => ExpenseClaimStatus.reviewing,
      'APPROVED' => ExpenseClaimStatus.approved,
      'REJECTED' => ExpenseClaimStatus.rejected,
      'PAID' => ExpenseClaimStatus.paid,
      _ => throw FormatException('未知报销状态：$value'),
    };
  }
}

/// 报销单
class ExpenseClaim {
  const ExpenseClaim({
    required this.id,
    required this.claimNo,
    required this.applicantId,
    required this.applicantName,
    required this.title,
    required this.items,
    required this.totalAmount,
    this.totalAmountExact,
    required this.status,
    required this.createdAt,
    this.departmentId,
    this.departmentName,
    this.submittedAt,
    this.approvedAt,
    this.rejectedAt,
    this.paidAt,
    this.remark,
    this.rejectReason,
    this.approvedByName,
    this.rejectedByName,
    this.paidByName,
    this.paymentDate,
    this.paymentAccountName,
    this.paymentExpenseStyleName,
    this.financeExpenseId,
    this.attachments = const [],
    this.paymentProofs = const [],
    this.invoices = const [],
    this.events = const [],
    this.version = 0,
    this.approvedBy,
    this.previousSubmissionSnapshot,
    this.submissionSnapshot,
    this.resubmission = false,
    this.financialApplication,
    this.applicationKind,
    this.travelApplicationId,
    this.travelApplicationSourceKind,
    this.approvalStage,
    this.approvalStageLabel,
    this.approvalRound = 0,
    this.canApprove,
    this.canPay,
    this.expenseKind = 'GENERAL',
    this.approvalRoutingStale = false,
    this.abandoned = false,
  });

  final String id;
  final String? applicationKind,
      travelApplicationId,
      travelApplicationSourceKind;
  final ExpenseClaimFinancialApplication? financialApplication;
  final int version;
  final String? approvedBy;

  /// Immutable submitted contents. Draft/rejected edits must keep using live
  /// data until the next submission freezes a new snapshot.
  final String? previousSubmissionSnapshot;
  final String? submissionSnapshot;
  final bool resubmission;
  final ExpenseApprovalStage? approvalStage;
  final String? approvalStageLabel;
  final int approvalRound;

  /// 服务端按当前节点、部门、只读身份与经办隔离计算；旧响应缺省为空。
  final bool? canApprove;
  final bool? canPay;
  final String expenseKind;
  final bool approvalRoutingStale;
  final bool abandoned;
  String get expenseKindLabel => expenseKind == 'TRAVEL' ? '出差报销' : '费用报销';

  String? get effectiveStageLabel =>
      _blankToNull(approvalStageLabel) ?? approvalStage?.label;

  String get progressLabel => abandoned
      ? '已放弃'
      : approvalRoutingStale
      ? '待重新提交'
      : (status == ExpenseClaimStatus.submitted ||
                status == ExpenseClaimStatus.reviewing) &&
            effectiveStageLabel != null
      ? '待${effectiveStageLabel!}'
      : status.label;

  /// 报销单号（BX + 日期 + 流水；V608 打印与归档编号）
  final String claimNo;

  final String applicantId;
  final String applicantName;

  /// 申请人部门（提交时快照 id / 部门名，2026-09-10 审批列表「部门」列与表头筛选）
  final String? departmentId;
  final String? departmentName;

  /// 报销单标题
  final String title;

  /// 报销项明细
  final List<ExpenseItem> items;

  /// 总金额
  final double totalAmount;
  final String? totalAmountExact;
  String get totalAmountText =>
      financeExactTrimmed(totalAmountExact ?? totalAmount.toString())!;

  /// 状态
  final ExpenseClaimStatus status;

  /// 创建时间
  final DateTime createdAt;

  /// 提交时间
  final DateTime? submittedAt;

  /// 审批通过时间
  final DateTime? approvedAt;

  /// 驳回时间（V608 补齐回显）
  final DateTime? rejectedAt;

  /// 付款登记时间(实际付款日期另见 paymentDate)。
  final DateTime? paidAt;

  /// 备注
  final String? remark;

  /// 驳回原因
  final String? rejectReason;

  /// 审批人姓名（V608 回显）
  final String? approvedByName;

  /// 驳回人姓名
  final String? rejectedByName;

  /// 打款人姓名
  final String? paidByName;

  /// 打款信息（V608 回显：日期 / 账户 / 费别 / 关联财务费用单）
  final DateTime? paymentDate;
  final String? paymentAccountName;
  final String? paymentExpenseStyleName;
  final String? financeExpenseId;

  /// 附件（发票影像等）；详情接口返回，列表接口可能为空
  final List<Attachment> attachments;
  final List<Attachment> paymentProofs;

  /// 发票登记（结构化要素；详情接口返回）
  final List<ExpenseClaimInvoice> invoices;

  /// 流转事件（审批轨迹；详情接口返回）
  final List<ExpenseClaimEvent> events;

  factory ExpenseClaim.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return ExpenseClaim(
      id: json['id'] as String,
      applicationKind: json['applicationKind'] as String?,
      travelApplicationId: json['travelApplicationId'] as String?,
      travelApplicationSourceKind:
          json['travelApplicationSourceKind'] as String?,
      financialApplication: json['financialApplication'] is Map
          ? ExpenseClaimFinancialApplication.fromJson(
              Map<String, dynamic>.from(json['financialApplication'] as Map),
            )
          : null,
      claimNo: (json['claimNo'] as String?) ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      approvedBy: json['approvedBy'] as String?,
      previousSubmissionSnapshot: json['previousSubmissionSnapshot'] as String?,
      submissionSnapshot: json['submissionSnapshot'] as String?,
      resubmission: json['resubmission'] as bool? ?? false,
      approvalStage: ExpenseApprovalStage.fromApi(json['approvalStage']),
      approvalStageLabel: json['approvalStageLabel'] as String?,
      approvalRound: (json['approvalRound'] as num?)?.toInt() ?? 0,
      canApprove: json['canApprove'] as bool?,
      canPay: json['canPay'] as bool?,
      expenseKind: json['expenseKind'] == 'TRAVEL' ? 'TRAVEL' : 'GENERAL',
      approvalRoutingStale: json['approvalRoutingStale'] == true,
      abandoned: json['abandoned'] == true,
      applicantId: json['applicantId'] as String,
      applicantName: json['applicantName'] as String,
      departmentId: json['departmentId'] as String?,
      departmentName: json['departmentName'] as String?,
      title: json['title'] as String,
      items: rawItems
          .map((item) => ExpenseItem.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      totalAmount: double.parse(
        financeExactDecimal(json['totalAmountExact'] ?? json['totalAmount'])!,
      ),
      totalAmountExact: financeExactDecimal(
        json['totalAmountExact'] ?? json['totalAmount'],
      ),
      status: ExpenseClaimStatusValue.fromApi(json['status']),
      createdAt: ChinaDateTime.tryParse(json['createdAt'] as String)!,
      submittedAt: _dateTime(json['submittedAt']),
      approvedAt: _dateTime(json['approvedAt']),
      rejectedAt: _dateTime(json['rejectedAt']),
      paidAt: _dateTime(json['paidAt']),
      remark: json['remark'] as String?,
      rejectReason: json['rejectReason'] as String?,
      approvedByName: _blankToNull(json['approvedByName'] as String?),
      rejectedByName: _blankToNull(json['rejectedByName'] as String?),
      paidByName: _blankToNull(json['paidByName'] as String?),
      paymentDate:
          json['paymentDate'] is String &&
              (json['paymentDate'] as String).isNotEmpty
          ? DateTime.tryParse(json['paymentDate'] as String)
          : null,
      paymentAccountName: _blankToNull(json['paymentAccountName'] as String?),
      paymentExpenseStyleName: _blankToNull(
        json['paymentExpenseStyleName'] as String?,
      ),
      financeExpenseId: json['financeExpenseId'] as String?,
      paymentProofs: (json['paymentProofs'] as List<dynamic>? ?? const [])
          .map((value) => Attachment.fromJson(value as Map<String, dynamic>))
          .toList(growable: false),
      attachments: (json['attachments'] as List<dynamic>? ?? const [])
          .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      invoices: (json['invoices'] as List<dynamic>? ?? const [])
          .map((e) => ExpenseClaimInvoice.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      events: (json['events'] as List<dynamic>? ?? const [])
          .map((e) => ExpenseClaimEvent.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  ExpenseClaim copyWith({
    List<ExpenseItem>? items,
    ExpenseClaimStatus? status,
    DateTime? submittedAt,
    DateTime? approvedAt,
    DateTime? paidAt,
    String? rejectReason,
  }) {
    return ExpenseClaim(
      id: id,
      financialApplication: financialApplication,
      applicationKind: applicationKind,
      travelApplicationId: travelApplicationId,
      travelApplicationSourceKind: travelApplicationSourceKind,
      claimNo: claimNo,
      version: version,
      approvedBy: approvedBy,
      previousSubmissionSnapshot: previousSubmissionSnapshot,
      submissionSnapshot: submissionSnapshot,
      resubmission: resubmission,
      approvalStage: approvalStage,
      approvalStageLabel: approvalStageLabel,
      approvalRound: approvalRound,
      canApprove: canApprove,
      canPay: canPay,
      expenseKind: expenseKind,
      approvalRoutingStale: approvalRoutingStale,
      abandoned: abandoned,
      applicantId: applicantId,
      applicantName: applicantName,
      departmentId: departmentId,
      departmentName: departmentName,
      title: title,
      items: items ?? this.items,
      totalAmount: totalAmount,
      totalAmountExact: totalAmountExact,
      status: status ?? this.status,
      createdAt: createdAt,
      submittedAt: submittedAt ?? this.submittedAt,
      approvedAt: approvedAt ?? this.approvedAt,
      rejectedAt: rejectedAt,
      paidAt: paidAt ?? this.paidAt,
      remark: remark,
      rejectReason: rejectReason ?? this.rejectReason,
      approvedByName: approvedByName,
      rejectedByName: rejectedByName,
      paidByName: paidByName,
      paymentDate: paymentDate,
      paymentAccountName: paymentAccountName,
      paymentExpenseStyleName: paymentExpenseStyleName,
      financeExpenseId: financeExpenseId,
      attachments: attachments,
      paymentProofs: paymentProofs,
      invoices: invoices,
      events: events,
    );
  }
}

class ExpenseClaimFinancialApplication {
  const ExpenseClaimFinancialApplication({
    required this.id,
    required this.applicationNo,
    required this.kind,
    required this.status,
    required this.currentStep,
    required this.canOpen,
  });
  final String id, applicationNo, kind, status, currentStep;
  final bool canOpen;
  factory ExpenseClaimFinancialApplication.fromJson(
    Map<String, dynamic> json,
  ) => ExpenseClaimFinancialApplication(
    id: json['id']?.toString() ?? '',
    applicationNo: json['applicationNo']?.toString() ?? '',
    kind: json['kind']?.toString() ?? '',
    status: json['status']?.toString() ?? '',
    currentStep: json['currentStep']?.toString() ?? '',
    canOpen: json['canOpen'] == true,
  );
}

class ExpenseClaimCreateInput {
  const ExpenseClaimCreateInput({
    required this.title,
    required this.items,
    this.remark,
    this.expectedVersion,
    this.applicationKind,
    this.travelApplicationId,
    this.travelApplicationSourceKind,
    this.expenseKind = 'GENERAL',
  });

  final int? expectedVersion;
  final String? applicationKind,
      travelApplicationId,
      travelApplicationSourceKind;
  final String expenseKind;
  final String title;
  final String? remark;
  final List<ExpenseItem> items;

  Map<String, dynamic> toJson() => {
    'title': title,
    'expenseKind': expenseKind,
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
    'remark': remark,
    'applicationKind': ?applicationKind,
    'travelApplicationId': ?travelApplicationId,
    'travelApplicationSourceKind': ?travelApplicationSourceKind,
    'items': items.map((item) => item.toCreateJson()).toList(),
  };
}

/// 队列汇总（审批页统计卡）
class ExpenseQueueSummary {
  const ExpenseQueueSummary({
    required this.pendingCount,
    required this.pendingAmount,
    this.pendingAmountExact,
    required this.payableCount,
    required this.payableAmount,
    this.payableAmountExact,
    required this.monthSubmittedCount,
    required this.monthSubmittedAmount,
    this.monthSubmittedAmountExact,
    required this.monthPaidCount,
    required this.monthPaidAmount,
    this.monthPaidAmountExact,
    this.actionablePendingCount = 0,
    this.actionablePayableCount = 0,
  });

  final int pendingCount;
  final double pendingAmount;
  final String? pendingAmountExact;
  String get pendingAmountText =>
      financeExactTrimmed(pendingAmountExact ?? pendingAmount.toString())!;
  final int payableCount;
  final double payableAmount;
  final String? payableAmountExact;
  String get payableAmountText =>
      financeExactTrimmed(payableAmountExact ?? payableAmount.toString())!;
  final int monthSubmittedCount;
  final double monthSubmittedAmount;
  final String? monthSubmittedAmountExact;
  String get monthSubmittedAmountText => financeExactTrimmed(
    monthSubmittedAmountExact ?? monthSubmittedAmount.toString(),
  )!;
  final int monthPaidCount;
  final double monthPaidAmount;
  final String? monthPaidAmountExact;
  String get monthPaidAmountText =>
      financeExactTrimmed(monthPaidAmountExact ?? monthPaidAmount.toString())!;
  final int actionablePendingCount;
  final int actionablePayableCount;

  factory ExpenseQueueSummary.fromJson(Map<String, dynamic> json) =>
      ExpenseQueueSummary(
        pendingCount: (json['pendingCount'] as num?)?.toInt() ?? 0,
        pendingAmount:
            double.tryParse(
              financeExactDecimal(
                    json['pendingAmountExact'] ?? json['pendingAmount'],
                  ) ??
                  '',
            ) ??
            0,
        pendingAmountExact: financeExactDecimal(
          json['pendingAmountExact'] ?? json['pendingAmount'],
        ),
        payableCount: (json['payableCount'] as num?)?.toInt() ?? 0,
        payableAmount:
            double.tryParse(
              financeExactDecimal(
                    json['payableAmountExact'] ?? json['payableAmount'],
                  ) ??
                  '',
            ) ??
            0,
        payableAmountExact: financeExactDecimal(
          json['payableAmountExact'] ?? json['payableAmount'],
        ),
        monthSubmittedCount:
            (json['monthSubmittedCount'] as num?)?.toInt() ?? 0,
        monthSubmittedAmount:
            double.tryParse(
              financeExactDecimal(
                    json['monthSubmittedAmountExact'] ??
                        json['monthSubmittedAmount'],
                  ) ??
                  '',
            ) ??
            0,
        monthSubmittedAmountExact: financeExactDecimal(
          json['monthSubmittedAmountExact'] ?? json['monthSubmittedAmount'],
        ),
        monthPaidCount: (json['monthPaidCount'] as num?)?.toInt() ?? 0,
        monthPaidAmount:
            double.tryParse(
              financeExactDecimal(
                    json['monthPaidAmountExact'] ?? json['monthPaidAmount'],
                  ) ??
                  '',
            ) ??
            0,
        monthPaidAmountExact: financeExactDecimal(
          json['monthPaidAmountExact'] ?? json['monthPaidAmount'],
        ),
        actionablePendingCount:
            (json['actionablePendingCount'] as num?)?.toInt() ?? 0,
        actionablePayableCount:
            (json['actionablePayableCount'] as num?)?.toInt() ?? 0,
      );
}

DateTime? _dateTime(Object? value) {
  if (value == null) return null;
  return ChinaDateTime.tryParse(value as String);
}

String? _blankToNull(String? value) =>
    value == null || value.trim().isEmpty ? null : value;
