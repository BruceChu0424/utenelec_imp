// 通知未读索引(ADR-108)——「打开页面要不要自动已读」「到达横幅有没有漏」的本地判定依据。
//
// 服务端摘要(48 位)随工作台徽章汇总每分钟带回; 只有摘要与手里这份索引对不上时才重拉
// GET /notices/unread-index(只有判定用轻量列, 不含正文)。替代原来:
//   · 每次导航都无条件 POST /notices/read-by-route(多数是空写, 落在转场帧里);
//   · 到达监听每分钟从纪元起分页全量对账。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/badges/badge_registry.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../repositories/notice_repository.dart';
import 'notice_providers.dart';

/// 当前会话的未读索引; 未登录或还没拉到过为 null(调用方按「未知」处理)。
final noticeUnreadIndexProvider =
    NotifierProvider<NoticeUnreadIndexNotifier, NoticeUnreadIndex?>(
      NoticeUnreadIndexNotifier.new,
    );

class NoticeUnreadIndexNotifier extends Notifier<NoticeUnreadIndex?> {
  Future<void>? _loading;
  bool _again = false;
  int _generation = 0;

  @override
  NoticeUnreadIndex? build() {
    final scope = ref.watch(authenticatedScopeProvider);
    final generation = ++_generation;
    _loading = null;
    _again = false;
    ref.onDispose(() {
      if (_generation == generation) _generation++;
    });
    if (scope == null) return null;
    // 摘要随徽章汇总到达; 与手里的索引对不上才重拉(首次到达时手里为空, 必拉一次)。
    ref.listen<int?>(
      badgeSummaryProvider.select(
        (s) => s.hasSource('notices') ? s.fact(BadgeFact.noticesDigest) : null,
      ),
      (_, digest) {
        if (digest != null && digest != state?.digest) unawaited(sync());
      },
    );
    scheduleMicrotask(() {
      if (_generation != generation) return;
      final digest = ref
          .read(badgeSummaryProvider)
          .facts[BadgeFact.noticesDigest];
      if (digest != null && digest != state?.digest) unawaited(sync());
    });
    return null;
  }

  /// 重拉索引(单飞; 在途时再调用只在其返回后补一次)。
  Future<void> sync() {
    if (ref.read(authenticatedScopeProvider) == null) {
      return Future<void>.value();
    }
    final loading = _loading;
    if (loading != null) {
      _again = true;
      return loading;
    }
    final generation = _generation;
    final run = _run(generation);
    _loading = run;
    return run;
  }

  Future<void> _run(int generation) async {
    try {
      do {
        _again = false;
        final requestedAt = DateTime.now();
        final index = await ref.read(noticeRepositoryProvider).unreadIndex();
        if (generation != _generation) return;
        state = index.stampedAt(requestedAt);
      } while (_again && generation == _generation);
    } catch (_) {
      // 拉取失败保留旧索引; 下一份汇总摘要到达时再试。
    } finally {
      if (generation == _generation) _loading = null;
    }
  }

  /// 本端置读成功后就地去掉这些条目(服务端摘要随后变化, 下一轮自然对齐)。
  void forget(bool Function(NoticeUnreadItem item) test) {
    final current = state;
    if (current == null) return;
    final next = current.without(test);
    if (!identical(next, current)) state = next;
  }
}
