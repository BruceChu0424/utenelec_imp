// 通知页面落点自动已读桥（2026-09-02 建立；2026-09-18 根治重写）。
//
// 用户导航到任何页面时自动清理相关未读通知，双通道互补：
//   ① 精确清理：action_route 恰好指向当前落点的通知（打开单据详情=看过）。
//      后端 /notices/read-by-route 按 action_route 精确匹配，无未读命中时
//      是一次空 upsert，成本可忽略。
//   ② 队列清理：当前落点（或其父队列路径）命中 notice_page_clear_events
//      权威映射时，按该页承载的业务事件集调 /notices/read-by-source。
//      解决「通知指向单据详情、接收人却在队列/工作台看任务」的系统性缺口
//      （财务审批、仓库领料/拣货、IQC 处置、委外全链路等）。
//
// 与既有口径的关系：只置已读，不代办结（resolved_at）与待办完成
// （task_completed_at）；审核弹卡的重弹由 popup_acknowledged/snooze/办结
// 撤回控制。与采购编辑页「保存成功即清理来源申请」的动作级接线互补：
// 桥是「打开即读」，动作级是「做完即读」。
//
// 2026-09-18 重写要点：不再维护内存路由档案（旧 noticeTargetRoutesProvider
// 依赖列表加载/到达派发先登记、重启或离线积压会丢登记）；改为每次落点直接
// 发起幂等清理，无状态、全覆盖。
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/page_resume_provider.dart';
import 'notice_page_clear_events.dart';
import 'notice_providers.dart';

/// 全局桥组件：挂在 app 外壳（MaterialApp.builder 内，与页面树同级），
/// 监听路由落点，命中即触发该页相关通知的自动已读。
class NoticeRouteReadBridge extends ConsumerWidget {
  const NoticeRouteReadBridge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(pageResumeProvider, (previous, next) {
      if (previous == null) return; // 启动首次落定，页面自有初始化
      final location = next.location;
      if (location.isEmpty || location == '/') return;
      final container = ProviderScope.containerOf(context, listen: false);
      // ① 精确清理：action_route 指向当前页面的通知。
      unawaited(markNoticesReadByRoute(container, [location]));
      // ② 队列清理：当前页（或其父队列）承载的业务事件类通知。
      final events = noticeClearEventsForLocation(location);
      if (events.isNotEmpty) {
        unawaited(markNoticesReadBySource(container, events));
      }
    });
    return const SizedBox.shrink();
  }
}
