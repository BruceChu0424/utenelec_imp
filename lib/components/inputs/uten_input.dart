// UtenInput - 通用输入框（文本/密码/搜索 + 客户端校验）
// 文档：docs/02-组件库/UtenInput.md

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'required_field_decoration.dart';
import 'uten_field_message.dart';
import 'uten_input_decoration.dart';

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

  @override
  State<UtenInput> createState() => _UtenInputState();
}

class _UtenInputState extends State<UtenInput> {
  late TextEditingController _controller;
  bool _isObscured = true;
  bool _ownsController = false;
  bool _empty = true;

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
    if (e != _empty) setState(() => _empty = e);
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
  }

  @override
  void dispose() {
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
    final autofilled =
        !_empty && (widget.autofilled || widget.warningMessage != null);

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
                  helper: autofilled && widget.warningMessage != null
                      ? UtenFieldMessage.autofill(widget.warningMessage!)
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
