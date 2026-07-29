// UtenImportButton - 单据编辑页「从上游引入 / 从应收应付引入」专用按钮。
//
// 背景：旧实现是 TextButton.icon（18px 图标 + 普通文字），现场反馈"看不清"。
// 统一样式（2026-07-29）：深绿底（teal800）+ 白字白图标 + 加大尺寸（16 号字 /
// 20px 图标 / 44+ 触摸目标），四个编辑页（销售/采购/委外/财务）共用。
//
// 用法：
//   UtenImportButton(label: '从上游引入', onPressed: _importFromUpstream)
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

class UtenImportButton extends StatelessWidget {
  const UtenImportButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.download_rounded,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
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
        minimumSize: const Size(0, 44),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
