// 通知 Provider

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
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

Future<void> markNoticeRead(WidgetRef ref, String id) async {
  await ref.read(noticeRepositoryProvider).markRead(id);
  ref.invalidate(noticeDetailProvider(id));
  ref.invalidate(noticeListProvider);
  ref.read(unreadNoticeCountProvider.notifier).refresh();
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
