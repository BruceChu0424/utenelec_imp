// 通用下拉项构造：空占位 + 字典项 + 当前值兜底。
//
// 解决 DropdownButtonFormField 断言失败：当 initialValue 是「孤儿值」（迁移老数据里
// 不在已加载字典中的遗留 id，如某明细的 colorId/unitId/clientId）时，items 里 0 匹配会
// 触发 "zero or 2+ DropdownMenuItem with the same value" 断言，整页红屏。
// 兜底：当前值不在字典时补一条，保证恰好 1 个匹配；占位项显式 value=null 与字典项不冲突。
import 'package:flutter/material.dart';

/// 构造 String? 下拉项列表（空占位 + 字典项 + 当前值兜底）。
///
/// [value] 当前值，可能不在 [entries] 中（孤儿/老库遗留 id）。
/// [entries] id→名称 字典。[emptyLabel] 空占位文案（默认「— 不选 —」）。
List<DropdownMenuItem<String?>> stringDropdownItems(
  String? value,
  Map<String, String> entries, {
  String emptyLabel = '— 不选 —',
}) {
  return [
    DropdownMenuItem<String?>(child: Text(emptyLabel)),
    for (final e in entries.entries)
      DropdownMenuItem<String?>(
        value: e.key,
        child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    if (value != null && value.isNotEmpty && !entries.containsKey(value))
      DropdownMenuItem<String?>(
        value: value,
        child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
  ];
}
