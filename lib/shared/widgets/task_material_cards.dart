// 任务直属物料的逐种卡片列表：「我的车间任务」与「委外任务中心」物料弹窗共用的唯一入口。
//
// 每张卡片一种物料：勾选框(可领才可勾) + 名称 / 编号·颜色 / 状态胶囊 + 关键数量(需求、
// 已领、可领、缺口) + 展开的到料明细(仓库可用等)。数量都是服务端逐种事实的显示文本，
// 本组件不做任何换算；业务差异(车间的直送/子件工单、委外的供应来源/每套用量)由调用方
// 组装成 [TaskMaterialEntry] 传入。
import 'package:flutter/material.dart';

import '../../components/data_display/uten_status_badge.dart';
import '../../components/data_display/uten_status_cell_color.dart';
import '../../components/inputs/uten_field_hint_icon.dart';
import '../../components/layout/uten_collapsible_content.dart';
import '../../components/layout/uten_table_column_kit.dart'
    show utenTableSelectedRowColor;
import '../../core/theme/uten_tokens.dart';

/// 一条数量事实：标签 + 已格式化的值。[hint] 非空时值后挂提示 icon(悬停说明)。
class TaskMaterialFact {
  const TaskMaterialFact(
    this.label,
    this.value, {
    this.error = false,
    this.hint,
    this.selectionOnly = false,
  });

  final String label;
  final String value;

  /// 错误态(缺口 > 0)：标签与值转错误色。
  final bool error;
  final String? hint;

  /// 只在可勾选(去领料)时显示，如「可领」。
  final bool selectionOnly;
}

/// 一种物料的卡片内容(调用方从各自的服务端事实组装)。
class TaskMaterialEntry {
  const TaskMaterialEntry({
    required this.id,
    required this.goodsName,
    required this.goodsCode,
    required this.stateLabel,
    required this.stateType,
    this.colorName,
    this.stateIcon,
    this.sourceLabel,
    this.headline = const [],
    this.details = const [],
    this.footnotes = const [],
  });

  /// 行身份(车间需求 id / 委外计划行 id)，也是勾选身份。
  final String id;
  final String goodsName;
  final String goodsCode;
  final String? colorName;
  final String stateLabel;
  final UtenStatusBadgeType stateType;
  final IconData? stateIcon;

  /// 来源一行(可勾选时显示在身份下面)，如「采购 · 仓库领料」。
  final String? sourceLabel;

  /// 卡片上常显的关键数量。
  final List<TaskMaterialFact> headline;

  /// 「到料明细」展开后的数量事实。
  final List<TaskMaterialFact> details;

  /// 展开区末尾的说明行：(文字, 是否次级色)。
  final List<(String, bool)> footnotes;
}

/// 逐种物料卡片列表。[keyPrefix] / [selectKeyPrefix] 决定测试与无障碍定位用的 key
/// (`$keyPrefix-table`、`$keyPrefix-row-$id`、`$keyPrefix-state-$id`、
/// `$keyPrefix-details-$id`、`$keyPrefix-toggle-all`、`$selectKeyPrefix-$id`)。
class TaskMaterialCards extends StatefulWidget {
  const TaskMaterialCards({
    super.key,
    required this.entries,
    required this.keyPrefix,
    required this.selectKeyPrefix,
    this.scrollable = false,
    this.showAllInitially = false,
    this.selectableIds = const {},
    this.selectedIds = const {},
    this.onSelectedIdsChanged,
  });

  final List<TaskMaterialEntry> entries;
  final String keyPrefix;
  final String selectKeyPrefix;

  /// 有界视口(弹窗)里只挂载进入视区的卡片。
  final bool scrollable;

  /// 默认只展示第一种物料，其余用「展开查看全部物料」；弹窗里一次全展示。
  final bool showAllInitially;
  final Set<String> selectableIds;
  final Set<String> selectedIds;

  /// 为空 = 只读(不出勾选框、不出「可领」)。
  final ValueChanged<Set<String>>? onSelectedIdsChanged;

  @override
  State<TaskMaterialCards> createState() => _TaskMaterialCardsState();
}

class _TaskMaterialCardsState extends State<TaskMaterialCards> {
  final Set<String> _expandedIds = {};
  late bool _showAll = widget.showAllInitially;

