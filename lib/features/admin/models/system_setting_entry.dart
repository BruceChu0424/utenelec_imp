// 系统设置项（GET /admin/system-settings 的 items[]）。
//
// 后端 SystemSettingDto：{ key, value, value_type, category, label, description, unit,
//   sort_order, updated_at }。value 统一字符串，按 valueType 校验/转换（本系统均为 int/long 数值）。

class SystemSettingEntry {
  const SystemSettingEntry({
    required this.key,
    required this.value,
    required this.valueType,
    required this.category,
    required this.label,
    required this.description,
    required this.unit,
    required this.sortOrder,
    required this.updatedAt,
  });

  final String key;
  final String value;
  final String valueType; // int / long / string / bool
  final String category; // security / token / sms / business
  final String label; // 中文显示名
  final String? description; // 说明（UI 提示）
  final String? unit; // 单位（次/分 / 分钟 / 天 / 秒 / 行）
  final int sortOrder;
  final String? updatedAt; // 最后修改时间（ISO 字符串）

  factory SystemSettingEntry.fromJson(Map<String, dynamic> j) =>
      SystemSettingEntry(
        key: (j['key'] ?? '').toString(),
        value: (j['value'] ?? '').toString(),
        valueType: (j['valueType'] ?? 'int').toString(),
        category: (j['category'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        description: j['description']?.toString(),
        unit: j['unit']?.toString(),
        sortOrder: (j['sortOrder'] as num?)?.toInt() ?? 0,
        updatedAt: j['updatedAt']?.toString(),
      );
}
