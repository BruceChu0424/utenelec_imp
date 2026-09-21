// hub 顶栏右上角的「本模块待办累计」标签。
//
// 2026-09-11 反馈：原来只挂一颗光秃秃的红色数字徽章，用户问「为什么右上角
// 会有个消息数量徽章啊」——它没有任何文字说明自己是什么，位置又在权限设置旁边，
// 看起来像个来路不明的红点。
//
// 现在给它一个自解释的形态：红底白字的「待办 N」小药丸 + 悬停说明，
// 数字仍由 todo_badge_registry 按模块求和得出（页面里不手写加法），
// 0 时整个不渲染（与红徽章口径一致：没有待办就不该有红色）。
//
// 2026-09-21 起它有一枚黄色姊妹 [UtenModuleProgressChip](「进行中 N」，
// 见 uten_module_progress_chip.dart)。两枚并排时**黄在左、红在右**，
// 与 hub 卡右上角的两枚徽章同序。
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_app_bar_action_button.dart';

class UtenModuleTodoChip extends StatelessWidget {
  const UtenModuleTodoChip({super.key, required this.count, this.tooltip});

  /// 本模块待办累计（注册表求和结果）。<= 0 不渲染。
  final int count;

  /// 悬停说明；缺省给一句通用口径。
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
          message: tooltip ?? '本模块待办合计 $count 项（各任务卡待办数之和）',
          child: Semantics(
            label: '本模块待办 $count 项',
            child: ExcludeSemantics(
              child: Container(
                key: const ValueKey('uten-module-todo-chip'),
                constraints: const BoxConstraints(
                  minHeight: UtenAppBarActionButton.height,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error,
                  borderRadius: BorderRadius.circular(UtenRadius.control),
                ),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(
                    '待办 $text',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onError,
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
