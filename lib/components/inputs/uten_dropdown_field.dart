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

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import 'required_field_decoration.dart';
import 'uten_field_message.dart';
import 'uten_input_decoration.dart';

/// 单选项：[value]（null=清空/不选）+ [label]（展示文本）。
///
/// [enabled]=false 为分组标题（如仓库层级下拉的父仓）：正常显示与参与值回显，
/// 但点击不生效；[indent] 为缩进像素（子仓缩进展示），两者默认关闭保持旧行为。
class UtenDropdownItem {
  const UtenDropdownItem({
    this.value,
    required this.label,
    this.enabled = true,
    this.indent = 0,
  });
  final String? value;
  final String label;
  final bool enabled;
  final double indent;
}

/// outlined 单选下拉，Overlay 弹层样式对齐货品资料筛选下拉。
class UtenDropdownField extends StatefulWidget {
  const UtenDropdownField({
    super.key,
    this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.required = false,
    this.allowClear = true,
    this.enabled = true,
    this.hintText,
    this.info,
    this.searchable,
    this.errorMessage,
    this.autofilled = false,
    this.warningMessage,
    this.onAddNew,
    this.addNewLabel,
  });

  /// 标签（表头字段用；grid 单元格可不传，由列头标识列）。
  final String? label;
  final String? value;
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

class _UtenDropdownFieldState extends State<UtenDropdownField> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;
  TextEditingController? _searchCtl;
  FocusNode? _searchFocus;

  /// 本次浮层向上还是向下展开（下方空间不够时向上）+ 适配后的最大高度。
  bool _openAbove = false;
  double _maxHeight = 320;

  /// 当前值的展示文本（孤儿值兜底显原值）。
  String get _display {
    if (widget.value == null) return '';
    for (final it in widget.items) {
      if (it.value == widget.value) return it.label;
    }
    return widget.value!;
  }

  void _open() {
    if (_overlay != null || !widget.enabled) return;
    // 测量字段在屏幕的位置：下方空间不够（比上方小）则向上展开，并按可用空间收限高，
    // 避免浮层在底部被裁/溢出屏外（颜色/单位等表单字段靠近底部时尤甚）。
    final box = context.findRenderObject() as RenderBox?;
    final screenH = MediaQuery.sizeOf(context).height;
    if (box != null && box.hasSize) {
      final top = box.localToGlobal(Offset.zero).dy;
      final down = screenH - (top + box.size.height);
      final up = top;
      _openAbove = up > down;
      final avail = (_openAbove ? up : down) - 8;
      _maxHeight = avail.clamp(120.0, 320.0);
    } else {
      _openAbove = false;
      _maxHeight = 320;
    }
    _searchCtl = TextEditingController();
    _searchFocus = FocusNode();
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
    _searchCtl?.dispose();
    _searchCtl = null;
    _searchFocus?.dispose();
    _searchFocus = null;
  }

  void _select(String? v) {
    widget.onChanged(v);
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
    final hasValue = widget.value != null;
    final requiredEmpty =
        widget.enabled &&
        widget.required &&
        !hasValue &&
        widget.errorMessage == null;
    // 预填黄框仅在「有值、无错误、非必填空」时呈现（必填空/错误仍走红，优先级更高）。
    final autofillHint =
        widget.enabled &&
        (widget.autofilled || widget.warningMessage != null) &&
        hasValue &&
        widget.errorMessage == null;
    return CompositedTransformTarget(
      link: _link,
      child: InkWell(
        onTap: _open,
        child: InputDecorator(
          decoration: applyRequiredEmpty(
            applyAutofillHint(
              UtenInputDecoration(
                InputDecoration(
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
                  helper: autofillHint
                      ? UtenFieldMessage.autofill(
                          widget.warningMessage ?? '已按上次记录预填，请核对',
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
            hasValue ? _display : (widget.hintText ?? '请选择'),
            style: TextStyle(
              color: hasValue
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 弹层：锚定字段下方、限高 320、竖向滚动；点外部关闭。样式对齐 _FilterCell。
  /// 选项较多（或 searchable:true）时顶部带搜索框，输入实时过滤，回车选中第一项。
  Widget _buildOverlay(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final searchable = widget.searchable ?? widget.items.length >= 4;
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
          targetAnchor: _openAbove ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: _openAbove ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(0, _openAbove ? -2 : 2),
          child: TapRegion(
            onTapOutside: (_) => _close(),
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: _maxHeight,
                  maxWidth: 300,
                ),
                child: StatefulBuilder(
                  builder: (ctx, setOverlayState) {
                    final q = _searchCtl?.text.trim().toLowerCase() ?? '';
                    final filtered = q.isEmpty
                        ? widget.items
                        : widget.items
                              .where((it) => it.label.toLowerCase().contains(q))
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
                              focusNode: _searchFocus,
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
                                          _searchCtl!.clear();
                                          setOverlayState(() {});
                                        },
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
                              onSubmitted: (_) {
                                if (filtered.isNotEmpty) {
                                  _select(filtered.first.value);
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
                                _close();
                                widget.onAddNew!();
                              },
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: UtenSpacing.s12,
                                  vertical: UtenSpacing.s8,
                                ),
                                decoration: BoxDecoration(
                                  color: UtenColors.successBg,
                                  borderRadius: BorderRadius.circular(6),
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
                                  label: '不选',
                                  selected: widget.value == null,
                                  onTap: () => _select(null),
                                  theme: theme,
                                ),
                              for (final it in filtered)
                                _item(
                                  ctx,
                                  label: it.label,
                                  selected: it.value == widget.value,
                                  onTap: it.enabled
                                      ? () => _select(it.value)
                                      : null,
                                  theme: theme,
                                  indent: it.indent,
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
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    required ThemeData theme,
    double indent = 0,
  }) {
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: disabled
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
  }
}
