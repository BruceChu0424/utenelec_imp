// 报销单模型
// 文档：docs/04-数据模型/实体字典.md#ExpenseClaim

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

  /// 已驳回
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
        ExpenseClaimStatus.paid => '已打款',
      };
}

/// 报销单
class ExpenseClaim {
  const ExpenseClaim({
    required this.id,
    required this.applicantId,
    required this.applicantName,
    required this.title,
    required this.items,
    required this.totalAmount,
    required this.status,
    required this.createdAt,
    this.submittedAt,
    this.approvedAt,
    this.paidAt,
    this.remark,
    this.rejectReason,
  });

  final String id;
  final String applicantId;
  final String applicantName;

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

  /// 打款时间
  final DateTime? paidAt;

  /// 备注
  final String? remark;

  /// 驳回原因
  final String? rejectReason;

  ExpenseClaim copyWith({
    ExpenseClaimStatus? status,
    DateTime? submittedAt,
    DateTime? approvedAt,
    DateTime? paidAt,
    String? rejectReason,
  }) {
    return ExpenseClaim(
      id: id,
      applicantId: applicantId,
      applicantName: applicantName,
      title: title,
      items: items,
      totalAmount: totalAmount,
      status: status ?? this.status,
      createdAt: createdAt,
      submittedAt: submittedAt ?? this.submittedAt,
      approvedAt: approvedAt ?? this.approvedAt,
      paidAt: paidAt ?? this.paidAt,
      remark: remark,
      rejectReason: rejectReason ?? this.rejectReason,
    );
  }
}
