// UtenSearchBar - 搜索栏（带清除 + 防抖）——全平台唯一搜索框组件。
// 文档：docs/02-组件库/UtenSearchBar.md
//
// 2026-09-01 全平台统一：搜索框只保留本组件一种形态——胶囊圆角
//（半径远大于高度，RRect 自动收敛为高度一半，与 M3 SegmentedButton
// StadiumBorder 分段导航条同形）。业务代码不得再手写搜索 TextField；
// 圆角与高度也不另设参数，保证所有页面外观一致。
//
// 高度机制（2026-10-07 根因结论，SDK input_decorator.dart 源码实证）：
// InputDecorator 的药丸**描边**按 layout.containerHeight = clamp(内容高, 文本行高,
// 外部 maxHeight) 绘制——只认 maxHeight，外部 minHeight 拉高的只是盒子、描边不跟
//（_BorderContainer 被 tightFor(内容高) 布局后居中）。因此「与分类分段严格同高」
// 不能靠外层约束，靠的是把**前后缀图标约束的 minHeight** 设为与分段行
// minCellHeight 同源的 [UtenFilterRow.minHeight]：fixIconHeight 参与内容高计算，
// 药丸下限即 36，两侧描边恒等于 max(36, 文本内容高)，任意密度/字号下相等。
// （2026-09-10 曾加 minHeight 48 拉高整盒、分段被 stretch 带着变高，当日回退；
// 这次只抬描边内容下限，分段行与药丸都不超出各自内容所需。）

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../shared/ai/page_context/ai_page_context.dart';

/// Uten 搜索栏
///
/// 内置防抖（默认 300ms）+ 清除按钮 + 自动聚焦控制。
class UtenSearchBar extends StatefulWidget {
  const UtenSearchBar({
    super.key,
    this.hint = '搜索',
    this.initialValue,
    this.onInputChanged,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.debounce = const Duration(milliseconds: 300),
    this.controller,
    this.dense = false,
  });

  final String hint;
  final String? initialValue;

  /// Fires synchronously for every text edit, before [debounce].
  ///
  /// Pages with asynchronous search can use this to invalidate an older
  /// request during the debounce window. [onChanged] remains the debounced
  /// callback that should start the replacement request.
  final ValueChanged<String>? onInputChanged;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Duration debounce;
  final TextEditingController? controller;

  /// 紧凑态：收紧内边距与图标（高约 30 而非 36）。
  ///
  /// 只给「筛选面板里的一格」用（报表/明细表的左侧筛选区）——那里搜索框是一堆
  /// 筛选项中的一项，默认高度显得笨重（2026-09-11 用户要求「搜索的框显示小点」）。
  /// **不要给页面主搜索框或 UtenFilterToolbar 里的搜索框传 dense**：工具条用
  /// IntrinsicHeight+stretch 让分类分段跟搜索框同高，改高度会把全站分段一起带走
  /// （2026-09-10 已因此回退过一次）。
  final bool dense;

  @override
  State<UtenSearchBar> createState() => _UtenSearchBarState();
}

class _UtenSearchBarState extends State<UtenSearchBar> {
  late final TextEditingController _controller;
  Timer? _debounce;
  bool _ownsController = false;

