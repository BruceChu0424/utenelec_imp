// UtenSearchBar - 搜索栏（带清除 + 防抖 + 输入法组合保护）——全平台唯一搜索框组件。
// 文档：docs/02-组件库/UtenSearchBar.md
//
// 全平台唯一搜索形态：与模块分类栏共用control10圆角矩形和紧凑间距。
// 桌面高度下限36，触控实际目标至少48；放大字号可自然撑高。
// 业务代码不再手写搜索 TextField，也不另设圆角或高度。
//
// 输入法组合保护（2026-10-09，中文输入「打一半拼音就被搜索/丢输入法」的根因）：
// 框架的 TextField.onChanged 对 IME 组合中的每次拼音按键都会回调，直接防抖触发
// 会让半截拼音（"li"）发起检索，检索又常命中 0 条导致页面切空态、搜索框被重建、
// 焦点丢失，组合中的拼音被原样顶上屏。因此本组件在 TextEditingValue.composing
// 非空（拼音未上屏）期间挂起 onInputChanged/onChanged；组合结束后统一补发一次
//（选字上屏走 onChanged，原样上屏/失焦提交等文本不变的结束方式走 controller
// 监听补发）。
//
// 高度机制（2026-10-07 根因结论，SDK input_decorator.dart 源码实证）：
// InputDecorator 的**描边**按 layout.containerHeight = clamp(内容高, 文本行高,
// 外部 maxHeight) 绘制——只认 maxHeight，外部 minHeight 拉高的只是盒子、描边不跟
//（_BorderContainer 被 tightFor(内容高) 布局后居中）。因此「与分类分段严格同高」
// 不能靠外层约束，靠的是把**前后缀图标约束的 minHeight** 设为与分段行
// minCellHeight 同源的 [UtenFilterRow.minHeight]：fixIconHeight 参与内容高计算，
// 描边下限按分类角色36/48，两侧在同一工具条中由内容和拉伸一起对齐。
// 2026-09-10 只加外盒 minHeight 的旧尝试已由内部图标高度角色接管：
// 桌面36、触控至少48窗口像素；不限制触控使用48，也不只拉高外盒。

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/router/page_search_lifecycle.dart';
import '../../core/theme/uten_tokens.dart';
import '../../shared/ai/page_context/ai_page_context.dart';

