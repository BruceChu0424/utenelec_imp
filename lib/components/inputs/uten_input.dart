// UtenInput - 通用输入框（文本/密码/搜索 + 客户端校验）
// 文档：docs/02-组件库/UtenInput.md（待写）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Uten 输入框
class UtenInput extends StatefulWidget {
  const UtenInput({
    super.key,
    this.label,
    this.hint,
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
  });

  /// 标签
  final String? label;

  /// 占位提示
  final String? hint;

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

  @override
  State<UtenInput> createState() => _UtenInputState();
}

class _UtenInputState extends State<UtenInput> {
  late final TextEditingController _controller;
  bool _isObscured = true;
  bool _wasEverInitialized = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    _isObscured = widget.isPassword;
    _wasEverInitialized = widget.controller == null;
  }

  @override
  void dispose() {
    if (_wasEverInitialized) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          // 标签
          Text(
            widget.label!,
            style: theme.textTheme.bodyMedium?.copyWith(
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
          onChanged: widget.onChanged,
          onFieldSubmitted: widget.onFieldSubmitted,
          enabled: widget.enabled,
          maxLines: widget.obscureText ? 1 : widget.maxLines,
          textInputAction: widget.textInputAction,
          focusNode: widget.focusNode,
          autofillHints: widget.autofillHints,
          inputFormatters: widget.inputFormatters,
          textCapitalization: widget.textCapitalization,
          style: theme.textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: widget.prefixIcon != null
                ? Icon(widget.prefixIcon, size: 20)
                : null,
            suffixIcon: _buildSuffix(),
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
        onPressed: () => setState(() => _isObscured = !_isObscured),
        splashRadius: 18,
      );
    }
    if (widget.suffixIcon != null) {
      return Icon(widget.suffixIcon, size: 20);
    }
    return null;
  }
}
