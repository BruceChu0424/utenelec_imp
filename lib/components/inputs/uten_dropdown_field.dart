// UtenDropdownField - outlined 单选下拉，弹层样式对齐货品资料 MasterDataTableView 的 _FilterCell
// （surfaceContainerHigh + elevation 8 + 圆角 8 + 选中 primaryContainer + 勾）。
//
// 取代编辑页/明细单元里的 DropdownButtonFormField，让所有下拉（供应商/币种/仓库/颜色/单位/账户/项目…）
// 与货品资料表头筛选下拉视觉一致。
//
// 用法：
//   UtenDropdownField(
//     label: '供应商', required: true,
//     value: _supplierId,
//     items: [for (final e in entries.entries) UtenDropdownItem(value: e.key, label: e.value)],
//     onChanged: (v) => setState(() => _supplierId = v),
//   )

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import 'required_field_decoration.dart';
import 'uten_field_message.dart';
import 'uten_input_decoration.dart';
import 'uten_table_cell_spec.dart';
import '../../shared/ai/page_context/ai_page_context.dart';

/// 单选项：[value]（null=清空/不选）+ [label]（展示文本）。
///
/// [enabled]=false 为分组标题（如仓库层级下拉的父仓）：正常显示与参与值回显，
/// 但点击不生效；[indent] 为缩进像素（子仓缩进展示），两者默认关闭保持旧行为。
/// [error]=true 用红字显示并在悬停时给出整句(如「无法转到下一道工序」的原因)，
/// 一般与 enabled=false 搭配：列出来让人知道为什么不能选。
class UtenDropdownItem {
  const UtenDropdownItem({
    this.value,
    required this.label,
    this.enabled = true,
    this.indent = 0,
    this.visible = true,
    this.error = false,
    this.tooltip,
  });
  final String? value;
  final String label;
  final bool enabled;
  final double indent;
  final bool error;

  /// Optional full context for a shorter visible label, such as an exact work
  /// order and receiving limit. Omitting it keeps the original label tooltip.
  final String? tooltip;

  /// A historical value can retain its label without appearing in new choices.
  final bool visible;
}

/// outlined 单选下拉，Overlay 弹层样式对齐货品资料筛选下拉。
class UtenDropdownField extends StatefulWidget {
  const UtenDropdownField({
    super.key,
    this.label,
    required this.value,
    this.selectedLabel,
    required this.items,
    required this.onChanged,
    this.required = false,
    this.allowClear = true,
    this.enabled = true,
    this.hintText,
    this.info,
    this.searchable,
    this.menuMatchContentWidth = false,
    this.errorMessage,
    this.autofilled = false,
    this.warningMessage,
    this.onAddNew,
    this.addNewLabel,
    this.dense = false,
    this.flat = false,
    this.aiSensitive = false,
  });

  /// 敏感字段(ADR-150)：AI 读页面时只发标签不发值。
  final bool aiSensitive;

  /// 紧凑形态（grid 单元格）：isDense 吃全局主题，与数量/单价等文本格等高
  ///（2026-09-12 用户口径：结账方式等网格下拉用统一 UI，不要原生 PopupMenu）。
  final bool dense;

  /// 无边框形态（MasterDataTableView 只读表的内联下拉，2026-10-06 行高统一
  /// 口径）：渲染为「文本 + 小箭头」，高度=单行文本，与同行文本格等高；39 高
  /// 的描边框会把只读行撑到 55。状态提示走文字色（无框可描红/黄）。
  /// 与 [dense] 同时传时 flat 优先。
  final bool flat;

  /// 标签（表头字段用；grid 单元格可不传，由列头标识列）。
  final String? label;
  final String? value;

  /// Optional label for the collapsed selected value. Menu choices, search and
  /// identity still use [UtenDropdownItem.label] and [UtenDropdownItem.value].
  /// Ignored when [value] is null; omitted preserves the original item label.
  final String? selectedLabel;
  final List<UtenDropdownItem> items;
  final ValueChanged<String?> onChanged;

  /// 是否必填（label 后加 *）。
  final bool required;

  /// 是否显示"不选"项（清空）。
  final bool allowClear;

  final bool enabled;
  final String? hintText;

  /// Field guidance disclosed by the info icon inside the input.
  final String? info;

  /// 弹层是否带搜索框（输入实时过滤选项）。null=自动（选项 ≥4 个时启用）。
  final bool? searchable;

