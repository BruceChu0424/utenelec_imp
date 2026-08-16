// UtenDocStatusPill - 单据状态药丸（审计 §4.1 第 3 批：六个域内 *_status_badge 的
// 共享渲染层合并）。
//
// 采购/销售/委外/生产/财务单据状态徽章原先各自手搓同款 Container：
// 语义色 12% 底 + 40% 描边 + 圆角 6 + labelSmall w600 同色文字。
// 收敛后域内 badge 只保留 状态→(标签, 颜色) 的映射与复合标签拼接，渲染只维护这一处。
// 与 [UtenStatusBadge] 的分工：后者按语义枚举配色（type 驱动、胶囊圆角），
// 本组件按调用方给定的原始 Material 色渲染（域内 0/1/-1 状态机各自的
// xStatusColor 映射驱动）。
import 'package:flutter/material.dart';

class UtenDocStatusPill extends StatelessWidget {
  const UtenDocStatusPill({
    super.key,
    required this.label,
    required this.color,
  });

  final String label;

  /// 语义色（域内 xStatusColor 解析）：底色 12% 透明、描边 40%、文字原色。
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
