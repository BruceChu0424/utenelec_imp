import 'package:flutter/material.dart';

import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/layout/uten_table_column_kit.dart';
import '../../../core/theme/uten_tokens.dart';
import 'master_data_table_view.dart';

/// 「大小屏共用一张表」的窄屏半边（2026-09-29 用户口径：改一处列定义，宽屏
/// 表格与窄屏卡片同时生效，页面不再各自维护一套手机卡片）。
///
/// 由 [MasterDataTableView] 在 `compactCards: true` 且屏宽进入 compact 断点
/// （<600，UtenBreakpoints）时启用的表体替身：同一份 [MasterColumnDef] 驱动，
/// 列的 [MasterColumnDef.cardRole] 决定它在卡片上的角色——
/// · title：卡片标题（默认第一可见列自动担任）；
/// · subtitle：标题下小字副行（多列用 · 连接）；
/// · hidden：不进卡片（表格里照常显示）；
/// · 其余列：`标签 值` 明细行；带 cellColor 的列渲染成带描边的语义色块
///   （与表格整格底色同语言，非胶囊）。
///
/// 行交互与表格同语义：勾选框=多选、点卡片=打开（手机上没有双击）、
/// 长按/右击=行菜单。翻页/合计条/工具条/空态等壳仍由 MasterDataTableView
/// 自己承担，本组件只替掉「表头+数据行」这一段。
class MasterDataCardList<T> extends StatelessWidget {
  const MasterDataCardList({
    super.key,
    required this.columns,
    required this.items,
    required this.primary,
    required this.loadingMore,
    this.controller,
    this.isSelected,
    this.canSelect,
    this.onCheckboxChanged,
    this.onOpen,
    this.rowMenuBuilder,
    this.onMenuOpening,
    this.onActionCompleted,
    this.bottomPadding = UtenSpacing.s8,
    this.header,
  });

  /// 可见且有序的列（MasterDataTableView._visibleIndices 的产物）。
  final List<MasterColumnDef<T>> columns;

  final List<T> items;

  /// 联动折叠模式：卡片列表用 primary ListView 交还 PrimaryScrollController。
  final bool primary;

  final bool loadingMore;
  final ScrollController? controller;
  final bool Function(T item)? isSelected;
  final bool Function(T item)? canSelect;
  final void Function(T item, bool checked)? onCheckboxChanged;
  final void Function(T item)? onOpen;

  /// 行菜单条目构建器（含 canShowRowMenu 门控后的产物；null=无菜单）。
  final List<UtenContextMenuEntry> Function(T item)? rowMenuBuilder;

  /// 弹菜单前把该行置为选中（与表格行同语义）。
  final void Function(T item)? onMenuOpening;

  /// 菜单动作完成后清理选中（与表格行同语义）。
  final Future<void> Function()? onActionCompleted;

