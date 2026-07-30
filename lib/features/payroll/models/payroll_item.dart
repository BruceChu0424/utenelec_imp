// 工资项（明细行）
// 文档：docs/04-数据模型/实体字典.md#PayrollItem

/// 工资项类型
enum PayrollItemType {
  /// 加项（应发：基本工资、加班费、奖金、补贴）
  earning,

  /// 减项（扣除：社保、公积金、个税、考勤扣款）
  deduction,
}

extension PayrollItemTypeValue on PayrollItemType {
  String get label => switch (this) {
    PayrollItemType.earning => '应发',
    PayrollItemType.deduction => '扣除',
  };

  /// 金额符号（应发为正，扣除为负）
  int get sign => switch (this) {
    PayrollItemType.earning => 1,
    PayrollItemType.deduction => -1,
  };

  String get apiValue => name.toUpperCase();

  static PayrollItemType fromApi(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    return switch (normalized) {
      'EARNING' => PayrollItemType.earning,
      'DEDUCTION' => PayrollItemType.deduction,
      _ => throw FormatException('未知工资项类型：$value'),
    };
  }
}

/// 工资项
class PayrollItem {
  const PayrollItem({
    required this.name,
    required this.amount,
    required this.type,
    this.description,
  });

  /// 项目名称（基本工资、加班费、社保、公积金、个税）
  final String name;

  /// 金额（正数）
  final double amount;

  /// 类型（应发/扣除）
  final PayrollItemType type;

  /// 说明（可选，如 "10 小时加班"）
  final String? description;

  factory PayrollItem.fromJson(Map<String, dynamic> json) => PayrollItem(
    name: json['name'] as String,
    amount: (json['amount'] as num).toDouble(),
    type: PayrollItemTypeValue.fromApi(json['type']),
    description: json['description'] as String?,
  );
}
