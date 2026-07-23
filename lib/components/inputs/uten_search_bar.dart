// UtenSearchBar - 搜索栏（带清除 + 防抖）
// 文档：docs/02-组件库/UtenSearchBar.md（待写）

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
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.debounce = const Duration(milliseconds: 300),
    this.controller,
  });

  final String hint;
  final String? initialValue;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Duration debounce;
  final TextEditingController? controller;

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
    _controller = widget.controller ?? TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () {
      widget.onChanged?.call(value);
    });
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
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: Icon(Icons.search_rounded,
            size: 20, color: theme.colorScheme.onSurfaceVariant),
        suffixIcon: _controller.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                splashRadius: 16,
                onPressed: () {
                  _controller.clear();
                  _onChanged('');
                  widget.onChanged?.call('');
                },
              )
            : null,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      style: theme.textTheme.bodyMedium,
    );
  }
}