  /// 列表底部留白（悬浮胶囊避让等，宿主经 bottomContentPadding 传入）。
  final double bottomPadding;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && !loadingMore && header == null) {
      return const SizedBox.shrink();
    }
    return ListView.builder(
      controller: controller,
      primary: primary,
      shrinkWrap: !primary,
      physics: primary
          ? const AlwaysScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      padding: EdgeInsets.only(
        left: UtenSpacing.s4,
        right: UtenSpacing.s4,
        bottom: bottomPadding,
      ),
      itemCount:
          items.length + (loadingMore ? 1 : 0) + (header == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (header != null && index == 0) return header!;
        final itemIndex = index - (header == null ? 0 : 1);
        if (itemIndex == items.length) {
          return const Padding(
            padding: EdgeInsets.all(UtenSpacing.s12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final item = items[itemIndex];
        return _Card<T>(
          columns: columns,
          item: item,
          isSelected: isSelected?.call(item) ?? false,
          checkboxEnabled: canSelect?.call(item) ?? true,
          onCheckboxChanged: onCheckboxChanged,
          onOpen: onOpen,
          rowMenuBuilder: rowMenuBuilder,
          onMenuOpening: onMenuOpening,
          onActionCompleted: onActionCompleted,
        );
      },
    );
  }
}

class _Card<T> extends StatelessWidget {
  const _Card({
    required this.columns,
    required this.item,
    required this.isSelected,
    required this.checkboxEnabled,
    this.onCheckboxChanged,
    this.onOpen,
    this.rowMenuBuilder,
    this.onMenuOpening,
    this.onActionCompleted,
  });

  final List<MasterColumnDef<T>> columns;
  final T item;
  final bool isSelected;
  final bool checkboxEnabled;
  final void Function(T item, bool checked)? onCheckboxChanged;
  final void Function(T item)? onOpen;
  final List<UtenContextMenuEntry> Function(T item)? rowMenuBuilder;
  final void Function(T item)? onMenuOpening;
  final Future<void> Function()? onActionCompleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectable = onCheckboxChanged != null;

    // 角色分派：显式 cardRole 优先；缺省第一可见列=标题、无副行。
    final titleIndex = columns.indexWhere(
      (c) => c.cardRole == MasterColumnCardRole.title,
    );
    final effectiveTitle = titleIndex >= 0 ? titleIndex : 0;
    final subtitleColumns = columns
        .where((c) => c.cardRole == MasterColumnCardRole.subtitle)
        .toList();
    final detailColumns = <MasterColumnDef<T>>[
      for (var i = 0; i < columns.length; i++)
        if (i != effectiveTitle &&
            columns[i].cardRole != MasterColumnCardRole.subtitle &&
            columns[i].cardRole != MasterColumnCardRole.hidden)
          columns[i],
    ];

    final title = columns[effectiveTitle].value(item) ?? '—';
    final subtitle = [
      for (final c in subtitleColumns)
        if ((c.value(item) ?? '').trim().isNotEmpty) c.value(item)!.trim(),
    ].join(' · ');

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (selectable) ...[
              SizedBox(
                width: 40,
                height: 40,
                child: Checkbox(
                  value: isSelected,
                  onChanged: checkboxEnabled
                      ? (value) => onCheckboxChanged!(item, value ?? false)
                      : null,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
            ],
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (rowMenuBuilder != null)
              Builder(
                builder: (buttonContext) => IconButton(
                  tooltip: '操作',
                  icon: const Icon(Icons.more_vert_rounded),
                  onPressed: () async {
                    final entries = rowMenuBuilder!(item);
                    if (entries.isEmpty) return;
                    onMenuOpening?.call(item);
                    final box = buttonContext.findRenderObject() as RenderBox;
                    final result = await showUtenContextMenu(
                      buttonContext,
                      globalPosition: box.localToGlobal(
                        Offset(box.size.width, box.size.height),
                      ),
                      entries: entries,
                    );
                    if (result == UtenContextMenuCloseReason.actionCompleted) {
                      await onActionCompleted?.call();
                    }
                  },
                ),
              ),
          ],
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (detailColumns.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            children: [
              for (final column in detailColumns)
                _detail(context, theme, column),
            ],
          ),
        ],
      ],
    );

    final card = Container(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: isSelected ? utenTableSelectedRowColor(theme) : null,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: body,
    );

    final open = onOpen;
    final menu = rowMenuBuilder;
    if (open == null && menu == null) return card;
    if (menu == null) {
      return InkWell(
        onTap: open == null ? null : () => open(item),
        child: card,
      );
    }
    return UtenContextMenuRegion(
      entriesBuilder: () => menu(item),
      onMenuOpening: onMenuOpening == null ? null : () => onMenuOpening!(item),
      onActionCompleted: onActionCompleted,
      child: InkWell(
        onTap: open == null ? null : () => open(item),
        child: card,
      ),
    );
  }

  /// 明细项：带 cellColor 的列渲染成带描边语义色块（与表格整格底色同语言），
  /// 其余列渲染 `标签 值` 小字。[MasterColumnDef.cardRendersBuilder] 的列直接
  /// 复用表格 cellBuilder（富格在卡片上不丢信息，如客户应收两行余额说明）。
  Widget _detail(BuildContext context, ThemeData theme, MasterColumnDef<T> c) {
    final value = (c.value(item) ?? '').trim();
    if (value.isEmpty && !c.cardRendersBuilder) {
      return const SizedBox.shrink();
    }
    if (c.cardRendersBuilder && c.cellBuilder != null) {
      return DefaultTextStyle.merge(
        style: theme.textTheme.bodySmall!,
        child: MasterDataTableCellScope(
          selected: isSelected,
          foregroundColor: theme.colorScheme.onSurface,
          child: Builder(builder: (ctx) => c.cellBuilder!(ctx, item)),
        ),
      );
    }
    final cellColor = c.cellColor?.call(context, item);
    if (cellColor == null) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${c.label} ',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(
              text: value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    final onCell =
        ThemeData.estimateBrightnessForColor(cellColor) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cellColor,
        border: Border.all(color: theme.colorScheme.outline, width: 0.5),
      ),
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: onCell,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
