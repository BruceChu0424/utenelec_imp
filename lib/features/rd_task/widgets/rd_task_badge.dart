// 工程研发部任务中心待完成任务数徽章（工作台「工程研发部」卡片用）。
// 数据源 rdTaskCountProvider（60s 轮询 /rd-tasks/count）；count<=0 时不渲染。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_notification_badge.dart';
import '../providers/rd_task_count_provider.dart';

class RdTaskBadge extends ConsumerWidget {
  const RdTaskBadge({super.key, this.size = 16, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(rdTaskCountProvider);
    return UtenNotificationBadge(count: count, size: size, showLabel: showLabel);
  }
}
