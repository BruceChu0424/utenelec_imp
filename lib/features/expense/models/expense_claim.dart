// 报销单模型
// 文档：docs/04-数据模型/实体字典.md#ExpenseClaim

import '../../../core/utils/china_datetime.dart';
import '../../../shared/attachments/attachment.dart';
import 'expense_claim_event.dart';
import 'expense_invoice.dart';
import 'expense_item.dart';

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
  });

  final String id;
  final int version;
  final String? approvedBy;

  /// Immutable submitted contents. Draft/rejected edits must keep using live
  /// data until the next submission freezes a new snapshot.
  final String? previousSubmissionSnapshot;
  final String? submissionSnapshot;
  final bool resubmission;

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
      claimNo: (json['claimNo'] as String?) ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      approvedBy: json['approvedBy'] as String?,
      previousSubmissionSnapshot: json['previousSubmissionSnapshot'] as String?,
      submissionSnapshot: json['submissionSnapshot'] as String?,
      resubmission: json['resubmission'] as bool? ?? false,
      applicantId: json['applicantId'] as String,
      applicantName: json['applicantName'] as String,
      departmentId: json['departmentId'] as String?,
      departmentName: json['departmentName'] as String?,
      title: json['title'] as String,
      items: rawItems
          .map((item) => ExpenseItem.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      totalAmount: (json['totalAmount'] as num).toDouble(),
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
    ExpenseClaimStatus? status,
    DateTime? submittedAt,
    DateTime? approvedAt,
    DateTime? paidAt,
    String? rejectReason,
  }) {
    return ExpenseClaim(
      id: id,
      claimNo: claimNo,
      version: version,
      approvedBy: approvedBy,
      previousSubmissionSnapshot: previousSubmissionSnapshot,
      submissionSnapshot: submissionSnapshot,
      resubmission: resubmission,
      applicantId: applicantId,
      applicantName: applicantName,
      departmentId: departmentId,
      departmentName: departmentName,
      title: title,
      items: items,
      totalAmount: totalAmount,
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

class ExpenseClaimCreateInput {
  const ExpenseClaimCreateInput({
    required this.title,
    required this.items,
    this.remark,
    this.expectedVersion,
  });

  final int? expectedVersion;
  final String title;
  final String? remark;
  final List<ExpenseItem> items;

  Map<String, dynamic> toJson() => {
    'title': title,
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
    'remark': remark,
    'items': items.map((item) => item.toCreateJson()).toList(),
  };
}

/// 队列汇总（审批页统计卡）
class ExpenseQueueSummary {
  const ExpenseQueueSummary({
    required this.pendingCount,
    required this.pendingAmount,
    required this.payableCount,
    required this.payableAmount,
    required this.monthSubmittedCount,
    required this.monthSubmittedAmount,
    required this.monthPaidCount,
    required this.monthPaidAmount,
  });

  final int pendingCount;
  final double pendingAmount;
  final int payableCount;
  final double payableAmount;
  final int monthSubmittedCount;
  final double monthSubmittedAmount;
  final int monthPaidCount;
  final double monthPaidAmount;

  factory ExpenseQueueSummary.fromJson(Map<String, dynamic> json) =>
      ExpenseQueueSummary(
        pendingCount: (json['pendingCount'] as num?)?.toInt() ?? 0,
        pendingAmount: (json['pendingAmount'] as num?)?.toDouble() ?? 0,
        payableCount: (json['payableCount'] as num?)?.toInt() ?? 0,
        payableAmount: (json['payableAmount'] as num?)?.toDouble() ?? 0,
        monthSubmittedCount:
            (json['monthSubmittedCount'] as num?)?.toInt() ?? 0,
        monthSubmittedAmount:
            (json['monthSubmittedAmount'] as num?)?.toDouble() ?? 0,
        monthPaidCount: (json['monthPaidCount'] as num?)?.toInt() ?? 0,
        monthPaidAmount: (json['monthPaidAmount'] as num?)?.toDouble() ?? 0,
      );
}

DateTime? _dateTime(Object? value) {
  if (value == null) return null;
  return ChinaDateTime.tryParse(value as String);
}

String? _blankToNull(String? value) =>
    value == null || value.trim().isEmpty ? null : value;
