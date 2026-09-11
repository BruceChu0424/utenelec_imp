// 采购/委外订货单明细「供应商」单元格：outlined 只读选择格（与表头 UtenDropdownField
// 同款描边风格），点击打开供应商滑入面板（UtenSupplierPicker：分类树+搜索+可内联新建）。
// 用于逐行选不同供应商（保存时由后端按供应商自动拆单）。多选联动由页面 onPick 回调
// 决定写入范围（勾选多行时任一选中行选的供应商填到所有选中行）。
// [value] 行级供应商 id；[entries] id→名称（显示用，通常含「已禁用」补显项）；
// [fallback] 表头默认供应商（行未覆盖时显示它）；[requiredEmpty] 必填未选时提示标红；
// [autofilled] 学习预填值（黄框提醒核对；用户改选由页面清除标记）。
//
// 规格（2026-09-09 统一口径）：不自带 border/contentPadding——isDense 吃全局
// 主题（圆角/内边距与数量、单价等文本格一致），正文字号——此前 bodySmall+
// (10,8) 矮于同行其他格，整行高低不齐。
import 'package:flutter/material.dart';

import '../../components/inputs/required_field_decoration.dart';
import '../../core/theme/uten_tokens.dart';

class ProcurementSupplierCell extends StatelessWidget {
  const ProcurementSupplierCell({
    super.key,
    required this.value,
    required this.entries,
    this.fallback,
    this.onPick,
    this.requiredEmpty = false,
    this.autofilled = false,
  });

  /// 行级覆盖值（用户逐行改过才非空）。
  final String? value;

  /// 表头默认供应商：行未覆盖时显示它（保存时后端也会按表头回落）。
  final String? fallback;
  final Map<String, String> entries;

  /// 点击单元格打开供应商选择面板（页面实现：面板返回 id 后按多选范围落值）。
  final Future<void> Function()? onPick;

  /// 必填且未选：hint「必选供应商」标红（行级必填口径）。
  final bool requiredEmpty;

  /// 学习预填（/last-terms 带出上次供应商）：黄框提醒核对。
  final bool autofilled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayId = value ?? fallback;
    final hasName =
        displayId != null && (entries[displayId]?.isNotEmpty ?? false);
    final hasValue = displayId != null && displayId.isNotEmpty;
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(UtenRadius.control),
      child: InputDecorator(
        decoration: applyAutofillHint(
          applyRequiredEmpty(
            InputDecoration(
              isDense: true,
              suffixIcon: Icon(
                hasValue ? Icons.unfold_more_rounded : Icons.search_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              suffixIconConstraints: const BoxConstraints(minWidth: 20),
            ),
            theme,
            requiredEmpty: requiredEmpty,
          ),
          theme,
          autofilled: autofilled && hasValue,
        ),
        child: Text(
          hasName ? entries[displayId]! : (requiredEmpty ? '必选供应商' : '点击选择供应商'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: hasName
                ? theme.colorScheme.onSurface
                : (requiredEmpty
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
