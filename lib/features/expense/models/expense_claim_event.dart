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
  rejected('审批驳回'),
  paid('已登记付款');

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
      'REJECTED' => ExpenseClaimEventType.rejected,
      'PAID' => ExpenseClaimEventType.paid,
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
  });

  final ExpenseClaimEventType type;

  /// 操作人姓名快照（空串兜底）
  final String actorName;

  /// 驳回原因等备注
  final String? remark;

  final DateTime occurredAt;

  factory ExpenseClaimEvent.fromJson(Map<String, dynamic> json) =>
      ExpenseClaimEvent(
        type: ExpenseClaimEventType.fromApi(json['eventType']),
        actorName: (json['actorName'] as String?)?.trim().isEmpty == true
            ? ''
            : (json['actorName'] as String?) ?? '',
        remark: json['remark'] as String?,
        occurredAt:
            ChinaDateTime.tryParse(json['occurredAt'] as String) ??
            (throw const FormatException('缺少流转记录时间')),
      );
}
