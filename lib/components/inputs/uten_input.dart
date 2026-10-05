// UtenInput - 通用输入框（文本/密码/搜索 + 客户端校验）
// 文档：docs/02-组件库/UtenInput.md

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'required_field_decoration.dart';
import 'uten_field_message.dart';
import 'uten_input_decoration.dart';
import '../../shared/ai/page_context/ai_page_context.dart';

/// Uten 输入框
class UtenInput extends StatefulWidget {
  const UtenInput({
    super.key,
    this.label,
    this.hint,
    this.info,
    this.errorMessage,
    this.autofilled = false,
    this.warningMessage,
    this.controller,
    this.obscureText = false,
    this.isPassword = false,
    this.keyboardType,
    this.prefixIcon,
    this.suffixIcon,
    this.validator,
    this.onChanged,
    this.onFieldSubmitted,
    this.enabled = true,
    this.maxLines = 1,
    this.textInputAction,
    this.focusNode,
    this.autofillHints,
    this.inputFormatters,
    this.textCapitalization = TextCapitalization.none,
    this.required = false,
    this.aiSensitive = false,
  });

  /// 标签
  final String? label;

  /// 占位提示
  final String? hint;

  /// Field guidance disclosed by the info icon inside the input.
  final String? info;

  /// 外部字段错误；与 [validator] 生成的错误共用统一长提示外观。
  final String? errorMessage;

  /// The caller clears this flag after an explicit edit or confirmation.
  final bool autofilled;
  final String? warningMessage;

  /// 文本控制器
  final TextEditingController? controller;

  /// 是否隐藏文本
  final bool obscureText;

  /// 是否是密码框（显示可见切换按钮）
  final bool isPassword;

  /// 键盘类型
  final TextInputType? keyboardType;

  /// 前置图标
  final IconData? prefixIcon;

  /// 后置图标
  final IconData? suffixIcon;

  /// 校验器
  final String? Function(String?)? validator;

  /// 文本变化回调
  final ValueChanged<String>? onChanged;

  /// 提交回调
  final ValueChanged<String>? onFieldSubmitted;

  /// 是否启用
  final bool enabled;

  /// 最大行数
  final int maxLines;

  /// 键盘动作
  final TextInputAction? textInputAction;

  /// 焦点节点
  final FocusNode? focusNode;

  /// 自动填充提示
  final Iterable<String>? autofillHints;

  /// 字段级输入约束。姓名、单位、地址等中文自然语言字段通常不应设置。
  final List<TextInputFormatter>? inputFormatters;

  final TextCapitalization textCapitalization;

  /// 是否必填：标签后显红 *；内容为空且启用时输入框描红边，填好即恢复。
  final bool required;

  /// 敏感数值字段(成本/工资/信用额度等, ADR-150)：AI 读页面时只发标签不发值。
  /// 密码框(isPassword/obscureText)根本不登记。
  final bool aiSensitive;

  @override
  State<UtenInput> createState() => _UtenInputState();
}

class _UtenInputState extends State<UtenInput> {
  late TextEditingController _controller;
  bool _isObscured = true;
  bool _ownsController = false;
  bool _empty = true;

  // ADR-150: registered with the AI page context; computed only on capture.
  final _aiSlot = AiPageSlot();

