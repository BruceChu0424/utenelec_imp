// 通知目标路由桥（2026-09-02）：把通知的 action_route 在客户端留档，用户导航
// 到任何有通知指向的路由时自动触发 read-by-route 已读清理——一劳永逸覆盖
// 所有「有通知显示」的页面（含未来新增的通知路由），无需逐页接线。
//
// 数据流：
//   通知列表加载（未读）──┐
//   通知到达派发（全部）──┴→ noticeTargetRoutesProvider（内存 Set，path 归一）
//   app_router 路由落定 → bumpPageResume(pageResumeProvider)
//   NoticeRouteReadBridge 监听落点 ∈ Set → markNoticesReadByRoute([落点])
//     → 清单/未读数刷新 → 列表重建按最新未读重新留档（闭环）。
//
// 与采购编辑页「保存成功即清理来源申请」的动作级接线互补：桥是「打开即读」，
// 动作级是「做完即读」（清理从未打开过的单据路由）。
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/page_resume_provider.dart';
import 'notice_providers.dart';

/// 已知「有通知指向」的路由集合（path，不含 query）。内存态：app 启动后由
/// 通知列表加载与到达派发填充，重启后靠新一轮列表/到达自然重建。
final noticeTargetRoutesProvider =
    NotifierProvider<NoticeTargetRoutesNotifier, Set<String>>(
      NoticeTargetRoutesNotifier.new,
    );

class NoticeTargetRoutesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  /// 记录一批通知的 action_route（忽略空值；去 query 归一为 path）。
  void recordRoutes(Iterable<String?> routes) {
    var added = false;
    final next = {...state};
    for (final route in routes) {
      if (route == null || route.isEmpty) continue;
      final path = Uri.parse(route).path;
      if (path.isEmpty || path == '/') continue;
      if (next.add(path)) added = true;
    }
    if (added) state = next;
  }

  /// 消费一个已处理的路由：清理成功后移出集合，避免同一路由反复触发；
  /// 该路由再有新通知到达/列表出现未读时会重新记录。
  void consume(String path) {
    if (!state.contains(path)) return;
    final next = {...state}..remove(path);
    state = next;
  }
}

/// 全局桥组件：挂在 app 外壳（MaterialApp.builder 内，与页面树同级），
/// 监听路由落点，命中留档路由即触发该路由通知的自动已读。
class NoticeRouteReadBridge extends ConsumerWidget {
  const NoticeRouteReadBridge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(pageResumeProvider, (previous, next) {
      if (previous == null) return; // 启动首次落定，页面自有初始化
      final location = next.location;
      final targets = ref.read(noticeTargetRoutesProvider);
      if (!targets.contains(location)) return;
      final container = ProviderScope.containerOf(context, listen: false);
      ref.read(noticeTargetRoutesProvider.notifier).consume(location);
      // markNoticesReadByRoute 内部失败静默：已读清理是增强行为，不打断导航；
      // 失败后该路由已消费，待新通知到达或列表未读重建时再有机会清理。
      unawaited(markNoticesReadByRoute(container, [location]));
    });
    return const SizedBox.shrink();
  }
}
