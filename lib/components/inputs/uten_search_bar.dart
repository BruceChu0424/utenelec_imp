// UtenSearchBar - 搜索栏（带清除 + 防抖）——全平台唯一搜索框组件。
// 文档：docs/02-组件库/UtenSearchBar.md
//
// 2026-09-01 全平台统一：搜索框只保留本组件一种形态——胶囊圆角
//（半径远大于高度，RRect 自动收敛为高度一半，与 M3 SegmentedButton
// StadiumBorder 分段导航条同形）。业务代码不得再手写搜索 TextField；
// 圆角与高度也不另设参数，保证所有页面外观一致。
//
// 高度说明：M3 默认给 prefix/suffix 图标各 48×48 最小约束会把输入框顶高，
// 此处显式收紧为内容驱动（约 43，随字号自然增高）；与分段导航条并排时的
// 「严格同高」由 UtenFilterToolbar 用 IntrinsicHeight+stretch 结构保证，
// 不在本组件里各自算高度（visualDensity 对两侧折减不一致，算不平）。

import 'dart:async';

import 'package:flutter/material.dart';

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

  /// 紧凑态：收紧内边距与图标（高约 36 而非 44）。
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
  /// 高度为内容驱动：M3 默认给 prefix/suffix 图标各 48×48 最小约束（会把
  /// 输入框顶高、且与分段条折减不一致），此处显式收紧到 32——图标不再
  /// 撑高度；contentPadding 与文本行高决定最终高度，字号放大自然增高。
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
        minHeight: widget.dense ? 28 : 32,
      ),
      suffixIcon: _controller.text.isNotEmpty
          ? IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              splashRadius: 16,
              visualDensity: VisualDensity.compact,
              onPressed: _clear,
            )
          : null,
      suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 32),
      // 高度由内容驱动（contentPadding 10 + 单行文本 ≈ 44），**不设 minHeight 48**：
      // UtenFilterToolbar 用 IntrinsicHeight+stretch 让分段条跟搜索框同高，强拉到
      // 48 会把全站分类分段一起拉高（2026-09-10 用户反馈「分类变高了不正常」已回退）。
      // 需要与本框等高的行尾下拉自行传紧凑 contentPadding（见即时库存页）。
      isDense: true,
      filled: true,
      fillColor: theme.inputDecorationTheme.fillColor,
      contentPadding: widget.dense
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      enabledBorder: border(theme.colorScheme.outline),
      focusedBorder: border(theme.colorScheme.primary, 2),
    );
  }
}
