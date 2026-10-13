import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/badges/badge_registry.dart';
import '../../shared/badges/badge_scope.dart';
import '../../core/theme/uten_tokens.dart';
import 'uten_module_progress_chip.dart';
import 'uten_module_todo_chip.dart';

/// 模块顶栏红黄汇总。页面只声明模块，取数与零值隐藏由公共组件负责。
class UtenModuleBadges extends ConsumerWidget {
  const UtenModuleBadges({super.key, required this.module, this.wrap = false});

  final BadgeModule module;
  final bool wrap;

  /// 手机顶栏将计数放到独立行，给标题、返回和业务动作保留空间。
  /// 无计数时没有底部行；字体放大到两枚不能同行时按实测高度换行。
  static PreferredSizeWidget? compactAppBarBottom(
    BuildContext context,
    WidgetRef ref,
    BadgeModule module,
  ) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 600) return null;
    final counts = ref.watch(
      badgeScopeCountsProvider(BadgeScope.module(module)),
    );
    final labels = [
      if (counts.inProgress > 0)
        '进行中 ${counts.inProgress > 99 ? '99+' : counts.inProgress}',
      if (counts.todo > 0) '待办 ${counts.todo > 99 ? '99+' : counts.todo}',
    ];
    if (labels.isEmpty) return null;
    final available = width - UtenSpacing.s12 * 2;
    final style = DefaultTextStyle.of(context).style.merge(
      Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
    );
    var totalWidth = 0.0;
    var chipHeight = 36.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
      )..layout(maxWidth: math.max(1, available - 28));
      totalWidth += painter.width + 28;
      chipHeight = math.max(chipHeight, painter.height);
      painter.dispose();
    }
    final rows = labels.length > 1 && totalWidth > available ? 2 : 1;
    final height =
        chipHeight * rows + UtenSpacing.s4 * (rows - 1) + UtenSpacing.s8;
    return PreferredSize(
      preferredSize: Size.fromHeight(height),
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s4,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: UtenModuleBadges(module: module, wrap: true),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(
      badgeScopeCountsProvider(BadgeScope.module(module)),
    );
    if (counts.todo <= 0 && counts.inProgress <= 0) {
      return const SizedBox.shrink();
    }
    final children = <Widget>[
      if (counts.inProgress > 0)
        UtenModuleProgressChip(count: counts.inProgress),
      if (counts.todo > 0) UtenModuleTodoChip(count: counts.todo),
    ];
    if (wrap) {
      return Wrap(
        alignment: WrapAlignment.end,
        runSpacing: UtenSpacing.s4,
        children: children,
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}
