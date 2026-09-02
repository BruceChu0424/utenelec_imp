// 员工端通知到达监听与顶部条调度。
// 文档：docs/02-组件库/UtenNotify.md §七
//
// - 按账号/模拟身份持久化 (publishedAt,id) 游标；首次由服务端补显未读且未确认到达的通知；
// - 每 10s 增量拉取、每分钟全量待确认对账，补回晚提交游标后方的通知；
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
import '../../../shared/providers/shared_providers.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';
import '../providers/notice_route_read_bridge.dart';
import '../repositories/notice_repository.dart';
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
    await ref.read(unreadNoticeCountProvider.notifier).refresh();
  };
});

/// 已登录员工主壳层的通知到达协调器。
///
/// 每个身份先恢复持久化 cursor；首次无 cursor 时由服务端补显全部未读。单飞请求、
/// 循环分页、周期全量对账与 identity generation 防止漏报、重复和跨会话迟到响应。
class NoticeArrivalListener extends ConsumerStatefulWidget {
  const NoticeArrivalListener({
    super.key,
    required this.identityKey,
    required this.child,
    this.pollInterval = const Duration(seconds: 10),
    this.fullAuditInterval = const Duration(minutes: 1),
    this.onArrival,
    this.routeContext,
  });

  final String identityKey;
  final Widget child;
  final Duration pollInterval;
  final Duration fullAuditInterval;
  final NoticeArrivalDispatcher? onArrival;
  final BuildContext? Function()? routeContext;

  @override
  ConsumerState<NoticeArrivalListener> createState() =>
      _NoticeArrivalListenerState();
}