  @override
  Widget build(BuildContext context) {
    final rows = widget.entries;
    final visibleRows = _showAll ? rows : rows.take(1).toList();
    if (widget.scrollable) {
      return ListView.separated(
        key: Key('${widget.keyPrefix}-table'),
        padding: EdgeInsets.zero,
        itemCount: visibleRows.length,
        separatorBuilder: (_, _) => const SizedBox(height: UtenSpacing.s8),
        itemBuilder: (context, index) => _card(context, visibleRows[index]),
      );
    }
    return Column(
      key: Key('${widget.keyPrefix}-table'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < visibleRows.length; index++) ...[
          if (index > 0) const SizedBox(height: UtenSpacing.s8),
          _card(context, visibleRows[index]),
        ],
        if (rows.length > 1 && !widget.showAllInitially) ...[
          const SizedBox(height: UtenSpacing.s12),
          FilledButton.tonalIcon(
            key: Key('${widget.keyPrefix}-toggle-all'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, UtenSpacing.s48),
            ),
            onPressed: () => setState(() {
              _showAll = !_showAll;
              if (!_showAll) _expandedIds.clear();
            }),
            icon: Icon(
              _showAll ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            ),
            label: Text(_showAll ? '收起物料' : '展开查看全部物料（共 ${rows.length} 项）'),
          ),
        ],
      ],
    );
  }

  Widget _card(BuildContext context, TaskMaterialEntry row) {
    final theme = Theme.of(context);
    final prefix = widget.keyPrefix;
    final expanded = _expandedIds.contains(row.id);
    final identity = [
      row.goodsCode,
      if (row.colorName?.trim().isNotEmpty == true) row.colorName!,
    ].where((value) => value.isNotEmpty).join(' · ');
    final selectionEnabled = widget.onSelectedIdsChanged != null;
    final selectable = widget.selectableIds.contains(row.id);
    final selected = widget.selectedIds.contains(row.id);
    void toggleSelection(bool? value) {
      if (!selectable) return;
      final next = Set<String>.of(widget.selectedIds);
      if (value == true) {
        next.add(row.id);
      } else {
        next.remove(row.id);
      }
      widget.onSelectedIdsChanged?.call(next);
    }

    return Container(
      key: ValueKey('$prefix-row-${row.id}'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: selected ? utenTableSelectedRowColor(theme) : null,
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final identityContent = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.goodsName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Wrap(
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (identity.isNotEmpty)
                        Text(
                          identity,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      TaskMaterialStateCell(
                        key: ValueKey('$prefix-state-${row.id}'),
                        label: row.stateLabel,
                        icon: row.stateIcon,
                        type: row.stateType,
                      ),
                    ],
                  ),
                  if (selectionEnabled &&
                      row.sourceLabel?.isNotEmpty == true) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text(row.sourceLabel!, style: theme.textTheme.bodySmall),
                  ],
                ],
              );
              final identityBlock = selectionEnabled
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          key: ValueKey('${widget.selectKeyPrefix}-${row.id}'),
                          value: selected,
                          semanticLabel: '选择${row.goodsName}',
                          onChanged: selectable ? toggleSelection : null,
                        ),
                        const SizedBox(width: UtenSpacing.s4),
                        Expanded(child: identityContent),
                      ],
                    )
                  : identityContent;
              final facts = [
                for (final fact in row.headline)
                  if (selectionEnabled || !fact.selectionOnly) fact,
              ];
              final quantities = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var index = 0; index < facts.length; index++) ...[
                    if (index > 0) const SizedBox(width: UtenSpacing.s8),
                    Expanded(child: _headlineFact(context, facts[index])),
                  ],
                ],
              );
              final detailsButton = TextButton.icon(
                key: ValueKey('$prefix-details-${row.id}'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s4,
                    vertical: UtenSpacing.s4,
                  ),
                ),
                onPressed: () => setState(() {
                  if (expanded) {
                    _expandedIds.remove(row.id);
                  } else {
                    _expandedIds.add(row.id);
                  }
                }),
                icon: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                label: const Text('到料明细'),
              );
              if (constraints.maxWidth >= 600) {
                return Row(
                  children: [
                    Expanded(flex: 4, child: identityBlock),
                    const SizedBox(width: UtenSpacing.s16),
                    Expanded(flex: 3, child: quantities),
                    const SizedBox(width: UtenSpacing.s8),
                    detailsButton,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  identityBlock,
                  const SizedBox(height: UtenSpacing.s8),
                  quantities,
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: detailsButton,
                  ),
                ],
              );
            },
          ),
          UtenCollapsibleContent(
            expanded: expanded,
            maintainState: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: UtenSpacing.s12),
                _details(context, row),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _headlineFact(BuildContext context, TaskMaterialFact fact) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          fact.label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: fact.error
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s2),
        Text(
          fact.value,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: fact.error ? theme.colorScheme.error : null,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _details(BuildContext context, TaskMaterialEntry row) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: UtenSpacing.s16,
          runSpacing: UtenSpacing.s6,
          children: [
            for (final fact in row.details)
              if (fact.hint case final hint?)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        '${fact.label} ${fact.value}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    UtenFieldHintIcon(info: hint, dense: true),
                  ],
                )
              else
                Text(
                  '${fact.label} ${fact.value}',
                  style: theme.textTheme.bodySmall,
                ),
          ],
        ),
        for (var index = 0; index < row.footnotes.length; index++) ...[
          SizedBox(height: index == 0 ? UtenSpacing.s8 : UtenSpacing.s4),
          Text(
            row.footnotes[index].$1,
            style: row.footnotes[index].$2
                ? theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// 物料状态格：徽章同源底色铺满格内容区（2026-09-27 用户口径「格内胶囊改单元格
/// 背景色」；带 0.5 描边的实色块，描边即「背景变色但边框要还在」）。文字用徽章深档色
/// 保证对比度，无圆角——读作整格着色而非胶囊。车间与委外的逐种物料表、卡片共用。
class TaskMaterialStateCell extends StatelessWidget {
  const TaskMaterialStateCell({
    super.key,
    required this.label,
    required this.type,
    this.icon,
  });

  final String label;
  final UtenStatusBadgeType type;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (bg, fg) = resolveStatusBadgeColors(type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: theme.colorScheme.outline, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