  /// Text the AI assistant filled in (yellow "AI filled, please review")
  /// until the user changes it.
  String? _aiFilledText;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    _isObscured = widget.isPassword;
    _ownsController = widget.controller == null;
    _empty = _controller.text.trim().isEmpty;
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final e = _controller.text.trim().isEmpty;
    final aiEdited = _aiFilledText != null && _controller.text != _aiFilledText;
    if (e != _empty || aiEdited) {
      setState(() {
        _empty = e;
        if (aiEdited) _aiFilledText = null;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _aiAttach();
  }

  void _aiAttach() {
    final secret = widget.isPassword || widget.obscureText;
    _aiSlot.attach(
      context,
      secret || widget.label == null
          ? null
          : AiFieldSource(
              capture: _aiField,
              setValue: widget.enabled ? _aiSetValue : null,
            ),
    );
  }

  AiFieldSnapshot? _aiField(AiCaptureContext ctx) {
    final label = aiSnapshotLabel(widget.label);
    if (!mounted || label == null || widget.isPassword || widget.obscureText) {
      return null;
    }
    final requiredEmpty = widget.required && widget.enabled && _empty;
    final aiFilled = _aiFilledText != null && !_empty;
    final autofilled =
        !_empty &&
        (widget.autofilled || widget.warningMessage != null || aiFilled);
    return AiFieldSnapshot(
      label: label,
      value: aiSnapshotValue(_controller.text),
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
                ? (aiFilled
                      ? ctx.l10n.fieldAiFilledReview
                      : widget.warningMessage ?? ctx.l10n.fieldAutofilledReview)
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
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    setState(() {
      _empty = value.trim().isEmpty;
      _aiFilledText = value;
    });
    widget.onChanged?.call(value);
  }

  @override
  void didUpdateWidget(covariant UtenInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      final previousValue = _controller.value;
      _controller.removeListener(_onTextChanged);
      if (_ownsController) _controller.dispose();
      _controller =
          widget.controller ?? TextEditingController.fromValue(previousValue);
      _ownsController = widget.controller == null;
      _empty = _controller.text.trim().isEmpty;
      _controller.addListener(_onTextChanged);
    }
    if (oldWidget.isPassword != widget.isPassword) {
      _isObscured = widget.isPassword;
    }
    _aiAttach();
  }

  @override
  void dispose() {
    _aiSlot.detach();
    _controller.removeListener(_onTextChanged);
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requiredEmpty = widget.required && widget.enabled && _empty;
    final aiFilled = _aiFilledText != null && !_empty;
    final autofilled =
        !_empty &&
        (widget.autofilled || widget.warningMessage != null || aiFilled);
    final autofillMessage = aiFilled
        ? aiPageL10n(context).fieldAiFilledReview
        : widget.warningMessage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          // Label keeps its required marker; help lives inside the field.
          fieldLabel(
            widget.label!,
            theme,
            required: widget.required,
            base: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
        ],
        // 输入框
        TextFormField(
          controller: _controller,
          obscureText: widget.isPassword ? _isObscured : widget.obscureText,
          keyboardType: widget.keyboardType,
          validator: widget.validator,
          errorBuilder: utenTextFieldErrorBuilder,
          onChanged: widget.onChanged,
          onFieldSubmitted: widget.onFieldSubmitted,
          ignorePointers: false,
          enabled: widget.enabled,
          maxLines: widget.obscureText ? 1 : widget.maxLines,
          textInputAction: widget.textInputAction,
          focusNode: widget.focusNode,
          autofillHints: widget.autofillHints,
          inputFormatters: widget.inputFormatters,
          textCapitalization: widget.textCapitalization,
          style: theme.textTheme.bodyLarge,
          decoration: applyRequiredEmpty(
            applyAutofillHint(
              UtenInputDecoration(
                InputDecoration(
                  hintText: widget.hint,
                  error: widget.errorMessage == null
                      ? null
                      : UtenFieldMessage.error(widget.errorMessage!),
                  prefixIcon: widget.prefixIcon != null
                      ? Icon(widget.prefixIcon, size: 20)
                      : null,
                  suffixIcon: _buildSuffix(),
                  helper: autofilled && autofillMessage != null
                      ? UtenFieldMessage.autofill(autofillMessage)
                      : null,
                ),
                info: widget.info,
              ),
              theme,
              autofilled: autofilled,
            ),
            theme,
            requiredEmpty: requiredEmpty,
          ),
        ),
      ],
    );
  }

  Widget? _buildSuffix() {
    if (widget.isPassword) {
      return IconButton(
        icon: Icon(
          _isObscured
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          size: 20,
        ),
        onPressed: widget.enabled
            ? () => setState(() => _isObscured = !_isObscured)
            : null,
        splashRadius: 18,
      );
    }
    if (widget.suffixIcon != null) {
      return Icon(widget.suffixIcon, size: 20);
    }
    return null;
  }
}
