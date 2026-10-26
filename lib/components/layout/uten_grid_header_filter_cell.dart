// Editing-grid headers retain exact facets. Text columns also accept keywords:
// typing narrows candidate buckets, Enter/Search applies to rows and closes.
// The menu's scope/version prevents callbacks from a previous table or source.
import 'package:flutter/material.dart';
import 'dart:math' as math;

import 'package:uten_imp/core/theme/uten_tokens.dart';
import '../../shared/search/keyword_search.dart';
import 'uten_table_column_kit.dart';
import '../inputs/uten_dropdown_scroll_scope.dart';
import '../feedback/uten_overlay_lifecycle.dart';

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
    this.leading,
    this.search = '',
    this.onSearch,
    this.scope,
    this.isCurrent,
    this.headerInfo,
  });

  final String label;
  final List<GridHeaderFilterBucket> buckets;
  final int nullCount;
  final String? selected;
  final ValueChanged<String?> onChanged;
  final bool requiredStar;
  final String search;
  final ValueChanged<String>? onSearch;
  final Object? scope;
  final bool Function()? isCurrent;
  final String? headerInfo;

  /// 标签前缀（2026-09-25）：固定列传图钉图标，与标签同行垂直居中。
  final Widget? leading;

  @override
  State<GridHeaderFilterCell> createState() => _GridHeaderFilterCellState();
}