class _NoticeArrivalListenerState extends ConsumerState<NoticeArrivalListener>
    with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _fullAuditTimer;
  bool _fullAuditDue = false;
  bool _cursorLoaded = false;
  NoticeArrivalCursor? _cursor;
  final Set<String> _deliveredIds = <String>{};
  final Set<String> _queuedIds = <String>{};
  final ListQueue<Notice> _pendingArrivals = ListQueue<Notice>();
  final Map<String, Notice> _activeArrivals = <String, Notice>{};
  int _generation = 0;
  int _requestSequence = 0;
  int? _activeRequest;
  Future<void> _persistTail = Future<void>.value();
  String? _lastScheduledSnapshot;
  bool _persistDirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
  }

  @override
  void didUpdateWidget(covariant NoticeArrivalListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityKey != widget.identityKey) {
      _resetForIdentity();
    } else {
      if (oldWidget.pollInterval != widget.pollInterval) {
        _startPolling();
      }
      if (oldWidget.fullAuditInterval != widget.fullAuditInterval) {
        _scheduleFullAudit();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      _dispatchNext();
    } else {
      _generation++;
      _activeRequest = null;
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _fullAuditTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startPolling() {
    _timer?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_poll()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_poll());
      _dispatchNext();
    });
  }

  void _scheduleFullAudit() {
    _fullAuditTimer?.cancel();
    _fullAuditTimer = Timer(widget.fullAuditInterval, () {
      _fullAuditDue = true;
    });
  }

  void _resetForIdentity() {
    _generation++;
    _fullAuditTimer?.cancel();
    _fullAuditTimer = null;
    _fullAuditDue = false;
    _cursorLoaded = false;
    _cursor = null;
    _deliveredIds.clear();
    _queuedIds.clear();
    _pendingArrivals.clear();
    _activeArrivals.clear();
    _lastScheduledSnapshot = null;
    _persistDirty = false;
    // 旧请求仍可在网络层完成，但 generation 会丢弃其结果；新身份不必等待它。
    _activeRequest = null;
    _startPolling();
  }

  Future<void> _poll() async {
    if (!mounted || widget.identityKey.isEmpty || _activeRequest != null) {
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
        _lastScheduledSnapshot = stored == null
            ? null
            : _snapshotSignature(stored, delivered);
        _persistDirty = false;
        _cursorLoaded = true;
        _fullAuditDue = true;
      }

      final fullAudit = _fullAuditDue || _cursor == null;
      var cursor = fullAudit ? null : _cursor;
      final unreadIdsThisAudit = <String>{};
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
          if (notice.id.isEmpty) continue;
          if (!notice.isRead) {
            if (fullAudit) unreadIdsThisAudit.add(notice.id);
            if (!_deliveredIds.contains(notice.id) &&
                _queuedIds.add(notice.id) &&
                seenThisPoll.add(notice.id)) {
              _pendingArrivals.addLast(notice);
              discoveredAny = true;
            }
          }
        }
        _advanceCursor(nextCursor);
        cursor = nextCursor;
        _prioritizePendingArrivals();
        // 增量页可以立即入顶部栈；首次登录/全量审计先拉完全部页再排序，
        // 让低优先级先入栈、重要/紧急最后入栈并保持在视觉最上层。
        if (!fullAudit) _dispatchNext();
        if (!page.hasMore) break;
        pageCount++;
        if (pageCount > 10000) {
          throw StateError('通知到达分页超过安全上限');
        }
      }

      if (fullAudit) {
        final deliveredBefore = _deliveredIds.length;
        _deliveredIds.retainAll(unreadIdsThisAudit);
        if (_deliveredIds.length != deliveredBefore) _persistDirty = true;
        _retainOnlyUnreadPending(unreadIdsThisAudit);
        _fullAuditDue = false;
        _scheduleFullAudit();
      }
      if (discoveredAny) {
        unawaited(ref.read(noticeArrivalRefreshProvider)());
      }
      _prioritizePendingArrivals();
      _dispatchNext();
    } catch (_) {
      // 已成功拉到的页仍留在 pending；失败页之后不会推进。下一次轮询/切前台续取。
    } finally {
      _schedulePersist();
      if (_activeRequest == request) _activeRequest = null;
    }
  }

  void _advanceCursor(NoticeArrivalCursor candidate) {
    final current = _cursor;
    if (current == null || _comesAfter(candidate, current)) {
      _cursor = candidate;
      _persistDirty = true;
    }
  }

  void _retainOnlyUnreadPending(Set<String> unreadIds) {
    if (_pendingArrivals.every((notice) => unreadIds.contains(notice.id))) {
      return;
    }
    final retained = _pendingArrivals
        .where((notice) => unreadIds.contains(notice.id))
        .toList(growable: false);
    _pendingArrivals
      ..clear()
      ..addAll(retained);
    _queuedIds
      ..clear()
      ..addAll(retained.map((notice) => notice.id));
    _queuedIds.addAll(_activeArrivals.keys);
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
    if (!mounted || _pendingArrivals.isEmpty) return;
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
    while (mounted && _pendingArrivals.isNotEmpty) {
      final notice = _pendingArrivals.removeFirst();
      final identityKey = widget.identityKey;
      _activeArrivals[notice.id] = notice;
      void delivered() => _confirmDelivered(identityKey, notice.id);
      try {
        if (injected != null) {
          injected(dispatchContext, notice, delivered);
        } else {
          dispatchNoticeArrival(
            dispatchContext,
            notice,
            onDelivered: delivered,
          );
        }
      } catch (_) {
        // 未成功进入顶部宿主，不确认 delivered；保留在队首，下一轮再试。
        _activeArrivals.remove(notice.id);
        _pendingArrivals.addFirst(notice);
        return;
      }
    }
  }

  void _confirmDelivered(String identityKey, String noticeId) {
    if (!mounted ||
        widget.identityKey != identityKey ||
        !_activeArrivals.containsKey(noticeId)) {
      return;
    }
    _activeArrivals.remove(noticeId);
    _queuedIds.remove(noticeId);
    if (_deliveredIds.add(noticeId)) _persistDirty = true;
    _schedulePersist();
    scheduleMicrotask(() {
      if (mounted && widget.identityKey == identityKey) _dispatchNext();
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
}) {
  // 点击可能发生在来源页切换后：提前捕获 app 级 container、router 与根
  // Navigator context，避免延迟回调读取已失效的 WidgetRef/页面 context。
  final container = ProviderScope.containerOf(context, listen: false);
  final router = onOpenDetail == null ? GoRouter.of(context) : null;
  final detailContext = Navigator.of(context, rootNavigator: true).context;

  // 全局路由桥留档：本条通知的 action_route——用户稍后导航到该路由时由
  // NoticeRouteReadBridge 自动触发已读（含未点开横幅直接去业务页的场景）。
  container.read(noticeTargetRoutesProvider.notifier).recordRoutes([
    notice.actionRoute,
  ]);

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

  // V459 审核待办弹卡：带「去审核/稍后再看」双按钮 + 认领状态行 + 办结自动收卡，
  // 弹前先做一次真态校验（已办结不弹）。与普通顶部条同为非阻塞（ADR-063）。
  if (notice.interactive) {
    unawaited(
      dispatchReviewCard(context, notice, kind: kind, onDelivered: onDelivered),
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
  UtenNotify.banner(
    context,
    title: priorityPrefix == null
        ? sourceTitle
        : '$priorityPrefix · $sourceTitle',
    message: notice.title,
    kind: kind,
    icon: notice.type.icon,
    duration: duration,
    onTap: open,
    onDismissed: onDelivered,
    // 两条不同 Notice 即使标题相同，也必须各自显示；ID 去重由协调器负责。
    force: true,
  );
}

/// V459 审核待办弹卡分派（见 ADR-063 / 方案 D2/D5/D6）。
///
/// 交互契约：
/// - 「去审核」：标已读（R6）→ 跳 actionRoute（域专属审核页；页面内自行认领）。
/// - 「稍后再看」：标已读 + 服务端 snooze 15 分钟（跨设备一致），到点未办结重弹。
/// - 停留期间每 30s 心跳真态校验：他人认领 → 状态行「XX 正在审核」；办结 →
///   自动收卡 + 轻提示「已由 XX 处理」；弹卡本身 20s 到期自然收起（悬停暂停）。
/// - 弹前先校验一次：已办结的待办不弹（R5），也不打扰。
Future<void> dispatchReviewCard(
  BuildContext context,
  Notice notice, {
  required AppNotificationKind kind,
  VoidCallback? onDelivered,
}) async {
  // 与 dispatchNoticeArrival 相同的失效防护：提前捕获容器与根 Navigator context。
  final container = ProviderScope.containerOf(context, listen: false);
  final router = GoRouter.of(context);
  final detailContext = Navigator.of(context, rootNavigator: true).context;
  final repository = container.read(noticeRepositoryProvider);

  container.read(noticeTargetRoutesProvider.notifier).recordRoutes([
    notice.actionRoute,
  ]);

  // 卡片关闭后心跳停止；statusLine 故意不 dispose——收卡动画窗口内卡片仍在监听，
  // 提前 dispose 会崩（数量级为个位 notifier，泄漏可忽略）。
  final statusLine = ValueNotifier<String?>(null);
  Timer? heartbeat;
  var cardId = '';
  var closed = false;

  void stopHeartbeat() {
    heartbeat?.cancel();
    heartbeat = null;
  }

  void closeCard({String? completionMessage}) {
    if (closed) return;
    closed = true;
    stopHeartbeat();
    if (cardId.isNotEmpty) {
      container.read(appNotificationProvider.notifier).dismiss(cardId);
    }
    if (completionMessage != null) {
      container
          .read(appNotificationProvider.notifier)
          .showInfo(completionMessage);
    }
  }

  Future<void> checkOnce({bool silentWhenInitiallyResolved = false}) async {
    if (closed) return;
    try {
      final statuses = await repository.pendingReviewStatus([notice.id]);
      final status = statuses.isEmpty ? null : statuses.first;
      if (status == null) return;
      if (status.resolved) {
        closeCard(
          completionMessage: silentWhenInitiallyResolved
              ? null
              : '「${notice.title}」已由他人处理',
        );
        return;
      }
      statusLine.value = status.claimedByName == null
          ? null
          : '${status.claimedByName} 正在审核';
    } catch (_) {
      // 真态校验失败可容忍：弹卡继续按既有停留时长自然收起。
    }
  }

  // 弹前真态校验：办结的待办不弹（仍算已送达）。
  await checkOnce(silentWhenInitiallyResolved: true);
  if (closed) {
    onDelivered?.call();
    return;
  }

  void navigateToTarget() {
    try {
      if (noticeActionTarget(notice) case final target?) {
        final match = router.configuration.findMatch(Uri.parse(target));
        if (!match.isError) {
          router.go(target);
          return;
        }
      }
    } catch (_) {
      // 历史脏 route 回退详情弹层。
    }
    showNoticeDetailDialog(detailContext, noticeId: notice.id);
  }

  // 经已捕获的容器入队（不跨 async gap 使用 context）。
  cardId = container
      .read(appNotificationProvider.notifier)
      .showMessage(
        notice.title,
        title: '待办 · ${notice.type.label}',
        kind: kind,
        icon: notice.type.icon,
        duration: const Duration(seconds: 20),
        statusLine: statusLine,
        actions: [
          AppNotificationAction(
            label: '去审核',
            filled: true,
            onPressed: () {
              markNoticeReadContainer(container, notice.id).ignore();
              navigateToTarget();
            },
          ),
          AppNotificationAction(
            label: '稍后再看',
            onPressed: () {
              // R6：稍后再看也算已处理提醒；snooze 失败可容忍（下轮到达仍会弹）。
              markNoticeReadContainer(container, notice.id).ignore();
              repository.snooze(notice.id).ignore();
            },
          ),
        ],
        onDismissed: () {
          closed = true;
          stopHeartbeat();
          onDelivered?.call();
        },
        // 同一单据的多份通知（逐人落库）必须各自弹卡；ID 去重由协调器负责。
        force: true,
      );

  heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => checkOnce());

  // 三形态并存（ADR-063 第二轮口径）：通知中心条目（落库即有）+ 顶部通知条
  // （上方，20s 自然收起）+ 居中审核弹窗（主交互：认领状态/去审核/稍后再看；
  // 关闭或办结自动退出）。detailContext 为根 Navigator context（提前捕获，
  // 页面切换不失效；弹前校验后仍挂载才弹）。
  if (detailContext.mounted) {
    unawaited(
      showReviewPendingDialog(detailContext, pending: [notice]).then((_) {
        // 居中弹窗退出后顶部条继续按自身节奏收起/心跳，无需干预。
      }),
    );
  }
}
