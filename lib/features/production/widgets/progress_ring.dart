// 圆形进度环（看板/详情页共用）：圆环 + 中间百分比数字。
// 红 <30% / 橙 <70% / 绿 ≥70%；done=true 时显示绿色 ✓。
// 百分比未满 100% 一律向下取整显示（99.8% 显示 99%），绝不虚报 100%。
import 'package:flutter/material.dart';

class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.value,
    this.size = 56,
    this.fontSize = 13,
    this.done = false,
  });

  final double value;
  final double size;
  final double fontSize;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value.clamp(0.0, 1.0);
    // 未满一律 floor：剩余一点也如实显示 99%，只有真正 >=100% 才显示 100%
    final pctText = v >= 1.0 ? '100%' : '${(v * 100).floor()}%';
    final color = done || v >= 0.7
        ? Colors.green
        : v >= 0.3
            ? Colors.orange
            : theme.colorScheme.error;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: v,
            strokeWidth: size / 11,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(color),
          ),
          done
              ? Icon(Icons.check_rounded, size: size * 0.42, color: color)
              : Text(
                  pctText,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
        ],
      ),
    );
  }
}
