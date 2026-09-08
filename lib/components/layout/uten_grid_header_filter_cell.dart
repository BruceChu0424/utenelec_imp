// 表头筛选单元格（EditableGridColumn.filterValueOf 提供后启用）：点击弹锚定
// 下拉（与 MasterDataTableView 列头 autofilter 同款视觉与交互——CompositedTransform
// 锚定列头下方、root Overlay、TapRegion 点外关闭、选项多时带搜索）。单选值 +
// 「所有」清空；选中时表头高亮（primaryContainer 底 + 主色加粗 + 下拉箭头）。
// UtenEditableGrid 表头筛选单元格的公共实现（列声明 filterValueOf 即启用）。
import 'package:flutter/material.dart';

import 'package:uten_imp/core/theme/uten_tokens.dart';

class GridHeaderFilterBucket {
  const GridHeaderFilterBucket({
    required this.value,
    required this.display,
    required this.count,
  });

  final String value;
  final String display;
  final int count;
}

class GridHeaderFilterCell extends StatefulWidget {
  const GridHeaderFilterCell({
    super.key,
    required this.label,
    required this.buckets,
    required this.nullCount,
    required this.selected,
    required this.onChanged,
    this.requiredStar = false,
  });

  final String label;
  final List<GridHeaderFilterBucket> buckets;
  final int nullCount;
  final String? selected;
  final ValueChanged<String?> onChanged;
  final bool requiredStar;

  @override
  State<GridHeaderFilterCell> createState() => _GridHeaderFilterCellState();
}

class _GridHeaderFilterCellState extends State<GridHeaderFilterCell> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;
  TextEditingController? _searchCtl;

  /// 行集变化后旧选中值可能已不在桶里：sanitize 退回「所有」。
  String? get _sanitized {
    final values = {for (final b in widget.buckets) b.value};
    return widget.selected != null && values.contains(widget.selected)
        ? widget.selected
        : null;
  }

  void _open() {
    if (_overlay != null) return;
    if (widget.buckets.isEmpty && widget.nullCount == 0) return;
    _searchCtl = TextEditingController();
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
    _searchCtl?.dispose();
    _searchCtl = null;
  }

  void _select(String? value) {
    widget.onChanged(value);
    _close();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _sanitized;
    final highlighted = s != null;
    String display;
    if (s == null) {
      display = widget.label;
    } else {
      display = widget.buckets
          .where((b) => b.value == s)
          .map((b) => b.display)
          .followedBy([s])
          .first;
    }
    return CompositedTransformTarget(
      link: _link,
      child: InkWell(
        onTap: _open,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
          color: highlighted ? theme.colorScheme.primaryContainer : null,
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: display,
                    style: (theme.textTheme.labelMedium ?? const TextStyle())
                        .copyWith(
                          fontWeight: highlighted
                              ? FontWeight.w800
                              : FontWeight.w700,
                          color: highlighted ? theme.colorScheme.primary : null,
                        ),
                    children: widget.requiredStar
                        ? [
                            TextSpan(
                              text: ' *',
                              style:
                                  (theme.textTheme.labelMedium ??
                                          const TextStyle())
                                      .copyWith(
                                        color: theme.colorScheme.error,
                                        fontWeight: FontWeight.w700,
                                      ),
                            ),
                          ]
                        : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 18,
                color: highlighted
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final theme = Theme.of(overlayContext);
    final searchable = widget.buckets.length >= 6;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          offset: const Offset(0, 2),
          child: TapRegion(
            onTapOutside: (_) => _close(),
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Container(
                constraints: const BoxConstraints(
                  maxHeight: 360,
                  maxWidth: 300,
                ),
                child: StatefulBuilder(
                  builder: (ctx, setOverlayState) {
                    final q = _searchCtl?.text.trim().toLowerCase() ?? '';
                    final buckets = q.isEmpty
                        ? widget.buckets
                        : widget.buckets
                              .where((b) => b.display.toLowerCase().contains(q))
                              .toList();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (searchable)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              UtenSpacing.s8,
                              UtenSpacing.s8,
                              UtenSpacing.s8,
                              UtenSpacing.s4,
                            ),
                            child: TextField(
                              controller: _searchCtl,
                              autofocus: true,
                              style: theme.textTheme.bodyMedium,
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '输入关键字搜索',
                                prefixIcon: const Icon(
                                  Icons.search_rounded,
                                  size: 18,
                                ),
                                prefixIconConstraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: UtenSpacing.s8,
                                  vertical: UtenSpacing.s8,
                                ),
                              ),
                              onChanged: (_) => setOverlayState(() {}),
                            ),
                          ),
                        Flexible(
                          child: ListView(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            children: <Widget>[
                              _menuItem(
                                ctx,
                                label: '所有',
                                isSelected: _sanitized == null,
                                onTap: () => _select(null),
                                theme: theme,
                              ),
                              for (final b in buckets)
                                _menuItem(
                                  ctx,
                                  label: '${b.display}（${b.count}）',
                                  isSelected: _sanitized == b.value,
                                  onTap: () => _select(b.value),
                                  theme: theme,
                                ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuItem(
    BuildContext context, {
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        color: isSelected ? theme.colorScheme.primaryContainer : null,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: isSelected ? FontWeight.w700 : null,
                  color: isSelected ? theme.colorScheme.primary : null,
                ),
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_rounded,
                size: 16,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}
