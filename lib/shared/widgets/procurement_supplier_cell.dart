// 采购/委外订货单明细「供应商」单元格：紧凑下拉。
// 用于逐行选不同供应商（保存时由后端按供应商自动拆单）。供应商字典可能数百条，
// 下拉可滚动；孤儿值（不在字典）回退为空，避免 DropdownButtonFormField 断言。
// 行未覆盖(value 空)时显示表头 fallback；DropdownButtonFormField 自管选中态。
import 'package:flutter/material.dart';

class ProcurementSupplierCell extends StatelessWidget {
  const ProcurementSupplierCell({
    super.key,
    required this.value,
    required this.entries,
    this.fallback,
    this.onChanged,
  });

  /// 行级覆盖值（用户逐行改过才非空）。
  final String? value;

  /// 表头默认供应商：行未覆盖时显示它（保存时后端也会按表头回落）。
  final String? fallback;
  final Map<String, String> entries;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String? resolve(String? candidate) =>
        (candidate != null && entries.containsKey(candidate))
        ? candidate
        : null;
    final initial = resolve(value) ?? resolve(fallback);
    return DropdownButtonFormField<String?>(
      initialValue: initial,
      isExpanded: true,
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      ),
      hint: Text('选供应商', style: theme.textTheme.bodySmall),
      items: [
        for (final entry in entries.entries)
          DropdownMenuItem<String?>(
            value: entry.key,
            child: Text(
              entry.value,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
