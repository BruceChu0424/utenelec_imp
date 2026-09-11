import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

class UtenFloatingActionGroup extends StatelessWidget {
  const UtenFloatingActionGroup({
    super.key,
    required this.children,
    this.maxWidth = 1080,
  });

  final List<Widget> children;
  final double maxWidth;

  /// 悬浮组内控件的统一高度。
  ///
  /// 取值 = [UtenButtonSize.large] 的最小高度：组里的业务动作一律用 large，
  /// 而「已选 N 项」胶囊默认按表格工具条的 48 走——两者并排时矮 4px，用户一眼
  /// 就看出来了（2026-09-11 反馈）。这里对每个孩子统一下 minHeight，谁也不用
  /// 记得在调用点传高度；用 min 而非 tight，超大字号下按钮文案换行仍能长高。
  static const double controlHeight = 52;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final availableWidth = (viewportWidth - UtenSpacing.s32)
        .clamp(0.0, maxWidth)
        .toDouble();

    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: availableWidth),
        child: Wrap(
          alignment: WrapAlignment.end,
          runAlignment: WrapAlignment.end,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final child in children)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: UtenElevation.mid(
                    isDark: theme.brightness == Brightness.dark,
                  ),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: controlHeight),
                  child: child,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
