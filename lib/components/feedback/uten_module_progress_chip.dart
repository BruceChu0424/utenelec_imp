// hub 顶栏右上角的「本模块进行中累计」标签 —— [UtenModuleTodoChip] 的黄色姊妹。
//
// 两枚并排时的顺序与 hub 卡右上角一致：**黄(进行中) 在左、红(待办) 在右**
// (2026-09-21 用户口径)。语义分工:
//   · 「待办 N」(红) 回答「我还欠多少活」——不干会出事;
//   · 「进行中 N」(黄) 回答「我手上还有多少在跑」——不用我动手, 但没完。
//
// 与红色那枚同款形态(36dp 最小高度 + UtenRadius.control 圆角 + 悬停说明 +
// 0 不渲染), 只换配色与文案; 数字由 in_progress_badge_registry 按模块求和得出,
// 页面里不手写加法。见 docs/00-项目准则/14-徽章与计数口径.md。

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_app_bar_action_button.dart';

class UtenModuleProgressChip extends StatelessWidget {
  const UtenModuleProgressChip({super.key, required this.count, this.tooltip});

  /// 本模块「进行中」累计(注册表求和结果)。<= 0 不渲染。
  final int count;

  /// 悬停说明; 缺省给一句通用口径。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final text = count > 99 ? '99+' : '$count';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Center(
        child: Tooltip(
          message: tooltip ?? '本模块进行中合计 $count 项(已在办、还没完, 暂不用你动手)',
          child: Semantics(
            label: '本模块进行中 $count 项',
            child: ExcludeSemantics(
              child: Container(
                key: const ValueKey('uten-module-progress-chip'),
                constraints: const BoxConstraints(
                  minHeight: UtenAppBarActionButton.height,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  // 与黄色徽章同一个深琥珀实底 + 白字(2026-09-21 用户口径);
                  // 明暗两档同色, 理由见 UtenColors.warningStrong。
                  color: UtenColors.warningStrong,
                  borderRadius: BorderRadius.circular(UtenRadius.control),
                ),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(
                    '进行中 $text',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
