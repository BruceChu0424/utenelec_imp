// UtenImportButton - 单据编辑页「从上游引入 / 从应收应付引入」专用按钮。
//
// 背景：旧实现是 TextButton.icon（18px 图标 + 普通文字），现场反馈"看不清"。
// 统一样式（2026-07-29）：深绿底（teal800）+ 白字白图标 + 加大尺寸（16 号字 /
// 20px 图标 / 44+ 触摸目标），四个编辑页（销售/采购/委外/财务）共用。
//
// 高度（2026-09-11）：默认吃表格工具条统一高度 48（UtenTableToolbar.controlHeight），
// 与同排的「表头设置」齐平——本按钮已移进明细表工具条，两者错开 4px 一眼能看出来。
//
// 用法：
//   UtenImportButton(label: '从上游引入', onPressed: _importFromUpstream)
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

class UtenImportButton extends StatelessWidget {
  const UtenImportButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.download_rounded,
    this.height = UtenTableToolbar.controlHeight,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  /// 控件高度。默认与「表头设置」同高（48）。
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: UtenColors.teal800, // 品牌深绿
        foregroundColor: Colors.white,
        disabledBackgroundColor: UtenColors.slate300,
        disabledForegroundColor: Colors.white70,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        minimumSize: Size(0, height),
        fixedSize: Size.fromHeight(height),
        textStyle: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UtenRadius.control),
        ),
      ),
    );
  }
}
