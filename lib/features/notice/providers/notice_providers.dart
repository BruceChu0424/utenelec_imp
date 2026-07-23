// 通知 Provider

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notice.dart';
import '../repositories/mock_notice_repository.dart';

final noticeRepositoryProvider = Provider<MockNoticeRepository>((ref) {
  return MockNoticeRepository();
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

final noticeDetailProvider =
    FutureProvider.autoDispose.family<Notice?, String>((ref, id) async {
  return ref.watch(noticeRepositoryProvider).getById(id);
});

/// 未读数（用于 Dashboard / 徽章）
final unreadNoticeCountProvider = FutureProvider.autoDispose<int>((ref) async {
  ref.watch(noticeListProvider);
  return ref.watch(noticeRepositoryProvider).unreadCount();
});

Future<void> markNoticeRead(WidgetRef ref, String id) async {
  await ref.read(noticeRepositoryProvider).markRead(id);
  ref.invalidate(noticeDetailProvider(id));
  ref.invalidate(noticeListProvider);
  ref.invalidate(unreadNoticeCountProvider);
}

Future<void> markAllNoticeRead(WidgetRef ref) async {
  await ref.read(noticeRepositoryProvider).markAllRead();
  ref.invalidate(noticeListProvider);
  ref.invalidate(unreadNoticeCountProvider);
}
