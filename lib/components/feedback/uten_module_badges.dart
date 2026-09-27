import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/badges/badge_registry.dart';
import '../../shared/badges/badge_scope.dart';
import 'uten_module_progress_chip.dart';
import 'uten_module_todo_chip.dart';

/// 模块顶栏红黄汇总。页面只声明模块，取数与零值隐藏由公共组件负责。
class UtenModuleBadges extends ConsumerWidget {
  const UtenModuleBadges({super.key, required this.module});

  final BadgeModule module;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(
      badgeScopeCountsProvider(BadgeScope.module(module)),
    );
    if (counts.todo <= 0 && counts.inProgress <= 0) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (counts.inProgress > 0)
          UtenModuleProgressChip(count: counts.inProgress),
        if (counts.todo > 0) UtenModuleTodoChip(count: counts.todo),
      ],
    );
  }
}
