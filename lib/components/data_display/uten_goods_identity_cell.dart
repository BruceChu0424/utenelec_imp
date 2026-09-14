import 'package:flutter/material.dart';

import 'package:uten_imp/core/theme/uten_tokens.dart';

/// 货品/物料「身份格」：名称主行 +（没有独立列的）次要属性副行。
///
/// 2026-09-14 用户口径：**所有与产品/物料相关的表格，名称 / 编号 / 颜色各占
/// 一列**。同名不同色、同名不同编号在本系统里非常普遍（V5带开关多功能三插
/// 插面 有「自制/白色 V50040」和「委外/香槟金 V20040」两条），只给名称会直接
/// 认错货；但把三者拼进一个格子同样不行——不能各自排序筛选，列窄时编号还先
/// 被省略号吃掉。**同日先做的「拼成一格」口径已退役**（见 ADR-081 §4）。
///
/// 所以现行用法是：本组件只放**名称**（外加确实没有独立列的规格/单位），
/// 编号与颜色紧跟其后各起一列，用 [UtenGoodsAttributeCell] 渲染。
/// 列的 `value`/`textOf` 必须与格内同源，否则排序、筛选桶、导出与语义标签
/// 会和眼睛看到的分叉。
///
/// ```dart
/// MasterColumnDef(key: 'goods', label: '货品名称', width: 200,
///   value: (row) => row.goodsName,
///   cellBuilderHandlesSemantics: true,
///   cellBuilder: (_, row) => UtenGoodsIdentityCell(name: row.goodsName)),
/// MasterColumnDef(key: 'goodsCode', label: '编号', width: 130,
///   value: (row) => row.goodsCode,
///   cellBuilder: (_, row) => UtenGoodsAttributeCell(row.goodsCode)),
/// MasterColumnDef(key: 'colorName', label: '颜色', width: 96,
///   value: (row) => row.colorName,
///   cellBuilder: (_, row) => UtenGoodsAttributeCell(row.colorName)),
/// ```
/// 与 [UtenGoodsIdentityCell] 配套的「编号 / 颜色」独立列单元。
///
/// 只做一件事：修剪后非空就显示，空就显示占位符（次要色）。抽出来是为了让
/// 全站几十张货品表的这两列长得一模一样——各页自己写 `Text(x ?? '—')` 时，
/// 占位词（'—' / '无' / '未维护'）与字色总会慢慢跑偏。
class UtenGoodsAttributeCell extends StatelessWidget {
  const UtenGoodsAttributeCell(
    this.value, {
    super.key,
    this.placeholder = '—',
    this.align = TextAlign.start,
  });

  final String? value;
  final String placeholder;
  final TextAlign align;

  /// 与格内同源的纯文本（列 `value`/`textOf` 用；空值返回 null 而不是占位词，
  /// 让表头筛选不把「没维护」聚成一个假桶）。
  static String? text(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clean = text(value);
    return Text(
      clean ?? placeholder,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: clean == null
            ? theme.colorScheme.onSurfaceVariant
            : theme.colorScheme.onSurface,
      ),
    );
  }
}

class UtenGoodsIdentityCell extends StatelessWidget {
  const UtenGoodsIdentityCell({
    super.key,
    required this.name,
    this.code,
    this.color,
    this.spec,
    this.unit,
    this.leading,
    this.trailing,
    this.nameMaxLines = 1,
    this.emptyPlaceholder = '—',
    this.nameStyle,
  });

  /// 货品/物料名称。空时回落到编号，再空显示 [emptyPlaceholder]。
  final String? name;

  /// 货品编号（ANumber）。
  final String? code;

  /// 颜色名称。未维护颜色的货品传 null——不要传「无」这类占位词。
  final String? color;

  /// 规格（可选，跟在编号·颜色之后）。
  final String? spec;

  /// 单位（可选，副行末位）。
  final String? unit;

  /// 名称左侧的前缀（层级徽章、展开箭头、状态点等）。
  final Widget? leading;

  /// 名称右侧的后缀（标签、警示图标等）。
  final Widget? trailing;

  /// 名称行最多几行（列窄时给 2 行避免关键字被吃掉）。
  final int nameMaxLines;

  /// 名称与编号都为空时的占位符。
  final String emptyPlaceholder;

  /// 名称行样式覆盖（默认 bodyMedium + w600）。
  final TextStyle? nameStyle;

  /// 与可视内容同源的纯文本（`value:` / 导出 / 语义标签共用）。
  ///
  /// 形如 `名称 (编号 · 颜色 · 规格)`；缺哪项就少哪项，全缺返回 null。
  static String? text({
    String? name,
    String? code,
    String? color,
    String? spec,
    String? unit,
  }) {
    final title = _clean(name) ?? _clean(code);
    final details = [
      if (_clean(name) != null) _clean(code),
      _clean(color),
      _clean(spec),
      _clean(unit),
    ].whereType<String>().toList(growable: false);
    if (title == null) return details.isEmpty ? null : details.join(' · ');
    if (details.isEmpty) return title;
    return '$title (${details.join(' · ')})';
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cleanName = _clean(name);
    final cleanCode = _clean(code);
    final title = cleanName ?? cleanCode ?? emptyPlaceholder;
    // 名称为空时编号已经顶到主行，副行不再重复一次编号。
    final details = [
      if (cleanName != null) cleanCode,
      _clean(color),
      _clean(spec),
      _clean(unit),
    ].whereType<String>().toList(growable: false);
    final titleText = Text(
      title,
      maxLines: nameMaxLines,
      overflow: TextOverflow.ellipsis,
      style:
          nameStyle ??
          theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    // 没有前后缀时**不包 Row**：多一层 Row 会让「按 Row 祖先定位整行」的既有
    // 表格用例和手势命中区错位（find.ancestor(...byType(Row)).first 会先撞上
    // 这一层），而且纯属多余的布局节点。
    final titleRow = leading == null && trailing == null
        ? titleText
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: UtenSpacing.s4),
              ],
              Flexible(child: titleText),
              if (trailing != null) ...[
                const SizedBox(width: UtenSpacing.s4),
                trailing!,
              ],
            ],
          );
    final semanticsLabel =
        text(name: name, code: code, color: color, spec: spec, unit: unit) ??
        emptyPlaceholder;
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            titleRow,
            if (details.isNotEmpty)
              Text(
                details.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