  /// Widen the open menu for all visible labels using their actual font and
  /// text scale. The menu stays inside the viewport; labels wrap in a narrow
  /// viewport. The collapsed field and the default fixed-width menu are unchanged.
  final bool menuMatchContentWidth;

  /// Validation error shown by a red border and an in-field error icon.
  final String? errorMessage;

  /// Prefilled values have an amber border and an in-field reminder icon.
  /// 优先级：errorMessage（红）> 必填空（红）> autofilled（黄）。
  final bool autofilled;

  /// Non-blocking warning disclosed inside the field.
  final String? warningMessage;

  /// 浮层内"添加新项"回调（如颜色/单位内联新建）：非空时在搜索框下方渲染浅绿"添加"按钮，
  /// 点击先关浮层再触发。null=不显示（默认，不影响其他调用方）。
  final Future<void> Function()? onAddNew;

  /// "添加"按钮文案（默认「+ 添加」）。
  final String? addNewLabel;

  @override
  State<UtenDropdownField> createState() => _UtenDropdownFieldState();
}

class _UtenDropdownFieldState extends State<UtenDropdownField>
    with WidgetsBindingObserver {
  final GlobalKey _anchorKey = GlobalKey();
  final Set<ScrollPosition> _scrollPositions = {};
  OverlayEntry? _overlay;
  OverlayEntry? _pendingOverlayRebuild;
  OverlayState? _overlayHost;
  Rect? _lastAnchor;
  ScrollNotificationObserverState? _scrollObserver;
  TextEditingController? _searchCtl;
  FocusNode? _searchFocus;
  Object? _menuWidthSignature;
  List<UtenDropdownItem> _measuredMenuItems = const [];
  double _measuredMenuWidth = 0;

  // ADR-150: AI page context registration; the value the assistant chose stays
  // framed yellow ("AI filled, please review") until the user picks again.
  final _aiSlot = AiPageSlot();
  bool _aiFilled = false;
  String? _aiFilledValue;

  bool get _aiFilledNow =>
      _aiFilled && widget.value != null && widget.value == _aiFilledValue;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ScrollNotificationObserver.maybeOf(context);
    if (_scrollObserver != observer) {
      _scrollObserver?.removeListener(_onScrollNotification);
      _scrollObserver = observer;
      _scrollObserver?.addListener(_onScrollNotification);
    }
    _aiAttach();
    final route = ModalRoute.of(context);
    if (_overlay != null && route != null && !route.isCurrent) _close();
    if (_overlay != null &&
        (!(_overlayHost?.mounted ?? false) ||
            !identical(
              _overlayHost,
              Overlay.maybeOf(context, rootOverlay: true),
            ))) {
      _close();
    }
    if (_overlay != null) _watchScrollPositions();
    _refreshOverlay();
  }

  @override
  void didUpdateWidget(covariant UtenDropdownField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _aiAttach();
    if (!widget.enabled) {
      _close();
    } else {
      if (_overlay != null) _watchScrollPositions();
      _refreshOverlay();
    }
  }

  void _onScrollNotification(ScrollNotification notification) =>
      _refreshOverlay();

  void _aiAttach() => _aiSlot.attach(
    context,
    widget.label == null
        ? null
        : AiFieldSource(
            capture: _aiField,
            setValue: widget.enabled ? _aiSetValue : null,
          ),
  );

  AiFieldSnapshot? _aiField(AiCaptureContext ctx) {
    final label = aiSnapshotLabel(widget.label);
    if (!mounted || label == null) return null;
    final hasValue = widget.value != null;
    final requiredEmpty =
        widget.enabled &&
        widget.required &&
        !hasValue &&
        widget.errorMessage == null;
    final autofilled =
        widget.enabled &&
        (widget.autofilled || widget.warningMessage != null || _aiFilledNow) &&
        hasValue &&
        widget.errorMessage == null;
    return AiFieldSnapshot(
      label: label,
      value: hasValue ? aiSnapshotValue(_display) : null,
      state: widget.errorMessage != null
          ? AiFieldState.error
          : requiredEmpty
          ? AiFieldState.requiredEmpty
          : autofilled
          ? AiFieldState.autofilled
          : AiFieldState.normal,
      required: widget.required,
      message: aiSnapshotValue(
        widget.errorMessage ??
            (autofilled
                ? (_aiFilledNow
                      ? ctx.l10n.fieldAiFilledReview
                      // Same words the field shows under itself.
                      : widget.warningMessage ?? '已按上次记录预填，请核对')
                : null),
        AiSnapshotLimits.info,
      ),
      info: aiSnapshotValue(widget.info, AiSnapshotLimits.info),
      sensitive: widget.aiSensitive,
    );
  }

  Future<void> _aiSetValue(String value, AiCaptureContext ctx) async {
    if (!mounted || !widget.enabled) {
      throw AiActionFailure(ctx.l10n.aiActionFieldReadOnly(widget.label ?? ''));
    }
    final wanted = value.trim();
    final choices = widget.items
        .where((item) => item.enabled && item.visible && item.value != null)
        .toList();
    UtenDropdownItem? match =
        choices.where((item) => item.label.trim() == wanted).firstOrNull ??
        choices
            .where(
              (item) => item.label.trim().toLowerCase() == wanted.toLowerCase(),
            )
            .firstOrNull;
    if (match == null) {
      final partial = choices
          .where(
            (item) =>
                wanted.isNotEmpty &&
                item.label.toLowerCase().contains(wanted.toLowerCase()),
          )
          .toList();
      if (partial.length == 1) match = partial.single;
    }
    if (match == null) {
      throw AiActionFailure(ctx.l10n.aiActionOptionMissing(wanted));
    }
    widget.onChanged(match.value);
    setState(() {
      _aiFilled = true;
      _aiFilledValue = match!.value;
    });
  }

  /// 当前值的展示文本（孤儿值兜底显原值）。
  String get _display {
    if (widget.value == null) return '';
    for (final it in widget.items) {
      if (it.value == widget.value) return it.label;
    }
    return widget.value!;
  }

  String get _selectedDisplay =>
      widget.value == null ? '' : widget.selectedLabel ?? _display;

  void _open() {
    if (_overlay != null || !widget.enabled) return;
    final search = _searchCtl = TextEditingController();
    final focus = _searchFocus = FocusNode();
    final host = _overlayHost = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) =>
          _buildHostedOverlay(overlayContext, entry, search, focus),
    );
    _overlay = entry;
    host.insert(entry);
    _watchScrollPositions();
    WidgetsBinding.instance.addObserver(this);
    _watchAnchor(entry);
  }

  Rect? _anchorRect() {
    final field = _anchorKey.currentContext?.findRenderObject();
    final overlay = _overlayHost?.context.findRenderObject();
    if (field is! RenderBox ||
        !field.hasSize ||
        !field.attached ||
        overlay is! RenderBox ||
        !overlay.attached) {
      return null;
    }
    return MatrixUtils.transformRect(
      field.getTransformTo(overlay),
      Offset.zero & field.size,
    );
  }

  void _watchAnchor(OverlayEntry entry) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_overlay, entry)) return;
      final anchor = _anchorRect();
      if (anchor == null) {
        _close();
        return;
      }
      if (anchor != _lastAnchor) _refreshOverlay();
      // Observe actual UI frames without requesting frames while the anchor is
      // stationary. Ancestor layout can move a constant field without rebuilding
      // it or changing any ScrollPosition.
      _watchAnchor(entry);
    });
  }

  void _watchScrollPositions() {
    // Every ancestor can move the field, including an outer viewport when a
    // nested viewport scrolls along the same axis.
    final positions = <ScrollPosition>{};
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        positions.add((element.state as ScrollableState).position);
      }
      return true;
    });
    for (final position in _scrollPositions.difference(positions)) {
      position.removeListener(_refreshOverlay);
    }
    for (final position in positions.difference(_scrollPositions)) {
      position.addListener(_refreshOverlay);
    }
    _scrollPositions
      ..clear()
      ..addAll(positions);
  }

  void _close() {
    final entry = _overlay;
    final search = _searchCtl;
    final focus = _searchFocus;
    _overlay = null;
    _overlayHost = null;
    _lastAnchor = null;
    _pendingOverlayRebuild = null;
    _searchCtl = null;
    _searchFocus = null;
    WidgetsBinding.instance.removeObserver(this);
    for (final position in _scrollPositions) {
      position.removeListener(_refreshOverlay);
    }
    _scrollPositions.clear();
    if (entry == null) {
      search?.dispose();
      focus?.dispose();
      return;
    }
    // remove can defer unmount to the next frame. Keep the old resources alive
    // until its TextField unmounts, without touching a rapidly reopened menu.
    var released = false;
    void releaseResources() {
      if (released || entry.mounted) return;
      released = true;
      entry.removeListener(releaseResources);
      search?.dispose();
      focus?.dispose();
    }

    entry.addListener(releaseResources);
    entry.remove();
    entry.dispose();
    releaseResources();
  }

  @override
  void didChangeMetrics() => _refreshOverlay();

  void _refreshOverlay() {
    final entry = _overlay;
    if (entry == null) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (identical(_pendingOverlayRebuild, entry)) return;
      _pendingOverlayRebuild = entry;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(_pendingOverlayRebuild, entry)) {
          _pendingOverlayRebuild = null;
        }
        if (mounted && identical(_overlay, entry)) entry.markNeedsBuild();
      });
    } else {
      entry.markNeedsBuild();
    }
  }

  Widget _withAnchor({required Widget child}) =>
      KeyedSubtree(key: _anchorKey, child: child);

  Widget _buildHostedOverlay(
    BuildContext overlayContext,
    OverlayEntry entry,
    TextEditingController search,
    FocusNode focus,
  ) {
    if (!mounted || !identical(_overlay, entry)) {
      return const SizedBox.shrink();
    }
    final themes = InheritedTheme.capture(
      from: context,
      to: _overlayHost!.context,
    );
    final fieldMedia = MediaQuery.of(context);
    final overlayMedia = MediaQuery.of(overlayContext);
    Widget menu = LayoutBuilder(
      builder: (menuContext, constraints) =>
          _buildOverlay(menuContext, constraints, entry, search, focus),
    );
    menu = MediaQuery(
      data: fieldMedia.copyWith(
        padding: overlayMedia.padding,
        viewInsets: overlayMedia.viewInsets,
        viewPadding: overlayMedia.viewPadding,
      ),
      child: Localizations.override(
        context: context,
        child: Directionality(
          textDirection: Directionality.of(context),
          child: menu,
        ),
      ),
    );
    final scope =
        context
                .getElementForInheritedWidgetOfExactType<
                  UncontrolledProviderScope
                >()
                ?.widget
            as UncontrolledProviderScope?;
    if (scope != null) {
      menu = UncontrolledProviderScope(container: scope.container, child: menu);
    }
    return themes.wrap(menu);
  }

  void _select(String? v) {
    if (!mounted || !widget.enabled) {
      _close();
      return;
    }
    final selectable = widget.items.any(
      (item) => item.value == v && item.enabled && item.visible,
    );
    if (!selectable && !(v == null && widget.allowClear)) return;
    _aiFilled = false;
    final onChanged = widget.onChanged;
    _close();
    onChanged(v);
  }

  @override
  void deactivate() {
    // A GlobalKey can move this still-mounted field within the same Overlay.
    // Invalidate the old owner entry and its callbacks before reattachment.
    _close();
    super.deactivate();
  }

  @override
  void dispose() {
    _scrollObserver?.removeListener(_onScrollNotification);
    _scrollObserver = null;
    _aiSlot.detach();
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasValue = widget.value != null;
    final requiredEmpty =
        widget.enabled &&
        widget.required &&
        !hasValue &&
        widget.errorMessage == null;
    // 预填黄框仅在「有值、无错误、非必填空」时呈现（必填空/错误仍走红，优先级更高）。
    final autofillHint =
        widget.enabled &&
        (widget.autofilled || widget.warningMessage != null || _aiFilledNow) &&
        hasValue &&
        widget.errorMessage == null;
    if (widget.flat) {
      return _buildFlat(theme, hasValue, requiredEmpty, autofillHint);
    }
    return _withAnchor(
      child: InkWell(
        onTap: _open,
        child: InputDecorator(
          decoration: applyRequiredEmpty(
            applyAutofillHint(
              UtenInputDecoration(
                InputDecoration(
                  // 紧凑形态（2026-09-18 用户口径：表格内下拉太高）——isDense +
                  // 共享紧凑内边距（2026-10-08 起与实盘格/编辑表同源，见
                  // UtenEditableGridCellSpec），收起时与同行文本格等高；非 dense
                  // 走主题默认。
                  isDense: widget.dense,
                  contentPadding: widget.dense
                      ? UtenEditableGridCellSpec.contentPadding
                      : null,
                  // 箭头图标自带约束（2026-10-06）：InputDecorator 对无约束的
                  // suffixIcon 默认给最小 48×48 触控槽，直接把格子撑高；预填
                  // 黄标时 UtenInputDecoration 的提示包装也按本约束收敛。
                  suffixIconConstraints: widget.dense
                      ? const BoxConstraints(minWidth: 20, minHeight: 20)
                      : null,
                  label: widget.label == null
                      ? null
                      : fieldLabel(
                          widget.label!,
                          theme,
                          required: widget.required,
                          info: widget.info,
                          base: theme.inputDecorationTheme.labelStyle,
                        ),
                  hintText: widget.hintText,
                  // 同格内值单行口径：内部 hint 超宽折行同样会撑高字段。
                  hintMaxLines: 1,
                  helper: autofillHint
                      ? UtenFieldMessage.autofill(
                          (_aiFilledNow
                                  ? aiPageL10n(context).fieldAiFilledReview
                                  : null) ??
                              widget.warningMessage ??
                              '已按上次记录预填，请核对',
                        )
                      : null,
                  error: widget.errorMessage == null
                      ? null
                      : UtenFieldMessage.error(widget.errorMessage!),
                  suffixIcon: const Icon(
                    Icons.arrow_drop_down_rounded,
                    size: 20,
                  ),
                ),
                info: widget.info,
              ),
              theme,
              autofilled: autofillHint,
            ),
            theme,
            requiredEmpty: requiredEmpty,
          ),
          child: Text(
            hasValue ? _selectedDisplay : (widget.hintText ?? '请选择'),
            // 单行 + 省略号（2026-09-16 用户口径）：选中值超宽时折成两行会把
            // 表格整行撑高（采购付款/结账方式「选完变两行」根因），超宽内容
            // 由网格列 textOf 自动加宽兜底，表单里就省略号。
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 紧凑形态字号对齐同行 TextField 输入文本（bodyLarge）：表格里
            // 下拉值与数量/单价同一字号同一行高，整行等高（2026-10-06）。
            style:
                (widget.dense
                        ? theme.textTheme.bodyLarge
                        : theme.textTheme.bodyMedium)
                    ?.copyWith(
                      color: hasValue
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
          ),
        ),
      ),
    );
  }

  /// 无边框形态：文本 + 小箭头，高度=单行文本（继承宿主格 DefaultTextStyle，
  /// 不写死字号——MDTV 读表是 bodySmall、其它宿主各自跟随）；弹层与描边形态
  /// 同一个 [_open]/[_buildOverlay]。状态提示没有框可描：错误/必填空走 error
  /// 文字色，预填走 warning 色，完整说明挂 Tooltip。
  Widget _buildFlat(
    ThemeData theme,
    bool hasValue,
    bool requiredEmpty,
    bool autofillHint,
  ) {
    final display = hasValue ? _selectedDisplay : (widget.hintText ?? '请选择');
    final message = widget.errorMessage ?? widget.warningMessage;
    return _withAnchor(
      child: Tooltip(
        message: message ?? (hasValue ? _display : display),
        child: InkWell(
          onTap: _open,
          borderRadius: BorderRadius.circular(UtenRadius.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: !widget.enabled
                        ? theme.colorScheme.onSurfaceVariant
                        : widget.errorMessage != null || requiredEmpty
                        ? theme.colorScheme.error
                        : !hasValue
                        ? theme.colorScheme.onSurfaceVariant
                        : autofillHint
                        ? UtenColors.warning
                        : null,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 16,
                color: widget.enabled
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 弹层：锚定字段下方、限高 320、竖向滚动；点外部关闭。样式对齐 _FilterCell。
  /// 选项较多（或 searchable:true）时顶部带搜索框，输入实时过滤，回车选中第一项。
  Widget _buildOverlay(
    BuildContext ctx,
    BoxConstraints constraints,
    OverlayEntry entry,
    TextEditingController search,
    FocusNode focus,
  ) {
    bool current() => mounted && identical(_overlay, entry) && widget.enabled;
    void close() {
      if (current()) _close();
    }

    void select(String? value) {
      if (current()) _select(value);
    }

    final anchor = _anchorRect();
    if (anchor == null) return const SizedBox.shrink();
    final host = _overlayHost!.context.findRenderObject() as RenderBox;
    var visible = Offset.zero & constraints.biggest;
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final viewport = element.findRenderObject();
        if (viewport is RenderBox && viewport.attached && viewport.hasSize) {
          visible = visible.intersect(
            MatrixUtils.transformRect(
              viewport.getTransformTo(host),
              Offset.zero & viewport.size,
            ),
          );
        }
      }
      return true;
    });
    if (!visible.overlaps(anchor)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_overlay, entry)) _close();
      });
      return const SizedBox.shrink();
    }
    _lastAnchor = anchor;
    final overlaySize = constraints.biggest;
    final theme = Theme.of(ctx);
    final searchable = widget.searchable ?? widget.items.length >= 4;
    // Resolve the anchor during layout. A paint-only follower prevents nested
    // Tooltip overlays from positioning themselves when a menu item is hovered.
    final down = overlaySize.height - anchor.bottom;
    final up = anchor.top;
    final openAbove = up > down;
    final maxHeight = ((openAbove ? up : down) - 8).clamp(120.0, 320.0);
    final defaultWidth = anchor.width.clamp(120.0, 480.0);
    final viewportWidth = math.max(0.0, overlaySize.width - UtenSpacing.s16);
    final fieldWidth = widget.menuMatchContentWidth
        ? math.min(
            viewportWidth,
            math.max(
              math.max(anchor.width, 120.0),
              _menuContentWidth(ctx, searchable),
            ),
          )
        : defaultWidth;
    final left = widget.menuMatchContentWidth
        ? anchor.left
              .clamp(
                UtenSpacing.s8,
                math.max(
                  UtenSpacing.s8,
                  overlaySize.width - UtenSpacing.s8 - fieldWidth,
                ),
              )
              .toDouble()
        : anchor.left;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: close,
          ),
        ),
        Positioned(
          left: left,
          top: openAbove ? null : anchor.bottom + 2,
          bottom: openAbove ? overlaySize.height - anchor.top + 2 : null,
          child: TapRegion(
            onTapOutside: (_) => close(),
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(UtenRadius.md),
              clipBehavior: Clip.antiAlias,
              child: Container(
                width: fieldWidth,
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: StatefulBuilder(
                  builder: (ctx, setOverlayState) {
                    final q = search.text.trim().toLowerCase();
                    final filtered = widget.items
                        .where(
                          (it) =>
                              it.visible &&
                              (q.isEmpty || it.label.toLowerCase().contains(q)),
                        )
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
                              controller: search,
                              focusNode: focus,
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
                                suffixIcon: q.isEmpty
                                    ? null
                                    : IconButton(
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 16,
                                        ),
                                        onPressed: () {
                                          if (!current()) return;
                                          search.clear();
                                          setOverlayState(() {});
                                        },
                                      ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(
                                    UtenRadius.control,
                                  ),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: UtenSpacing.s8,
                                  vertical: UtenSpacing.s8,
                                ),
                              ),
                              onChanged: (_) => setOverlayState(() {}),
                              onSubmitted: (_) {
                                if (filtered.isNotEmpty) {
                                  select(filtered.first.value);
                                }
                              },
                            ),
                          ),
                        if (widget.onAddNew != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              UtenSpacing.s8,
                              UtenSpacing.s4,
                              UtenSpacing.s8,
                              UtenSpacing.s4,
                            ),
                            child: InkWell(
                              onTap: () {
                                if (!current()) return;
                                final onAddNew = widget.onAddNew;
                                if (onAddNew == null) return;
                                _close();
                                onAddNew();
                              },
                              borderRadius: BorderRadius.circular(
                                UtenRadius.sm,
                              ),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: UtenSpacing.s12,
                                  vertical: UtenSpacing.s8,
                                ),
                                decoration: BoxDecoration(
                                  color: UtenColors.successBg,
                                  borderRadius: BorderRadius.circular(
                                    UtenRadius.sm,
                                  ),
                                  border: Border.all(color: UtenColors.success),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.add_rounded,
                                      size: 18,
                                      color: theme.colorScheme.primary,
                                    ),
                                    const SizedBox(width: UtenSpacing.s4),
                                    Text(
                                      widget.addNewLabel ?? '添加',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme.colorScheme.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        Flexible(
                          child: ListView(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            children: <Widget>[
                              if (widget.allowClear)
                                _item(
                                  ctx,
                                  key: ValueKey((
                                    'uten-dropdown-clear-option',
                                    widget.key,
                                  )),
                                  label: '不选',
                                  selected: widget.value == null,
                                  onTap: () => select(null),
                                  theme: theme,
                                ),
                              for (final it in filtered)
                                _item(
                                  ctx,
                                  key: ValueKey((
                                    'uten-dropdown-option',
                                    widget.key,
                                    it.value,
                                  )),
                                  label: it.label,
                                  tooltip: it.tooltip,
                                  selected: it.value == widget.value,
                                  onTap: it.enabled
                                      ? () => select(it.value)
                                      : null,
                                  theme: theme,
                                  indent: it.indent,
                                  error: it.error,
                                ),
                              if (filtered.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: UtenSpacing.s12,
                                    vertical: UtenSpacing.s12,
                                  ),
                                  child: Text(
                                    '无匹配项',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
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

  Widget _item(
    BuildContext ctx, {
    Key? key,
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    required ThemeData theme,
    double indent = 0,
    bool error = false,
    String? tooltip,
  }) {
    final disabled = onTap == null;
    final item = InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.only(
          left: UtenSpacing.s12 + indent,
          right: UtenSpacing.s12,
          top: UtenSpacing.s8,
          bottom: UtenSpacing.s8,
        ),
        color: selected ? theme.colorScheme.primaryContainer : null,
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: selected
                  ? Icon(
                      Icons.check_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    )
                  : null,
            ),
            const SizedBox(width: UtenSpacing.s4),
            Expanded(
              child: Text(
                label,
                maxLines: widget.menuMatchContentWidth ? null : 1,
                overflow: widget.menuMatchContentWidth
                    ? TextOverflow.clip
                    : TextOverflow.ellipsis,
                style: error
                    ? theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      )
                    : disabled
                    ? theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      )
                    : theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
    return Tooltip(key: key, message: tooltip ?? label, child: item);
  }

  double _menuContentWidth(BuildContext context, bool searchable) {
    final theme = Theme.of(context);
    final inherited = DefaultTextStyle.of(context).style;
    final style = inherited.merge(theme.textTheme.bodyMedium);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    var scrollbar = 8.0;
    final thickness = ScrollbarTheme.of(context).thickness;
    for (final states in [
      <WidgetState>{},
      {WidgetState.hovered},
      {WidgetState.dragged},
    ]) {
      scrollbar = math.max(scrollbar, thickness?.resolve(states) ?? 0);
    }
    final addLabel = widget.onAddNew == null
        ? null
        : widget.addNewLabel ?? '添加';
    final signature = (
      _searchCtl,
      style,
      scaler,
      direction,
      scrollbar,
      searchable,
      widget.allowClear,
      addLabel,
    );
    final visible = widget.items
        .where((item) => item.visible)
        .toList(growable: false);
    if (_menuWidthSignature == signature &&
        visible.length == _measuredMenuItems.length &&
        visible.indexed.every(
          (entry) => identical(entry.$2, _measuredMenuItems[entry.$1]),
        )) {
      return _measuredMenuWidth;
    }
    double textWidth(String text, TextStyle textStyle) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    // Every row reserves the check column, padding and scrollbar even when not
    // selected. Disabled section rows use the same semibold font as their text.
    final itemChrome =
        UtenSpacing.s12 * 2 + 18 + UtenSpacing.s4 + scrollbar + UtenSpacing.s8;
    var width = widget.allowClear ? textWidth('不选', style) + itemChrome : 0.0;
    for (final item in visible) {
      final itemStyle = !item.enabled && !item.error
          ? style.copyWith(fontWeight: FontWeight.w600)
          : style;
      width = math.max(
        width,
        textWidth(item.label, itemStyle) + itemChrome + item.indent,
      );
    }
    if (searchable) {
      // Include both search and clear icons, outer padding and input padding so
      // typing a narrow search never resizes the original full-choice menu.
      width = math.max(
        width,
        textWidth('输入关键字搜索', style) + 32 * 2 + UtenSpacing.s8 * 4,
      );
    }
    if (addLabel != null) {
      width = math.max(
        width,
        textWidth(addLabel, style.copyWith(fontWeight: FontWeight.w600)) +
            18 +
            UtenSpacing.s4 +
            UtenSpacing.s12 * 2 +
            UtenSpacing.s8 * 2,
      );
    }
    _menuWidthSignature = signature;
    _measuredMenuItems = visible;
    _measuredMenuWidth = width.ceilToDouble() + 2;
    return _measuredMenuWidth;
  }
}