  // ADR-150: the page search box is a generic AI view action ("search for").
  final _aiSlot = AiPageSlot();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _aiSlot.attach(
      context,
      widget.onChanged == null && widget.onSubmitted == null
          ? null
          : AiPageInfoSource(actions: _aiActions),
    );
  }

  List<AiPageAction> _aiActions(AiCaptureContext ctx) => [
    AiPageAction(
      name: 'searchPage',
      title: ctx.l10n.aiActionSearch,
      kind: AiActionKind.view,
      params: [
        AiActionParam(
          'text',
          type: AiParamType.string,
          title: ctx.l10n.aiActionParamSearch,
          required: false,
          maxLength: 80,
        ),
      ],
      handler: (call) async {
        if (!mounted) throw AiActionFailure(ctx.l10n.aiChatCardHandlerMissing);
        final text = (call.args['text'] as String? ?? '').trim();
        _debounce?.cancel();
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        widget.onInputChanged?.call(text);
        if (widget.onChanged != null) {
          widget.onChanged!(text);
        } else {
          widget.onSubmitted?.call(text);
        }
        setState(() {});
        return null;
      },
    ),
  ];

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ?? TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(covariant UtenSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Uncontrolled search fields may be rendered in two responsive locations
    // (page header and drawer header). Keep their text aligned with the shared
    // page state without sharing one TextEditingController between two inputs.
    if (_ownsController && oldWidget.initialValue != widget.initialValue) {
      final next = widget.initialValue ?? '';
      if (_controller.text != next) {
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    }
  }

  @override
  void dispose() {
    _aiSlot.detach();
    _debounce?.cancel();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    widget.onInputChanged?.call(value);
    _debounce = Timer(widget.debounce, () {
      widget.onChanged?.call(value);
    });
    setState(() {});
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    widget.onInputChanged?.call('');
    widget.onChanged?.call('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      onChanged: _onChanged,
      onSubmitted: widget.onSubmitted,
      textInputAction: TextInputAction.search,
      decoration: _decoration(theme),
      style: widget.dense
          ? theme.textTheme.bodySmall
          : theme.textTheme.bodyMedium,
    );
  }

  /// 胶囊形输入装饰（全平台唯一搜索框形态）：半径取远大于可能高度，
  /// RRect 归一化后即高度一半的 stadium，颜色对齐 M3 SegmentedButton
  ///（描边 outline、聚焦主色）。
  ///
  /// 描边高度 = max(前后缀图标约束高, contentPadding + 文本行高 + 密度折减)，
  /// 图标约束高与分类分段行 minCellHeight 同源取 UtenFilterRow.minHeight(36)
  ///（机制见文件头）；字号放大时行高自然增高，描边跟随、分段行同拉伸。
  InputDecoration _decoration(ThemeData theme) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      hintText: widget.hint,
      prefixIcon: Icon(
        Icons.search_rounded,
        size: widget.dense ? 18 : 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      prefixIconConstraints: BoxConstraints(
        minWidth: widget.dense ? 34 : 40,
        // 图标约束高 = 药丸描边的内容高下限（fixIconHeight 参与内容高计算，
        // 见文件头机制说明）——与 UtenSegmentRow.minCellHeight 同源取
        // UtenFilterRow.minHeight，分类栏与搜索框描边恒同高。
        minHeight: widget.dense ? 28 : UtenFilterRow.minHeight,
      ),
      suffixIcon: _controller.text.isNotEmpty
          ? SizedBox(
              width: UtenFilterRow.minHeight,
              height: UtenFilterRow.minHeight,
              // 清除钮默认 padded 触达目标最小约 40，会把有输入时的药丸顶高、
              // 空框又回落，高度来回跳；外层紧约束统一收口到行高下限。
              child: IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                splashRadius: 16,
                visualDensity: VisualDensity.compact,
                onPressed: _clear,
              ),
            )
          : null,
      suffixIconConstraints: BoxConstraints(
        minWidth: 36,
        minHeight: widget.dense ? 28 : UtenFilterRow.minHeight,
      ),
      // 描边高度机制见文件头：内容高下限由前后缀图标约束(36)提供，
      // contentPadding 与文本行高决定随字号增长的部分，**不设 minHeight 48**：
      // 外部 minHeight 拉高的只是盒子，描边不跟，还会经 stretch 把全站分类
      // 分段一起带高（2026-09-10 用户反馈「分类变高了不正常」已回退）。
      // 需要与本框等高的行尾下拉自行传紧凑 contentPadding（见即时库存页）。
      isDense: true,
      filled: true,
      fillColor: theme.inputDecorationTheme.fillColor,
      contentPadding: widget.dense
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      enabledBorder: border(theme.colorScheme.outline),
      focusedBorder: border(theme.colorScheme.primary, 2),
    );
  }
}
