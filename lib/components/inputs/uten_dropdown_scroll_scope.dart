import 'package:flutter/material.dart';

/// 下拉菜单不绘制滚动条，滚轮、触控及键盘仍由原 Scrollable 处理。
///
/// 作用域只包住菜单或菜单触发器；不得包住页面、表格或分类面板。
/// Material 的原生 DropdownButton 会自行创建常显 Scrollbar，并捕获触发器
/// 的 InheritedTheme，因此同时覆盖局部 ScrollbarTheme，避免原生入口漏出。
class UtenDropdownScrollScope extends StatelessWidget {
  const UtenDropdownScrollScope({
    super.key,
    required this.child,
    this.nativeDropdown = false,
  });

  final Widget child;

  /// Flutter 原生 DropdownButton 内置常显滚动条，iOS 上还会忽略滚动条主题。
  /// 仅该遗留菜单采用 Material 绘制，才能遵循全平台一致的无滚动条合同。
  final bool nativeDropdown;

  @override
  Widget build(BuildContext context) {
    final menu = ScrollbarTheme(
      data: ScrollbarTheme.of(context).copyWith(
        thickness: const WidgetStatePropertyAll(0),
        thumbColor: const WidgetStatePropertyAll(Colors.transparent),
        trackColor: const WidgetStatePropertyAll(Colors.transparent),
        trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbVisibility: const WidgetStatePropertyAll(false),
        trackVisibility: const WidgetStatePropertyAll(false),
        interactive: false,
      ),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: child,
      ),
    );
    final theme = Theme.of(context);
    return nativeDropdown && theme.platform == TargetPlatform.iOS
        ? Theme(
            data: theme.copyWith(platform: TargetPlatform.android),
            child: menu,
          )
        : menu;
  }
}