class _GridHeaderFilterCellState extends State<GridHeaderFilterCell> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;
  UtenOverlayLifecycle? _overlayLifecycle;
  TextEditingController? _searchCtl;
  Object? _openScope;
  int _menuVersion = 0;
  double _menuWidth = 300;
  double _menuHeight = 360;
  double _menuOffsetX = 0;
  bool _openUp = false;
  bool _refreshScheduled = false;

  bool get _current =>
      mounted &&
      _overlay != null &&
      _openScope == widget.scope &&
      (widget.isCurrent?.call() ?? true);

  /// Buckets reflect the other columns' conditions. An exact selection may
  /// legitimately be absent from that intersection; the owner prunes only
  /// genuinely obsolete values against all source rows.
  String? get _sanitized => widget.selected;

  void _open() {
    if (_overlay != null) return;
    if (!(widget.isCurrent?.call() ?? true)) return;
    if (widget.onSearch == null &&
        widget.buckets.isEmpty &&
        widget.nullCount == 0 &&
        widget.selected == null) {
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    final anchor = context.findRenderObject() as RenderBox?;
    final surface = overlay.context.findRenderObject() as RenderBox?;
    if (anchor != null &&
        surface != null &&
        anchor.hasSize &&
        surface.hasSize) {
      final origin = surface.globalToLocal(anchor.localToGlobal(Offset.zero));
      final bottom = origin.dy + anchor.size.height;
      final availableBelow =
          surface.size.height -
          MediaQuery.viewInsetsOf(context).bottom -
          bottom -
          10;
      final availableAbove = origin.dy - 10;
      _openUp = availableBelow < 180 && availableAbove > availableBelow;
      _menuWidth = math.min(360.0, math.max(0.0, surface.size.width - 16));
      _menuHeight = math.min(
        360.0,
        math.max(0.0, _openUp ? availableAbove : availableBelow),
      );
      final left = origin.dx
          .clamp(8.0, math.max(8.0, surface.size.width - _menuWidth - 8))
          .toDouble();
      _menuOffsetX = left - origin.dx;
    }
    _openScope = widget.scope;
    _menuVersion++;
    _searchCtl = TextEditingController(text: widget.search);
    _overlay = OverlayEntry(builder: _buildOverlay);
    overlay.insert(_overlay!);
    _overlayLifecycle = UtenOverlayLifecycle(onUnavailable: _close);
    _overlayLifecycle!.attach(context);
  }

  void _close() {
    _overlayLifecycle?.dispose();
    _overlayLifecycle = null;
    _overlay?.remove();
    _overlay = null;
    _menuVersion++;
    _openScope = null;
    _searchCtl?.dispose();
    _searchCtl = null;
  }

  void _select(String? value) {
    if (!_current) return;
    widget.onChanged(value);
    _close();
  }

  void _submit() {
    if (!_current) return;
    final value = _searchCtl?.value;
    if (value == null ||
        (value.composing.isValid && !value.composing.isCollapsed)) {
      return;
    }
    widget.onSearch?.call(value.text.trim());
    _close();
  }

  @override
  void didUpdateWidget(covariant GridHeaderFilterCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope ||
        oldWidget.onSearch != null && widget.onSearch == null ||
        !(widget.isCurrent?.call() ?? true)) {
      _close();
    } else {
      // The header updates inside the table's build; its root overlay is an
      // ancestor, so request the refresh after the current build finishes.
      if (_overlay == null || _refreshScheduled) return;
      _refreshScheduled = true;
      final version = _menuVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshScheduled = false;
        if (_current && version == _menuVersion) _overlay?.markNeedsBuild();
      });
    }
  }

  @override
  void deactivate() {
    _close();
    super.deactivate();
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
    // 无任何可选值（该列在当前行集上全空）→ 退回纯标签，不画「点开只有『所有』」
    // 的死箭头。与 MasterDataTableView._FilterCell 的 interactive 口径一致
    // （2026-09-11 表头快速筛选补齐批次统一）。
    if (widget.buckets.isEmpty &&
        s == null &&
        widget.onSearch == null &&
        widget.search.isEmpty) {
      return _plainHeader(theme);
    }
    final highlighted = s != null || widget.search.isNotEmpty;
    final headerStyle = UtenTableHeader.textStyle(
      theme,
      highlighted: highlighted,
    );
    String display;
    if (widget.search.isNotEmpty) {
      display = '${widget.label}：${widget.search}';
    } else if (s == null) {
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
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: UtenSpacing.s4),
              ],
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: display,
                    style: headerStyle,
                    children: widget.requiredStar
                        ? [
                            TextSpan(
                              text: ' *',
                              style: headerStyle.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ]
                        : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.headerInfo != null)
                UtenColumnHintIcon(message: widget.headerInfo!),
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

  /// 无可选值时的纯标签表头（与可筛选态同高同内边距，只是不可点、无箭头）。
  Widget _plainHeader(ThemeData theme) {
    final style = UtenTableHeader.textStyle(theme);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(width: UtenSpacing.s4),
          ],
          Flexible(
            child: Text.rich(
              TextSpan(
                text: widget.label,
                style: style,
                children: widget.requiredStar
                    ? [
                        TextSpan(
                          text: ' *',
                          style: style.copyWith(color: theme.colorScheme.error),
                        ),
                      ]
                    : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.headerInfo != null)
            UtenColumnHintIcon(message: widget.headerInfo!),
        ],
      ),
    );
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final theme = Theme.of(overlayContext);
    final searchable = widget.onSearch != null;
    final version = _menuVersion;
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
          targetAnchor: _openUp ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: _openUp ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(_menuOffsetX, _openUp ? -2 : 2),
          child: TapRegion(
            onTapOutside: (_) => _close(),
            child: Material(
              key: const Key('uten-grid-column-filter-menu'),
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(UtenRadius.md),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: _menuWidth,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: _menuHeight),
                  child: StatefulBuilder(
                    builder: (ctx, setOverlayState) {
                      final q = _searchCtl?.text.trim() ?? '';
                      final buckets = rankedKeywordMatches(
                        widget.buckets,
                        q,
                        fields: (b) => [b.display],
                      );
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
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      key: const Key(
                                        'uten-column-keyword-input',
                                      ),
                                      controller: _searchCtl,
                                      autofocus: true,
                                      textInputAction: TextInputAction.search,
                                      style: theme.textTheme.bodyMedium,
                                      decoration: InputDecoration(
                                        isDense: true,
                                        hintText: widget.label,
                                        prefixIcon: const Icon(
                                          Icons.search_rounded,
                                          size: 18,
                                        ),
                                        prefixIconConstraints:
                                            const BoxConstraints(
                                              minWidth: 32,
                                              minHeight: 32,
                                            ),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            UtenRadius.control,
                                          ),
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: UtenSpacing.s8,
                                              vertical: UtenSpacing.s8,
                                            ),
                                      ),
                                      onChanged: (_) {
                                        if (_current &&
                                            version == _menuVersion) {
                                          setOverlayState(() {});
                                        }
                                      },
                                      onSubmitted: (_) {
                                        if (version == _menuVersion) _submit();
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: UtenSpacing.s4),
                                  TextButton(
                                    key: const Key(
                                      'uten-column-keyword-search',
                                    ),
                                    onPressed: () {
                                      if (version == _menuVersion) _submit();
                                    },
                                    child: const Text('搜索'),
                                  ),
                                ],
                              ),
                            ),
                          Flexible(
                            child: UtenDropdownScrollScope(
                              child: ListView(
                                shrinkWrap: true,
                                padding: EdgeInsets.zero,
                                children: <Widget>[
                                  _menuItem(
                                    ctx,
                                    label: '所有',
                                    isSelected:
                                        _sanitized == null &&
                                        widget.search.isEmpty,
                                    onTap: () {
                                      if (version == _menuVersion) {
                                        _select(null);
                                      }
                                    },
                                    theme: theme,
                                  ),
                                  for (final b in buckets)
                                    _menuItem(
                                      ctx,
                                      label: '${b.display}（${b.count}）',
                                      isSelected: _sanitized == b.value,
                                      onTap: () {
                                        if (version == _menuVersion) {
                                          _select(b.value);
                                        }
                                      },
                                      theme: theme,
                                    ),
                                ],
                              ),
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
