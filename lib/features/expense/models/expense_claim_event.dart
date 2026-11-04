// 报销单流转事件模型（V608）
// 文档：docs/04-数据模型/实体字典.md#ExpenseClaimEvent

import '../../../core/utils/china_datetime.dart';

/// 流转事件类型
enum ExpenseClaimEventType {
  created('创建报销单'),
  submitted('提交审批'),
  withdrawn('撤回'),
  edited('修改'),
  approved('审批通过'),
  stageApproved('节点审核通过'),
  rejected('审批驳回'),
  paid('已登记付款'),
  paymentReversed('原付款已反审'),
  abandoned('已放弃报销');

  const ExpenseClaimEventType(this.label);
  final String label;

  String get apiValue => name.toUpperCase();

  static ExpenseClaimEventType fromApi(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    return switch (normalized) {
      'CREATED' => ExpenseClaimEventType.created,
      'SUBMITTED' => ExpenseClaimEventType.submitted,
      'WITHDRAWN' => ExpenseClaimEventType.withdrawn,
      'EDITED' => ExpenseClaimEventType.edited,
      'APPROVED' => ExpenseClaimEventType.approved,
      'STAGE_APPROVED' => ExpenseClaimEventType.stageApproved,
      'REJECTED' => ExpenseClaimEventType.rejected,
      'PAID' => ExpenseClaimEventType.paid,
      'PAYMENT_REVERSED' => ExpenseClaimEventType.paymentReversed,
      'ABANDONED' => ExpenseClaimEventType.abandoned,
      _ => ExpenseClaimEventType.edited,
    };
  }
}

/// 流转事件（详情审批轨迹；操作人姓名为落库快照）
class ExpenseClaimEvent {
  const ExpenseClaimEvent({
    required this.type,
    required this.actorName,
    this.remark,
    required this.occurredAt,
    this.approvalStage,
    this.approvalRound = 0,
  });

  final ExpenseClaimEventType type;

  /// 操作人姓名快照（空串兜底）
  final String actorName;

  /// 驳回原因等备注
  final String? remark;

  final DateTime occurredAt;
  final String? approvalStage;
  final int approvalRound;

  String get displayLabel {
    final stage = switch (approvalStage) {
      'DEPARTMENT' => '部门负责人审核',
      'FINANCE_INITIAL' => '财务初核',
      'FINANCE_REVIEW' => '财务复核',
      'EXECUTIVE' => '总经办批准',
      _ => '',
    };
    return '${approvalRound > 0 ? '第$approvalRound轮 ' : ''}${stage.isEmpty ? '' : '$stage · '}${type.label}';
  }

  factory ExpenseClaimEvent.fromJson(Map<String, dynamic> json) =>
      ExpenseClaimEvent(
        type: ExpenseClaimEventType.fromApi(json['eventType']),
        actorName: (json['actorName'] as String?)?.trim().isEmpty == true
            ? ''
            : (json['actorName'] as String?) ?? '',
        remark: json['remark'] as String?,
        approvalStage: json['approvalStage'] as String?,
        approvalRound: (json['approvalRound'] as num?)?.toInt() ?? 0,
        occurredAt:
            ChinaDateTime.tryParse(json['occurredAt'] as String) ??
            (throw const FormatException('缺少流转记录时间')),
      );
}
