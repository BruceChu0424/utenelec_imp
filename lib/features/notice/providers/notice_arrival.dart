// 员工端通知到达监听与顶部条调度。
// 文档：docs/02-组件库/UtenNotify.md §七
//
// - 按账号/模拟身份持久化 (publishedAt,id) 游标；首次由服务端补显未读且未确认到达的通知；
// - 前台每 20s 按游标增量拉取(页面隐藏暂停; 徽章汇总提示有新通知时立即拉)；游标后方的
//   遗漏由未读索引摘要驱动补拉，不再每 2s 轮询、每分钟从纪元全量对账(ADR-108)；
// - 所有优先级均进入非阻塞顶部叠放层；重要度只改变视觉与停留时长；
// - 同一批通知逐条跟踪真实关闭回调，点击才标注已读并跳 actionRoute。

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/ui/app_notification.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/providers/app_visibility_provider.dart';
import '../../../shared/providers/shared_providers.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';
import '../repositories/notice_repository.dart';
import 'notice_unread_index_provider.dart';
import '../widgets/notice_detail_dialog.dart';
import '../widgets/review_pending_dialog.dart';

typedef NoticeArrivalLoader =
    Future<NoticeArrivalPage> Function(NoticeArrivalCursor? after);
typedef NoticeArrivalDispatcher =
    void Function(
      BuildContext context,
      Notice notice,
      VoidCallback onDelivered,
    );

/// One foreground arrival page may contain many reviews. Coalesce their final
/// eligibility checks into the existing bounded status endpoint.
final noticeReviewArrivalStatusProvider =
    Provider<Future<PendingReviewStatus?> Function(String)>((ref) {
      final batcher = _ReviewArrivalStatusBatcher(
        ref.watch(noticeRepositoryProvider),
      );
      return batcher.load;
    });

class _ReviewArrivalStatusBatcher {
  _ReviewArrivalStatusBatcher(this._repository);
  final NoticeRepository _repository;
  final _pending = <String, List<Completer<PendingReviewStatus?>>>{};
  bool _scheduled = false;

  Future<PendingReviewStatus?> load(String id) {
    final completer = Completer<PendingReviewStatus?>();
    _pending.putIfAbsent(id, () => []).add(completer);
    if (!_scheduled) {
      _scheduled = true;
      scheduleMicrotask(_drain);
    }
    return completer.future;
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        final batch = <String, List<Completer<PendingReviewStatus?>>>{};
        for (final id in _pending.keys.take(50).toList()) {
          batch[id] = _pending.remove(id)!;
        }
        try {
          final statuses = await _repository.pendingReviewStatus(
            batch.keys.toList(),
          );
          final byId = {for (final status in statuses) status.noticeId: status};
          for (final entry in batch.entries) {
            for (final waiter in entry.value) {
              waiter.complete(byId[entry.key]);
            }
          }
        } catch (error, stack) {
          // Do not fan out more failing HTTP requests for the rest of a burst.
          final failed = [...batch.values, ..._pending.values];
          _pending.clear();
          for (final waiters in failed) {
            for (final waiter in waiters) {
              waiter.completeError(error, stack);
            }
          }
          return;
        }
      }
    } finally {
      _scheduled = false;
    }
  }
}

/// 轻量到达 feed。服务端按 (publishedAt,id) 高水位升序分页，不受置顶排序影响。
/// Provider 单独抽出，既便于 Widget 测试，也为后续 SSE/WebSocket 替换保留同一入口。
final noticeArrivalLoaderProvider = Provider<NoticeArrivalLoader>((ref) {
  final repository = ref.watch(noticeRepositoryProvider);
  return (after) => repository.listArrivals(after: after);
});

abstract interface class NoticeArrivalCursorStore {
  Future<NoticeArrivalCursor?> read(String identityKey);

  Future<Set<String>> readDeliveredIds(String identityKey);

  Future<void> write(
    String identityKey,
    NoticeArrivalCursor cursor,
    Set<String> deliveredIds,
  );
}