/// Uten 搜索栏
///
/// 内置防抖（默认 300ms）+ 清除按钮 + 自动聚焦控制 + 输入法组合保护
///（拼音组合期间不派发回调，见文件头说明）。
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

  /// Fires synchronously for every committed text edit, before [debounce].
  ///
  /// Pages with asynchronous search can use this to invalidate an older
  /// request during the debounce window. [onChanged] remains the debounced
  /// callback that should start the replacement request. IME composition
  /// (pinyin not yet committed) holds both callbacks until the composition
  /// ends — half-typed pinyin never dispatches.
  final ValueChanged<String>? onInputChanged;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Duration debounce;
  final TextEditingController? controller;

  /// 密集筛选态：文字使用bodyMedium、图标18；保留同一36/48高度角色。
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
  late final _searchLifecycle = PageSearchLifecycle(
    onLeave: _cancelPendingSearch,
    onReturn: _clear,
  );

  /// 非 null = 有一段 IME 组合（拼音未上屏）被挂起，等组合结束后补发回调。
  /// 其值是挂起期间的最新文本；组合结束若文本已变（选字上屏会走
  /// TextField.onChanged），由 onChanged 路径清掉，避免双发。
  String? _heldByComposition;

  // ADR-150: the page search box is a generic AI view action ("search for").
  final _aiSlot = AiPageSlot();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _searchLifecycle.attach(context);
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
        _heldByComposition = null;
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
    // 组合结束时文本可能不变（原样上屏/失焦提交），onChanged 不会触发，
    // 靠监听 controller 捕捉「composing 区间清空」这一刻补发挂起的回调。
    _controller.addListener(_onControllerValueChanged);
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
        _heldByComposition = null;
        _debounce?.cancel();
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    }
  }

  @override
  void dispose() {
    _searchLifecycle.dispose();
    _controller.removeListener(_onControllerValueChanged);
    _aiSlot.detach();
    _debounce?.cancel();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  /// controller 值变化：只负责「组合结束但文本没变」的补发（TextField.onChanged
  /// 只在文本变化时触发，覆盖不了这种结束方式）。程序赋值不会走到这里需要补发
  /// 的路径——它们发生时 [_heldByComposition] 已被调用方清空。
  void _onControllerValueChanged() {
    final held = _heldByComposition;
    if (held == null) return;
    if (_controller.value.composing != TextRange.empty) return;
    if (_controller.text != held) return;
    _heldByComposition = null;
    _dispatch(held);
  }

  void _onChanged(String value) {
    if (_controller.value.composing != TextRange.empty) {
      // 拼音组合中：挂起回调（不清文本），等组合结束统一派发。
      _debounce?.cancel();
      _heldByComposition = value;
      setState(() {});
      return;
    }
    _heldByComposition = null;
    _dispatch(value);
  }

  void _dispatch(String value) {
    _debounce?.cancel();
    widget.onInputChanged?.call(value);
    _debounce = Timer(widget.debounce, () {
      if (!mounted) return;
      widget.onChanged?.call(value);
    });
    setState(() {});
  }

  void _cancelPendingSearch() {
    _debounce?.cancel();
    _heldByComposition = null;
  }

  void _clear() {
    if (!mounted) return;
    _cancelPendingSearch();
    _controller.clear();
    widget.onInputChanged?.call('');
    if (widget.onChanged != null) {
      widget.onChanged!('');
    } else {
      widget.onSubmitted?.call('');
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      onChanged: _onChanged,
      // 回车即查：先取消挂起的防抖回调，避免回车查完 ~300ms 后防抖又重查一次。
      onSubmitted: widget.onSubmitted == null
          ? null
          : (value) {
              _debounce?.cancel();
              widget.onSubmitted!(value);
            },
      textInputAction: TextInputAction.search,
      decoration: _decoration(context, theme),
      style: widget.dense
          ? theme.textTheme.bodyMedium
          : theme.textTheme.bodyLarge,
    );
  }

  /// 与分类栏共用control10圆角矩形；描边outline，聚焦使用主色。
  ///
  /// 描边高度 = max(前后缀图标约束高, contentPadding + 文本行高 + 密度折减)，
  /// 图标约束高与分类分段同源取桌面36/触控至少48的 UtenFilterRow 角色
  ///（机制见文件头）；字号放大时行高自然增高，描边跟随、分段行同拉伸。
  InputDecoration _decoration(BuildContext context, ThemeData theme) {
    final controlHeight = UtenFilterRow.heightOf(context);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: UtenFilterRow.borderRadius,
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      // Override a generic theme's taller field floor for this role; the
      // internal icon constraints below also set the actual painted outline.
      constraints: BoxConstraints(minHeight: controlHeight),
      hintText: widget.hint,
      prefixIcon: Icon(
        Icons.search_rounded,
        size: widget.dense ? 18 : 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      prefixIconConstraints: BoxConstraints(
        minWidth: widget.dense ? 32 : UtenFilterRow.minHeight,
        // 内部图标高参与描边内容高度；桌面36、触控按48窗口目标补偿。
        minHeight: controlHeight,
      ),
      suffixIcon: _controller.text.isNotEmpty
          ? SizedBox(
              width: controlHeight,
              height: controlHeight,
              // 有值与空值共用同一描边下限；清除按钮使用完整角色触控目标。
              child: IconButton(
                tooltip: '清除搜索',
                icon: const Icon(Icons.close_rounded, size: 18),
                splashRadius: 16,
                visualDensity: VisualDensity.compact,
                onPressed: _clear,
              ),
            )
          : null,
      suffixIconConstraints: BoxConstraints(
        minWidth: controlHeight,
        minHeight: controlHeight,
      ),
      // 描边下限由内部图标角色提供，内容行高和padding可继续撑高。
      // 单独设置外部minHeight不会改变InputDecorator描边高度。
      // 需要与本框等高的行尾下拉自行传紧凑 contentPadding（见即时库存页）。
      isDense: true,
      filled: true,
      fillColor: theme.inputDecorationTheme.fillColor,
      contentPadding: UtenFilterRow.contentPadding,
      enabledBorder: border(theme.colorScheme.outline),
      focusedBorder: border(theme.colorScheme.primary, 2),
    );
  }
}
