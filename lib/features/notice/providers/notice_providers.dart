// 通知 Provider

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/router/route_names.dart';
import '../models/notice.dart';
import '../repositories/notice_repository.dart';

final noticeRepositoryProvider = Provider<NoticeRepository>((ref) {
  return DioNoticeRepository(ref.watch(apiClientProvider));
});

/// 筛选：全部 / 仅未读 / 仅置顶
enum NoticeFilter { all, unread }

extension NoticeFilterValue on NoticeFilter {
  String get label => switch (this) {
    NoticeFilter.all => '全部',
    NoticeFilter.unread => '未读',
  };
}

final noticeFilterProvider = StateProvider<NoticeFilter>((ref) {
  return NoticeFilter.all;
});

final noticeListProvider =
    AsyncNotifierProvider.autoDispose<NoticeListNotifier, List<Notice>>(
      NoticeListNotifier.new,
    );

class NoticeListNotifier extends AutoDisposeAsyncNotifier<List<Notice>> {
  @override
  Future<List<Notice>> build() async {
    final filter = ref.watch(noticeFilterProvider);
    final repo = ref.watch(noticeRepositoryProvider);
    return repo.list(onlyUnread: filter == NoticeFilter.unread);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() {
      final filter = ref.read(noticeFilterProvider);
      return ref
          .read(noticeRepositoryProvider)
          .list(onlyUnread: filter == NoticeFilter.unread);
    });
  }
}

final noticeDetailProvider = FutureProvider.autoDispose.family<Notice?, String>(
  (ref, id) async {
    return ref.watch(noticeRepositoryProvider).getById(id);
  },
);

const Duration _kUnreadPollInterval = Duration(seconds: 60);

/// 通知未读数（Dashboard / 徽章用）：默认 60s 轮询一次；网络/服务异常时保留旧值，
/// 避免徽章闪烁。范式同 lib/features/visitor_approval/providers/visitor_pending_count_provider.dart。
/// 通知人人可见（employee 自带 notice:read），故不按权限短路。
final unreadNoticeCountProvider =
    StateNotifierProvider<UnreadNoticeCountNotifier, int>((ref) {
      final notifier = UnreadNoticeCountNotifier(ref);
      notifier.start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class UnreadNoticeCountNotifier extends StateNotifier<int> {
  UnreadNoticeCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;

  void start() {
    _tick();
    _timer = Timer.periodic(_kUnreadPollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    try {
      final count = await ref.read(noticeRepositoryProvider).unreadCount();
      state = count;
    } catch (_) {
      // 网络/服务异常时保留旧值，避免徽章闪烁
    }
  }

  /// 立即刷新（标记已读 / 删除 / 发布 / 业务桥动作完成后调用）。
  Future<void> refresh() => _tick();
}

/// 通知「对应页面」目标路由：[Notice.actionRoute] 附加 `returnTo=/notice`，
/// 便于目标页返回键回到通知列表。无 actionRoute 时返回 null（回退详情弹层）。
///
/// 通知到达横幅点击（[dispatchNoticeArrival]）与 `NoticeDetailPage._goAction`
/// 共用本逻辑，保证两者跳转完全一致。放在本文件以避免 notice_arrival ↔
/// notice_detail_page 经 notice_detail_dialog 形成循环 import。
String? noticeActionTarget(Notice notice) {
  final route = notice.actionRoute;
  if (route == null || route.isEmpty) return null;
  final uri = Uri.parse(route);
  final params = Map<String, String>.from(uri.queryParameters)
    ..['returnTo'] = RouteName.notice;
  return uri.replace(queryParameters: params).toString();
}

Future<void> markNoticeRead(WidgetRef ref, String id) async {
  await ref.read(noticeRepositoryProvider).markRead(id);
  ref.invalidate(noticeDetailProvider(id));
  ref.invalidate(noticeListProvider);
  ref.read(unreadNoticeCountProvider.notifier).refresh();
}

/// 与 [markNoticeRead] 等价，但取 `ProviderContainer` 而非 `WidgetRef`。
///
/// 用于「通知到达横幅点击」等异步延迟触发场景：横幅的 onTap 可能在来源页
/// 已 dispose 后数分钟才触发，此时其 `WidgetRef` 已失效（再 read 会抛
/// StateError）。`ProviderContainer` 由 `ProviderScope.containerOf` 在派发
/// 时捕获，随 app 生命周期稳定，跨异步安全。
Future<void> markNoticeReadContainer(
  ProviderContainer container,
  String id,
) async {
  await container.read(noticeRepositoryProvider).markRead(id);
  container.invalidate(noticeDetailProvider(id));
  container.invalidate(noticeListProvider);
  container.read(unreadNoticeCountProvider.notifier).refresh();
}

Future<void> completeNoticeTodo(WidgetRef ref, String id) async {
  await ref.read(noticeRepositoryProvider).completeTodo(id);
  ref.invalidate(noticeDetailProvider(id));
  ref.invalidate(noticeListProvider);
  ref.read(unreadNoticeCountProvider.notifier).refresh();
}

Future<void> markAllNoticeRead(WidgetRef ref) async {
  await ref.read(noticeRepositoryProvider).markAllRead();
  ref.invalidate(noticeListProvider);
  ref.read(unreadNoticeCountProvider.notifier).refresh();
}

/// 批量删除（从当前用户列表移除），返回实际删除条数
Future<int> deleteNotices(WidgetRef ref, List<String> ids) async {
  final deleted = await ref.read(noticeRepositoryProvider).deleteMany(ids);
  ref.invalidate(noticeListProvider);
  ref.read(unreadNoticeCountProvider.notifier).refresh();
  return deleted;
}

/// 祝福墙分页（详情页 / 全部祝福弹层用）。
final noticeBlessingsProvider = FutureProvider.autoDispose
    .family<List<NoticeBlessing>, String>((ref, id) async {
      return ref.watch(noticeRepositoryProvider).listBlessings(id, size: 50);
    });

/// 当前用户「今日庆典」（登录弹窗 + 今日概览庆典卡片）。
/// 服务端按 birth/hire date + 今日庆典通知判定；不含任何日期原值（PII 安全）。
final myCelebrationTodayProvider =
    FutureProvider.autoDispose<List<MyCelebrationToday>>((ref) async {
      return ref.watch(noticeRepositoryProvider).myCelebrationToday();
    });

/// 「点击收到」回执（acknowledge 模式）。完成后失效详情+列表。
Future<void> acknowledgeNotice(WidgetRef ref, String id) async {
  await ref.read(noticeRepositoryProvider).acknowledge(id);
  ref.invalidate(noticeDetailProvider(id));
  ref.invalidate(noticeListProvider);
}

/// 「送上祝福」（bless 模式）。完成后失效详情+列表+祝福墙。
Future<void> blessNotice(WidgetRef ref, String id, String content) async {
  await ref.read(noticeRepositoryProvider).bless(id, content);
  ref.invalidate(noticeDetailProvider(id));
  ref.invalidate(noticeListProvider);
  ref.invalidate(noticeBlessingsProvider(id));
}