class SharedPreferencesNoticeArrivalCursorStore
    implements NoticeArrivalCursorStore {
  SharedPreferencesNoticeArrivalCursorStore(this._preferences);

  final SharedPreferences _preferences;
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  String _key(String identityKey) =>
      'uten.notice.arrival.cursor.v1.'
      '${base64Url.encode(utf8.encode(identityKey))}';

  @override
  Future<NoticeArrivalCursor?> read(String identityKey) async {
    final raw = _preferences.getString(_key(identityKey));
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final publishedAt = DateTime.tryParse(
        json['publishedAt'] as String? ?? '',
      )?.toUtc();
      final id = json['id'] as String?;
      if (publishedAt == null || id == null || !_uuidPattern.hasMatch(id)) {
        return null;
      }
      return NoticeArrivalCursor(publishedAt: publishedAt, id: id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Set<String>> readDeliveredIds(String identityKey) async {
    final raw = _preferences.getString(_key(identityKey));
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final ids = json['deliveredIds'] as List<dynamic>? ?? const <dynamic>[];
      return ids.whereType<String>().where(_uuidPattern.hasMatch).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  @override
  Future<void> write(
    String identityKey,
    NoticeArrivalCursor cursor,
    Set<String> deliveredIds,
  ) async {
    final sortedIds = deliveredIds.toList()..sort();
    final saved = await _preferences.setString(
      _key(identityKey),
      jsonEncode({
        'publishedAt': cursor.publishedAt.toUtc().toIso8601String(),
        'id': cursor.id,
        'deliveredIds': sortedIds,
      }),
    );
    if (!saved) throw StateError('通知到达游标持久化失败');
  }
}

final noticeArrivalCursorStoreProvider = Provider<NoticeArrivalCursorStore>((
  ref,
) {
  return SharedPreferencesNoticeArrivalCursorStore(
    ref.watch(sharedPreferencesProvider),
  );
});

typedef NoticeArrivalRefresh = Future<void> Function();

final noticeArrivalRefreshProvider = Provider<NoticeArrivalRefresh>((ref) {
  return () async {
    ref.invalidate(noticeListProvider);
    await ref.read(badgeSummaryProvider.notifier).refresh();
  };
});

/// 已登录员工主壳层的通知到达协调器。
///
/// 每个身份先恢复持久化 cursor；首次无 cursor 时由服务端补显全部未读。之后只按游标
/// 增量拉取(默认 20 秒一次，页面隐藏时暂停；徽章汇总带回的最新发布时间超过游标时
/// 立即拉一次)。游标后方的遗漏(晚提交、稍后再看到期、在别处读掉)不再每分钟从纪元
/// 全量对账，而是由未读索引摘要驱动：摘要对不上才重拉轻量索引，据此补拉漏掉的、
/// 剔除已不该弹的(ADR-108)。单飞请求、identity generation 防止重复和跨会话迟到响应。
class NoticeArrivalListener extends ConsumerStatefulWidget {
  const NoticeArrivalListener({
    super.key,
    required this.identityKey,
    required this.child,
    this.pollInterval = const Duration(seconds: 20),
    this.onArrival,
    this.routeContext,
  });

  final String identityKey;
  final Widget child;
  final Duration pollInterval;
  final NoticeArrivalDispatcher? onArrival;
  final BuildContext? Function()? routeContext;

  @override
  ConsumerState<NoticeArrivalListener> createState() =>
      _NoticeArrivalListenerState();
}

class _NoticeArrivalListenerState extends ConsumerState<NoticeArrivalListener>
    with WidgetsBindingObserver {
  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  Timer? _timer;
  bool _cursorLoaded = false;
  NoticeArrivalCursor? _cursor;
  final Set<String> _deliveredIds = <String>{};

  /// 本端确认送达的时刻(只在内存): 未读索引对账时, 比索引请求更晚送达的不能剔除。
  final Map<String, DateTime> _deliveredAt = <String, DateTime>{};
  final Set<String> _queuedIds = <String>{};
  final ListQueue<Notice> _pendingArrivals = ListQueue<Notice>();
  final ListQueue<Notice> _pendingReviewArrivals = ListQueue<Notice>();
  bool _normalAuditPending = false;
  final Map<String, Notice> _activeArrivals = <String, Notice>{};
  int _generation = 0;
  int _requestSequence = 0;
  int? _activeRequest;

  /// 送达前校验失败后的单次重试定时器。
  Timer? _retryTimer;
  static const _arrivalRetryDelay = Duration(seconds: 2);

  /// 在途请求期间又来了一次拉取要求(索引对账 / 汇总提示有新通知): 返回后补一次。
  NoticeArrivalCursor? _catchUpFrom;
  bool _pollAgain = false;
  Future<void> _persistTail = Future<void>.value();
  String? _lastScheduledSnapshot;
  bool _persistDirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 未读索引变化(摘要对不上后重拉到的新索引) → 对账: 补拉漏掉的、剔除不该弹的。
    ref.listenManual<NoticeUnreadIndex?>(noticeUnreadIndexProvider, (_, index) {
      if (index != null) _reconcile(index);
    });
    // 徽章汇总带回的最新发布时间超过本地游标 → 有新通知, 不等下一轮立即拉。
    ref.listenManual<int>(
      badgeSummaryProvider.select(
        (s) => s.fact(BadgeFact.noticesLatestPublishedAt),
      ),
      (_, latestMillis) {
        final cursor = _cursor;
        if (latestMillis <= 0 || cursor == null) return;
        if (latestMillis > cursor.publishedAt.millisecondsSinceEpoch) {
          unawaited(_poll());
        }
      },
    );
    _startPolling();
  }

  @override
  void didUpdateWidget(covariant NoticeArrivalListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityKey != widget.identityKey) {
      _resetForIdentity();
    } else if (oldWidget.pollInterval != widget.pollInterval) {
      _startPolling();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (isVisibleLifecycle(state)) {
      _startPolling();
      _dispatchNext();
    } else {
      _generation++;
      _activeRequest = null;
      _timer?.cancel();
      _timer = null;
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startPolling() {
    _timer?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && !isVisibleLifecycle(lifecycle)) return;
    _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_poll()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_poll());
      _dispatchNext();
    });
  }

  void _resetForIdentity() {
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _cursorLoaded = false;
    _cursor = null;
    _deliveredIds.clear();
    _deliveredAt.clear();
    _queuedIds.clear();
    _pendingArrivals.clear();
    _pendingReviewArrivals.clear();
    _normalAuditPending = false;
    _activeArrivals.clear();
    _lastScheduledSnapshot = null;
    _persistDirty = false;
    _catchUpFrom = null;
    _pollAgain = false;
    // 旧请求仍可在网络层完成，但 generation 会丢弃其结果；新身份不必等待它。
    _activeRequest = null;
    _startPolling();
  }

  /// 按未读索引对账(替代原来每分钟从纪元分页的全量对账)。
  void _reconcile(NoticeUnreadIndex index) {
    if (!mounted || !_cursorLoaded) return;
    final requestedAt = index.requestedAt ?? _epoch;
    final pending = <String, NoticeUnreadItem>{
      for (final item in index.items)
        if (item.pendingArrival) item.id: item,
    };
    // 已送达记录只留仍该弹的; 索引请求之后才送达的, 索引看不见, 不能据此剔除。
    final deliveredBefore = _deliveredIds.length;
    _deliveredIds.removeWhere(
      (id) =>
          !pending.containsKey(id) &&
          (_deliveredAt[id] ?? _epoch).isBefore(requestedAt),
    );
    _deliveredAt.removeWhere((id, _) => !_deliveredIds.contains(id));
    if (_deliveredIds.length != deliveredBefore) _persistDirty = true;
    // 排队未弹的: 已被读掉/确认/办结的不再弹; 比索引最新一条还新的, 索引无从判断, 保留。
    final newest = index.latestPublishedAt;
    for (final queue in [_pendingArrivals, _pendingReviewArrivals]) {
      final kept = queue
          .where(
            (notice) =>
                pending.containsKey(notice.id) ||
                newest == null ||
                notice.publishedAt.isAfter(newest),
          )
          .toList(growable: false);
      if (kept.length != queue.length) {
        queue
          ..clear()
          ..addAll(kept);
      }
    }
    _queuedIds
      ..clear()
      ..addAll(_pendingArrivals.map((notice) => notice.id))
      ..addAll(_pendingReviewArrivals.map((notice) => notice.id))
      ..addAll(_activeArrivals.keys);
    // 仍该弹、却既没送达也没在排队的: 游标后方的遗漏, 从最早一条之前补拉一次。
    DateTime? earliest;
    for (final item in pending.values) {
      if (_deliveredIds.contains(item.id) || _queuedIds.contains(item.id)) {
        continue;
      }
      if (earliest == null || item.publishedAt.isBefore(earliest)) {
        earliest = item.publishedAt;
      }
    }
    _schedulePersist();
    if (earliest != null) {
      unawaited(
        _poll(
          from: NoticeArrivalCursor(
            publishedAt: earliest.subtract(const Duration(microseconds: 1)),
            id: NoticeArrivalCursor.zeroId,
          ),
        ),
      );
    }
  }

  /// 拉取到达 feed。[from] 非空 = 从该位置补拉(不回退主游标); 否则按主游标增量拉,
  /// 该身份还没有游标时从头拉一遍(首次登录补显全部未读)。
  Future<void> _poll({NoticeArrivalCursor? from}) async {
    if (!mounted || widget.identityKey.isEmpty) return;
    if (_activeRequest != null) {
      if (from != null) {
        final pendingFrom = _catchUpFrom;
        if (pendingFrom == null || _comesAfter(pendingFrom, from)) {
          _catchUpFrom = from;
        }
      } else {
        _pollAgain = true;
      }
      return;
    }
    final request = ++_requestSequence;
    final generation = _generation;
    final identityKey = widget.identityKey;
    _activeRequest = request;
    try {
      final store = ref.read(noticeArrivalCursorStoreProvider);
      if (!_cursorLoaded) {
        final stored = await store.read(identityKey);
        final delivered = await store.readDeliveredIds(identityKey);
        if (!mounted || generation != _generation) return;
        _cursor = stored;
        _deliveredIds
          ..clear()
          ..addAll(delivered);
        _deliveredAt.clear();
        _lastScheduledSnapshot = stored == null
            ? null
            : _snapshotSignature(stored, delivered);
        _persistDirty = false;
        _cursorLoaded = true;
        // 重启/换身份时未读索引可能早已在手(之后不会再有变化通知): 游标一就绪就
        // 对账一次, 把上次没弹完、仍该弹的补回来。
        final index = ref.read(noticeUnreadIndexProvider);
        if (index != null) scheduleMicrotask(() => _reconcile(index));
      }

      final fullScan = from == null && _cursor == null;
      if (fullScan) _normalAuditPending = true;
      var cursor = from ?? _cursor;
      final seenThisPoll = <String>{};
      var discoveredAny = false;
      var pageCount = 0;
      while (true) {
        final page = await ref.read(noticeArrivalLoaderProvider)(cursor);
        if (!mounted || generation != _generation) return;
        final nextCursor = page.cursor;
        if (cursor != null &&
            (page.items.isNotEmpty || page.hasMore) &&
            !_comesAfter(nextCursor, cursor)) {
          throw StateError('通知到达游标未前进');
        }
        for (final notice in page.items) {
          if (notice.id.isEmpty || notice.isRead) continue;
          if (!_deliveredIds.contains(notice.id) &&
              !_activeArrivals.containsKey(notice.id) &&
              _queuedIds.add(notice.id) &&
              seenThisPoll.add(notice.id)) {
            _queueFor(notice).addLast(notice);
            discoveredAny = true;
          }
        }
        _advanceCursor(nextCursor);
        cursor = nextCursor;
        _prioritizePendingArrivals();
        // 增量页可以立即入顶部栈；首次登录先拉完全部页再排序，
        // 让低优先级先入栈、重要/紧急最后入栈并保持在视觉最上层。
        // Reviews must not wait for every page of old unread announcements.
        _dispatchNext();
        if (!page.hasMore) break;
        pageCount++;
        if (pageCount > 10000) {
          throw StateError('通知到达分页超过安全上限');
        }
      }

      if (fullScan) _normalAuditPending = false;
      if (discoveredAny) {
        unawaited(ref.read(noticeArrivalRefreshProvider)());
      }
      _prioritizePendingArrivals();
      _dispatchNext();
    } catch (_) {
      // 已成功拉到的页仍留在 pending；失败页之后不会推进。下一次轮询/切前台续取。
      _normalAuditPending = false;
    } finally {
      _schedulePersist();
      if (_activeRequest == request) {
        _activeRequest = null;
        final catchUp = _catchUpFrom;
        final again = _pollAgain;
        _catchUpFrom = null;
        _pollAgain = false;
        if (mounted && generation == _generation) {
          if (catchUp != null) {
            unawaited(_poll(from: catchUp));
          } else if (again) {
            unawaited(_poll());
          }
        }
      }
    }
  }

  void _advanceCursor(NoticeArrivalCursor candidate) {
    final current = _cursor;
    if (current == null || _comesAfter(candidate, current)) {
      _cursor = candidate;
      _persistDirty = true;
    }
  }

  void _prioritizePendingArrivals() {
    if (_pendingArrivals.length < 2) return;
    final sorted = _pendingArrivals.toList(growable: false)
      ..sort((left, right) {
        // 顶部栈是“后入在上”：低优先级先派发，important / urgent 后派发，
        // 最终仍由最高优先级位于最上层；同级按时间由旧到新入栈。
        final byPriority = _noticePriorityRank(
          left.priority,
        ).compareTo(_noticePriorityRank(right.priority));
        if (byPriority != 0) return byPriority;
        final byTime = left.publishedAt.compareTo(right.publishedAt);
        return byTime != 0 ? byTime : left.id.compareTo(right.id);
      });
    _pendingArrivals
      ..clear()
      ..addAll(sorted);
  }

  int _noticePriorityRank(NoticePriority priority) => switch (priority) {
    NoticePriority.urgent => 2,
    NoticePriority.important => 1,
    NoticePriority.normal => 0,
  };

  void _dispatchNext() {
    if (!mounted ||
        (_pendingReviewArrivals.isEmpty &&
            (_normalAuditPending || _pendingArrivals.isEmpty))) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;

    final routedContext = widget.routeContext?.call();
    if (widget.routeContext != null && routedContext == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _dispatchNext();
      });
      return;
    }

    final dispatchContext = routedContext ?? context;
    final injected = widget.onArrival;
    while (mounted &&
        (_pendingReviewArrivals.isNotEmpty ||
            (!_normalAuditPending && _pendingArrivals.isNotEmpty))) {
      final notice = _pendingReviewArrivals.isNotEmpty
          ? _pendingReviewArrivals.removeFirst()
          : _pendingArrivals.removeFirst();
      final identityKey = widget.identityKey;
      final generation = _generation;
      _activeArrivals[notice.id] = notice;
      void delivered() => _confirmDelivered(identityKey, generation, notice.id);
      try {
        if (injected != null) {
          injected(dispatchContext, notice, delivered);
        } else {
          dispatchNoticeArrival(
            dispatchContext,
            notice,
            onDelivered: delivered,
            onRetry: () => _retryArrival(identityKey, generation, notice),
            isCurrent: () => _isDeliveryCurrent(identityKey, generation),
          );
        }
      } catch (_) {
        // 未成功进入顶部宿主，不确认 delivered；保留在队首，下一轮再试。
        _activeArrivals.remove(notice.id);
        _queueFor(notice).addFirst(notice);
        return;
      }
    }
  }

  ListQueue<Notice> _queueFor(Notice notice) =>
      notice.interactive ? _pendingReviewArrivals : _pendingArrivals;

  bool _isDeliveryCurrent(String identityKey, int generation) =>
      mounted && widget.identityKey == identityKey && generation == _generation;

  void _retryArrival(String identityKey, int generation, Notice notice) {
    if (!_isDeliveryCurrent(identityKey, generation)) return;
    if (_activeArrivals.remove(notice.id) == null) return;
    _queueFor(notice).addLast(notice);
    // 送达前校验暂时失败: 约 2 秒后单次重试(不是紧循环, 也不等 20 秒一轮的轮询);
    // 游标可以前进, 但该条没记送达、仍在队列里。
    _retryTimer ??= Timer(_arrivalRetryDelay, () {
      _retryTimer = null;
      if (_isDeliveryCurrent(identityKey, generation)) _dispatchNext();
    });
  }

  void _confirmDelivered(String identityKey, int generation, String noticeId) {
    if (!_isDeliveryCurrent(identityKey, generation) ||
        !_activeArrivals.containsKey(noticeId)) {
      return;
    }
    _activeArrivals.remove(noticeId);
    _queuedIds.remove(noticeId);
    _deliveredAt[noticeId] = DateTime.now();
    if (_deliveredIds.add(noticeId)) _persistDirty = true;
    _schedulePersist();
    scheduleMicrotask(() {
      if (_isDeliveryCurrent(identityKey, generation)) _dispatchNext();
    });
  }

  void _schedulePersist() {
    if (!mounted || !_persistDirty) return;
    final cursor = _cursor;
    if (cursor == null) return;
    final identityKey = widget.identityKey;
    final delivered = Set<String>.of(_deliveredIds);
    final snapshot = _snapshotSignature(cursor, delivered);
    if (snapshot == _lastScheduledSnapshot) {
      _persistDirty = false;
      return;
    }
    final store = ref.read(noticeArrivalCursorStoreProvider);
    _lastScheduledSnapshot = snapshot;
    _persistDirty = false;
    _persistTail = _persistTail.then((_) async {
      try {
        await store.write(identityKey, cursor, delivered);
      } catch (_) {
        if (mounted &&
            widget.identityKey == identityKey &&
            _lastScheduledSnapshot == snapshot) {
          _lastScheduledSnapshot = null;
          _persistDirty = true;
        }
      }
    });
  }

  String _snapshotSignature(NoticeArrivalCursor cursor, Set<String> delivered) {
    final ids = delivered.toList()..sort();
    return '${cursor.publishedAt.toUtc().toIso8601String()}|${cursor.id}|'
        '${ids.join(',')}';
  }

  bool _comesAfter(NoticeArrivalCursor candidate, NoticeArrivalCursor current) {
    final byTime = candidate.publishedAt.compareTo(current.publishedAt);
    return byTime > 0 ||
        (byTime == 0 && candidate.id.compareTo(current.id) > 0);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 分派一条新到达通知。
///
/// 所有优先级都进入非阻塞顶部叠放层。important / urgent 仅使用更强语义色和更长
/// 停留时间，不再默认弹出会中断仓库、生产等当前操作的居中窗口。
void dispatchNoticeArrival(
  BuildContext context,
  Notice notice, {
  VoidCallback? onOpenDetail,
  VoidCallback? onDelivered,
  VoidCallback? onRetry,
  bool Function()? isCurrent,
}) {
  // 点击可能发生在来源页切换后：提前捕获 app 级 container、router 与根
  // Navigator context，避免延迟回调读取已失效的 WidgetRef/页面 context。
  // （页面落点的自动已读由 NoticeRouteReadBridge 统一驱动，此处不留档。）
  final container = ProviderScope.containerOf(context, listen: false);
  final router = onOpenDetail == null ? GoRouter.of(context) : null;
  final detailContext = Navigator.of(context, rootNavigator: true).context;

  void markRead() {
    // fire-and-forget：标注已读失败可容忍，角标/列表在下次轮询（60s）自愈。
    markNoticeReadContainer(container, notice.id).ignore();
  }

  void navigateToTarget() {
    try {
      if (noticeActionTarget(notice) case final target?) {
        final match = router!.configuration.findMatch(Uri.parse(target));
        if (!match.isError) {
          router.go(target);
          return;
        }
      }
    } catch (_) {
      // 历史脏 route 不应让通知无法打开；统一回退详情弹层。
    }
    showNoticeDetailDialog(detailContext, noticeId: notice.id);
  }

  void open() {
    markRead();
    if (onOpenDetail != null) {
      onOpenDetail();
    } else {
      navigateToTarget();
    }
  }

  final (kind, duration, priorityPrefix) = switch (notice.priority) {
    NoticePriority.urgent => (
      AppNotificationKind.error,
      const Duration(seconds: 8),
      '紧急',
    ),
    NoticePriority.important => (
      AppNotificationKind.warning,
      const Duration(seconds: 6),
      '重要',
    ),
    NoticePriority.normal => (
      AppNotificationKind.info,
      notice.type.isCelebratory
          ? const Duration(seconds: 5)
          : const Duration(seconds: 4),
      null,
    ),
  };

  // V459 审核待办：顶部纯显示条 + 居中审核弹窗（主交互在弹窗内），
  // 弹前先做一次真态校验（已办结不弹）。与普通顶部条同为非阻塞（ADR-063）。
  if (notice.interactive) {
    unawaited(
      dispatchReviewCard(
        context,
        notice,
        kind: kind,
        onDelivered: onDelivered,
        onRetry: onRetry,
        isCurrent: isCurrent,
      ),
    );
    return;
  }

  final sourceTitle = notice.type.isCelebratory
      ? notice.subjectName != null
            ? '${notice.type.label}祝福 · ${notice.subjectName}'
            : '${notice.type.label}祝福'
      : notice.type.isWork
      ? '${notice.type.label} · ${notice.publisher}'
      : notice.publisher;
  // 人工打卡类通知（人事手动发布 + acknowledge 模式）在线到达时顶部条内联
  // 【打卡确认】：点击即回执（幂等），不必进详情；失败顶部报错，登录弹窗兜底。
  final requiresManualAck = manualAckPending(notice);
  UtenNotify.banner(
    context,
    title: priorityPrefix == null
        ? sourceTitle
        : '$priorityPrefix · $sourceTitle',
    message: notice.title,
    kind: kind,
    icon: notice.type.icon,
    // 待打卡的条目多留几秒，给用户点按钮的时间。
    duration: requiresManualAck ? const Duration(seconds: 12) : duration,
    onTap: open,
    onDismissed: onDelivered,
    actions: requiresManualAck
        ? [
            AppNotificationAction(
              label: '打卡确认',
              filled: true,
              onPressed: () => acknowledgeNoticeInline(container, notice.id),
            ),
          ]
        : null,
    // 两条不同 Notice 即使标题相同，也必须各自显示；ID 去重由协调器负责。
    force: true,
  );
}

/// 是否为「待打卡的人工通知」：人事手动发布（无 source_event）、acknowledge 模式、
/// 本人尚未打卡。系统链路的 system/urgent 通知不在此列（无打卡义务）。
bool manualAckPending(Notice notice) =>
    notice.sourceEvent == null &&
    notice.interactionMode == NoticeInteractionMode.acknowledge &&
    !notice.myAcked;

/// 顶部到达条内联打卡（与登录弹窗共用同一 acknowledge 端点）。取
/// [ProviderContainer] 而非 WidgetRef：按钮回调可能在来源页销毁后触发。
/// 成功刷新列表/详情缓存，**不另弹成功条**——按钮动作后卡片自身收起即反馈；
/// 收起动画期间若再入队一条新弹条，宿主折叠态只挂载最上层一张，原卡会被
/// 中途卸载而丢失 onDismissed（送达确认），并在新条消失后重新露出。
/// 失败顶部报错（不抛出——弹条动作回调无 await 语义），原卡随后重新露出可重试，
/// 登录弹窗也会兜底。
Future<void> acknowledgeNoticeInline(
  ProviderContainer container,
  String noticeId,
) async {
  try {
    await container.read(noticeRepositoryProvider).acknowledge(noticeId);
    container.invalidate(noticeListProvider);
    container.invalidate(noticeDetailProvider(noticeId));
  } catch (_) {
    container
        .read(appNotificationProvider.notifier)
        .showError('打卡失败，请稍后在通知中心或登录提醒中重试', force: true);
  }
}

/// V459 审核待办弹卡分派（见 ADR-063 / 方案 D2/D5/D6）。
///
/// 交互契约（2026-09-03 口径修订）：
/// - 主交互全部由同时弹出的居中审核弹窗承载（认领状态心跳/去审核/稍后再看）；
/// - 顶部条降级为纯显示——不带操作按钮与状态行，8s 自然收起，
///   避免同一待办在两处出现重复的「去审核」按钮；
/// - 弹前先校验一次：已办结的待办不弹，也不打扰。
Future<void> dispatchReviewCard(
  BuildContext context,
  Notice notice, {
  required AppNotificationKind kind,
  VoidCallback? onDelivered,
  VoidCallback? onRetry,
  bool Function()? isCurrent,
}) async {
  // 与 dispatchNoticeArrival 相同的失效防护：提前捕获容器与根 Navigator context。
  final container = ProviderScope.containerOf(context, listen: false);
  final detailContext = Navigator.of(context, rootNavigator: true).context;
  final reviewGeneration = reviewPendingDialogGeneration;

  // 弹前真态校验：办结的待办不弹（仍算已送达）。
  try {
    final status = await container.read(noticeReviewArrivalStatusProvider)(
      notice.id,
    );
    if (isCurrent?.call() == false) return;
    if (status == null || status.resolved) {
      onDelivered?.call();
      return;
    }
  } catch (_) {
    // A failed authorization/status check cannot authorize an actionable popup.
    onRetry?.call();
    return;
  }
  if (!detailContext.mounted ||
      reviewGeneration != reviewPendingDialogGeneration) {
    return;
  }

  // 纯显示顶部条：无按钮/状态行，8s 自然收起（悬停暂停有 8s 上限）。
  // 2026-09-12 用户口径：待办/审批顶部条也要「显示一会就消失」——原 20s 停留
  // 在积压多条时近乎常驻；主交互本就在居中审核弹窗，顶部条只做到达提醒。
  container
      .read(appNotificationProvider.notifier)
      .showMessage(
        notice.title,
        title: '待办 · ${notice.type.label}',
        kind: kind,
        icon: notice.type.icon,
        duration: const Duration(seconds: 8),
        onDismissed: onDelivered,
        // 同一单据的多份通知（逐人落库）必须各自弹卡；ID 去重由协调器负责。
        force: true,
      );

  // 三形态并存（ADR-063 第二轮口径）：通知中心条目（落库即有）+ 顶部通知条
  // （纯显示，8s 自然收起）+ 居中审核弹窗（主交互：认领状态/去审核/稍后再看；
  // 关闭或办结自动退出）。detailContext 为根 Navigator context（提前捕获，
  // 页面切换不失效；弹前校验后仍挂载才弹）。
  if (detailContext.mounted) {
    unawaited(
      showReviewPendingDialog(detailContext, pending: [notice]).then((_) {
        // 居中弹窗退出后顶部条继续按自身节奏收起，无需干预。
      }),
    );
  }
}
