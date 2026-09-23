// 通知仓库（真实后端）
// 后端：server .../features/notice/NoticeController（/api/notices）

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/notice.dart';
import '../models/notice_audience.dart';

class NoticeArrivalCursor {
  const NoticeArrivalCursor({required this.publishedAt, required this.id});

  static const zeroId = '00000000-0000-0000-0000-000000000000';

  final DateTime publishedAt;
  final String id;
}

class NoticeArrivalPage {
  const NoticeArrivalPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });

  final List<Notice> items;
  final NoticeArrivalCursor cursor;
  final bool hasMore;
}

/// 未读索引项: 判定「打开页面要不要自动已读」「到达横幅有没有漏」用的轻量列(无正文)。
class NoticeUnreadItem {
  const NoticeUnreadItem({
    required this.id,
    required this.publishedAt,
    this.actionRoute,
    this.sourceEvent,
    this.pendingArrival = false,
  });

  factory NoticeUnreadItem.fromJson(Map<String, dynamic> json) =>
      NoticeUnreadItem(
        id: json['id'] as String? ?? '',
        publishedAt:
            DateTime.tryParse(json['publishedAt'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        actionRoute: json['actionRoute'] as String?,
        sourceEvent: json['sourceEvent'] as String?,
        pendingArrival: json['pendingArrival'] as bool? ?? false,
      );

  final String id;
  final DateTime publishedAt;
  final String? actionRoute;
  final String? sourceEvent;

  /// 仍应弹到达横幅(未读、未确认弹窗、未办结、稍后已到期)。
  final bool pendingArrival;
}

/// 当前用户全部可见未读通知的索引 + 服务端摘要(ADR-108)。
///
/// 摘要随工作台徽章汇总每分钟带回; 与这里的 [digest] 对不上才重拉本索引。
class NoticeUnreadIndex {
  const NoticeUnreadIndex({
    required this.unreadCount,
    required this.digest,
    required this.items,
    this.requestedAt,
  });

  factory NoticeUnreadIndex.fromJson(Map<String, dynamic> json) =>
      NoticeUnreadIndex(
        unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
        digest: (json['digest'] as num?)?.toInt() ?? 0,
        items: [
          for (final item in json['items'] as List<dynamic>? ?? const [])
            if (item is Map<String, dynamic>) NoticeUnreadItem.fromJson(item),
        ],
      );

  final int unreadCount;
  final int digest;
  final List<NoticeUnreadItem> items;

  /// 本端发出这次索引请求的时刻: 此后才到达/确认的通知不在索引里, 对账时不能据此剔除。
  final DateTime? requestedAt;

  /// 索引里最新一条的发布时间(比它更新的通知, 这份索引无从判断)。
  DateTime? get latestPublishedAt =>
      items.isEmpty ? null : items.last.publishedAt;

  NoticeUnreadIndex stampedAt(DateTime at) => NoticeUnreadIndex(
    unreadCount: unreadCount,
    digest: digest,
    items: items,
    requestedAt: at,
  );

  /// 有 action_route 恰好指向 [route] 的未读通知。
  bool hasRoute(String route) => items.any((item) => item.actionRoute == route);

  /// 有来自 [events] 任一业务事件的未读通知。
  bool hasSourceEvent(Iterable<String> events) {
    final wanted = events.toSet();
    return items.any(
      (item) => item.sourceEvent != null && wanted.contains(item.sourceEvent),
    );
  }

  /// 去掉本端已置读的条目(服务端摘要随后会变, 下一轮自然对齐)。
  NoticeUnreadIndex without(bool Function(NoticeUnreadItem item) test) {
    final kept = items.where((item) => !test(item)).toList(growable: false);
    if (kept.length == items.length) return this;
    return NoticeUnreadIndex(
      unreadCount: unreadCount - (items.length - kept.length),
      digest: digest,
      items: kept,
      requestedAt: requestedAt,
    );
  }
}

abstract interface class NoticeRepository {
  /// 当前用户可见通知列表（置顶优先 + 时间倒序）
  Future<List<Notice>> list({bool? onlyUnread});

  /// 顶部到达提醒 feed（按 publishedAt + id 高水位升序分页）。
  Future<NoticeArrivalPage> listArrivals({
    NoticeArrivalCursor? after,
    int limit = 100,
  });

  Future<Notice?> getById(String id);

  Future<Notice> markRead(String id);

  Future<void> completeTodo(String id);

  /// 全部标记已读
  Future<void> markAllRead();

  /// 未读索引(判定用轻量列 + 摘要；未读数本身随徽章汇总带回，ADR-108)。
  Future<NoticeUnreadIndex> unreadIndex();

  /// 按业务事件来源批量标记已读（如打开进度页清空完工徽章）。返回实际置读条数。
  Future<int> markReadBySource(List<String> events);

  /// 按站内办理路由（action_route 精确匹配）批量标记已读：业务动作完成或
  /// 打开对应单据后，指向这些路由的通知对当前用户变已读。返回实际置读条数。
  Future<int> markReadByRoute(List<String> routes);

  /// V459「稍后再看」：snoozed_until 前弹卡流不再弹出（通知中心仍可见），
  /// 同时置已读；minutes 默认 15。
  Future<void> snooze(String id, {int minutes = 15});

  /// V459 弹卡真态校验：按通知 id 批量返回办结与认领状态（弹前 + 停留心跳）。
  Future<List<PendingReviewStatus>> pendingReviewStatus(List<String> ids);

  /// V459 居中审核弹窗（登录检查）：我名下未办结且未稍后的待审通知。
  Future<List<Notice>> pendingReviews();

  /// 人工通知登录弹窗（2026-09-10，ADR-063 §8）：人事手动发布、对我可见且仍待处理的
  /// 通知——打卡类型（acknowledge）未打卡恒弹；只提醒类型（none）14 天内未读未确认。
  /// 与 [pendingReviews] 并行拉取，在同一居中弹窗内分组展示。
  Future<List<Notice>> pendingPopups();

  /// 发布新通知（需 notice:publish 权限），返回入库后的实体
  Future<Notice> publish({
    required String title,
    required String content,
    required NoticeType type,
    bool topPriority = false,
    NoticePriority priority = NoticePriority.normal,
    List<String> attachments = const [],
    NoticeAudienceScope audienceScope = NoticeAudienceScope.all,
    List<String> departmentIds = const [],
    List<String> employeeIds = const [],
    NoticeKind kind = NoticeKind.normal,
    String? actionRoute,
    DateTime? dueAt,
    String? subjectEmployeeId,
    List<String> blessingTemplates = const [],
  });

  /// 庆典通知发布预览：选对象 + 类型后取自动填充（标题/事件标签/模板）。
  Future<NoticeCelebrationPreview> previewCelebration({
    required String employeeId,
    required NoticeType type,
  });

  /// 当前用户今日庆典（登录弹窗 / 今日卡片；服务端按 birth/hire date + 今日庆典通知判定）。
  Future<List<MyCelebrationToday>> myCelebrationToday();

  /// 一键批量发布庆典祝福（默认模板 + 服务端派生标题，本年已发的去重跳过）。
  Future<CelebrationBatchResult> publishCelebrationBatch({
    required NoticeType type,
    required List<String> employeeIds,
  });

  /// 庆典自动发布设置（notice:read；默认关——祝福由人事手动发布，V600）。
  Future<NoticeCelebrationSettings> getCelebrationSettings();

  /// 翻转「庆典自动发送」开关（notice:publish，HR 任务中心页面开关）。
  /// 返回最新设置。
  Future<NoticeCelebrationSettings> setCelebrationAutoEnabled(bool enabled);

  /// 「点击收到」回执（acknowledge 模式，幂等）。返回最新计数与本人状态。
  Future<Notice> acknowledge(String id);

  /// 「送上祝福」（bless 模式，upsert）。返回最新通知（含 myBlessing）。
  Future<Notice> bless(String id, String content);

  /// 撤回本人祝福。
  Future<Notice> withdrawBlessing(String id);

  /// 祝福墙分页列表。
  Future<List<NoticeBlessing>> listBlessings(
    String id, {
    int page = 0,
    int size = 20,
  });

  Future<NoticeAudiencePreview> previewAudience({
    required List<String> departmentIds,
    required List<String> employeeIds,
  });

  Future<List<NoticeAudienceEmployee>> searchAudienceEmployees({
    String? search,
  });

  /// 批量删除（从当前用户列表移除；他人不受影响）。返回实际删除条数。
  Future<int> deleteMany(List<String> ids);
}

class DioNoticeRepository implements NoticeRepository {
  DioNoticeRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<Notice>> list({bool? onlyUnread}) async {
    final json = await _api.get(
      ApiEndpoints.notices,
      query: onlyUnread == true ? {'onlyUnread': true} : null,
    );
    final items = (json['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return [for (final m in items) _fromJson(m)];
  }

  @override
  Future<NoticeArrivalPage> listArrivals({
    NoticeArrivalCursor? after,
    int limit = 100,
  }) async {
    final json = await _api.get(
      ApiEndpoints.noticeArrivals,
      query: {
        'limit': limit,
        if (after != null) 'after': after.publishedAt.toUtc().toIso8601String(),
        if (after != null) 'afterId': after.id,
      },
    );
    final items = (json['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    final cursorPublishedAt =
        DateTime.tryParse(
          json['cursorPublishedAt'] as String? ?? '',
        )?.toUtc() ??
        after?.publishedAt ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final cursorId =
        json['cursorId'] as String? ?? after?.id ?? NoticeArrivalCursor.zeroId;
    return NoticeArrivalPage(
      items: [for (final item in items) _fromJson(item)],
      cursor: NoticeArrivalCursor(publishedAt: cursorPublishedAt, id: cursorId),
      hasMore: json['hasMore'] as bool? ?? false,
    );
  }

  @override
  Future<Notice?> getById(String id) async {
    final json = await _api.get(ApiEndpoints.notice(id));
    if (json.isEmpty) return null;
    return _fromJson(json);
  }

  @override
  Future<Notice> markRead(String id) async {
    await _api.post(ApiEndpoints.noticeRead(id));
    // read 接口为 void（统一已读语义），回查一次拿最新状态
    final notice = await getById(id);
    if (notice == null) throw Exception('通知不存在');
    return notice;
  }

  @override
  Future<void> completeTodo(String id) async {
    await _api.post(ApiEndpoints.noticeComplete(id));
  }

  @override
  Future<void> markAllRead() async {
    await _api.post(ApiEndpoints.noticesReadAll);
  }

  @override
  Future<NoticeUnreadIndex> unreadIndex() async {
    final json = await _api.get(ApiEndpoints.noticesUnreadIndex);
    return NoticeUnreadIndex.fromJson(json);
  }

  @override
  Future<int> markReadBySource(List<String> events) async {
    if (events.isEmpty) return 0;
    final json = await _api.post(
      ApiEndpoints.noticesReadBySource,
      query: {'events': events.join(',')},
    );
    return (json['read'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<int> markReadByRoute(List<String> routes) async {
    if (routes.isEmpty) return 0;
    final json = await _api.post(
      ApiEndpoints.noticesReadByRoute,
      query: {'routes': routes.join(',')},
    );
    return (json['read'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> snooze(String id, {int minutes = 15}) {
    return _api
        .post(ApiEndpoints.noticeSnooze(id), query: {'minutes': minutes})
        .then((_) {});
  }

  @override
  Future<List<Notice>> pendingReviews() async {
    final json = await _api.get(ApiEndpoints.noticesPendingReviews);
    final rows = json['items'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().map(_fromJson).toList();
  }

  @override
  Future<List<Notice>> pendingPopups() async {
    final json = await _api.get(ApiEndpoints.noticesPendingPopups);
    final rows = json['items'];
    if (rows is! List) return const [];
    return rows.whereType<Map<String, dynamic>>().map(_fromJson).toList();
  }

  @override
  Future<List<PendingReviewStatus>> pendingReviewStatus(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const [];
    // Keep each heartbeat within the server's 50-id cap. Merge all batches so
    // missing entries mean withdrawn access, not silently truncated input.
    if (ids.length > 50) {
      final results = <PendingReviewStatus>[];
      for (var offset = 0; offset < ids.length; offset += 50) {
        results.addAll(
          await pendingReviewStatus(
            ids.sublist(
              offset,
              offset + 50 < ids.length ? offset + 50 : ids.length,
            ),
          ),
        );
      }
      return results;
    }
    final json = await _api.get(
      ApiEndpoints.noticesPendingReviewStatus,
      query: {'ids': ids.join(',')},
    );
    final rows = json['items'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(PendingReviewStatus.fromJson)
        .toList();
  }

  @override
  Future<Notice> publish({
    required String title,
    required String content,
    required NoticeType type,
    bool topPriority = false,
    NoticePriority priority = NoticePriority.normal,
    List<String> attachments = const [],
    NoticeAudienceScope audienceScope = NoticeAudienceScope.all,
    List<String> departmentIds = const [],
    List<String> employeeIds = const [],
    NoticeKind kind = NoticeKind.normal,
    String? actionRoute,
    DateTime? dueAt,
    String? subjectEmployeeId,
    List<String> blessingTemplates = const [],
  }) async {
    final json = await _api.post(
      ApiEndpoints.notices,
      body: {
        'title': title,
        'content': content,
        'type': type.name,
        'topPriority': topPriority,
        'priority': priority.name,
        'attachments': attachments,
        'audienceScope': audienceScope.name,
        'departmentIds': departmentIds,
        'employeeIds': employeeIds,
        'kind': kind.name.toUpperCase(),
        'actionRoute': actionRoute,
        'dueAt': dueAt?.toUtc().toIso8601String(),
        'subjectEmployeeId': ?subjectEmployeeId,
        if (blessingTemplates.isNotEmpty)
          'blessingTemplates': blessingTemplates,
      },
    );
    return _fromJson(json);
  }

  @override
  Future<NoticeCelebrationPreview> previewCelebration({
    required String employeeId,
    required NoticeType type,
  }) async {
    final json = await _api.get(
      ApiEndpoints.noticeCelebrationPreview,
      query: {'employeeId': employeeId, 'type': type.name},
    );
    return NoticeCelebrationPreview.fromJson(json);
  }

  @override
  Future<List<MyCelebrationToday>> myCelebrationToday() async {
    final json = await _api.get(ApiEndpoints.noticeCelebrationMyToday);
    final items = (json['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return [for (final m in items) MyCelebrationToday.fromJson(m)];
  }

  @override
  Future<CelebrationBatchResult> publishCelebrationBatch({
    required NoticeType type,
    required List<String> employeeIds,
  }) async {
    final json = await _api.post(
      ApiEndpoints.noticeCelebrationBatch,
      body: {'type': type.name, 'employeeIds': employeeIds},
    );
    return CelebrationBatchResult.fromJson(json);
  }

  @override
  Future<NoticeCelebrationSettings> getCelebrationSettings() async {
    final json = await _api.get(ApiEndpoints.noticeCelebrationSettings);
    return NoticeCelebrationSettings.fromJson(json);
  }

  @override
  Future<NoticeCelebrationSettings> setCelebrationAutoEnabled(
    bool enabled,
  ) async {
    final json = await _api.put(
      ApiEndpoints.noticeCelebrationAuto,
      body: {'enabled': enabled},
    );
    return NoticeCelebrationSettings.fromJson(json);
  }

  @override
  Future<Notice> acknowledge(String id) async {
    await _api.post(ApiEndpoints.noticeAcknowledge(id));
    // 回执接口返回计数快照，但统一回查拿最新 Notice（含 myAcked/ackCount）
    final notice = await getById(id);
    if (notice == null) throw Exception('通知不存在');
    return notice;
  }

  @override
  Future<Notice> bless(String id, String content) async {
    await _api.post(
      ApiEndpoints.noticeBlessing(id),
      body: {'content': content},
    );
    final notice = await getById(id);
    if (notice == null) throw Exception('通知不存在');
    return notice;
  }

  @override
  Future<Notice> withdrawBlessing(String id) async {
    await _api.delete(ApiEndpoints.noticeBlessing(id));
    final notice = await getById(id);
    if (notice == null) throw Exception('通知不存在');
    return notice;
  }

  @override
  Future<List<NoticeBlessing>> listBlessings(
    String id, {
    int page = 0,
    int size = 20,
  }) async {
    final json = await _api.get(
      ApiEndpoints.noticeBlessings(id),
      query: {'page': page, 'size': size},
    );
    final items = (json['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return [for (final m in items) NoticeBlessing.fromJson(m)];
  }

  @override
  Future<NoticeAudiencePreview> previewAudience({
    required List<String> departmentIds,
    required List<String> employeeIds,
  }) async {
    final json = await _api.post(
      ApiEndpoints.noticesAudiencePreview,
      body: {'departmentIds': departmentIds, 'employeeIds': employeeIds},
    );
    return NoticeAudiencePreview.fromJson(json);
  }

  @override
  Future<List<NoticeAudienceEmployee>> searchAudienceEmployees({
    String? search,
  }) async {
    final items = await _api.getList(
      ApiEndpoints.noticesAudienceEmployees,
      query: search == null || search.trim().isEmpty
          ? null
          : {'search': search.trim()},
    );
    return [for (final item in items) NoticeAudienceEmployee.fromJson(item)];
  }

  @override
  Future<int> deleteMany(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final json = await _api.post(
      ApiEndpoints.noticesBatchDelete,
      body: {'ids': ids},
    );
    return (json['deleted'] as num?)?.toInt() ?? 0;
  }

  Notice _fromJson(Map<String, dynamic> json) {
    final type = _typeFrom(json['type'] as String?);
    final rawMode = NoticeInteractionMode.fromName(
      json['interactionMode'] as String?,
    );
    return Notice(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      type: type,
      publisher: json['publisher'] as String? ?? '',
      publishedAt:
          ChinaDateTime.tryParse(json['publishedAt'] as String?) ??
          ChinaDateTime.now(),
      isRead: json['isRead'] as bool? ?? false,
      readAt: json['readAt'] != null
          ? ChinaDateTime.tryParse(json['readAt'] as String?)
          : null,
      topPriority: json['topPriority'] as bool? ?? false,
      priority: _priorityFrom(json['priority'] as String?),
      attachments: (json['attachments'] as List<dynamic>? ?? const [])
          .cast<String>(),
      audienceScope: NoticeAudienceScope.fromName(
        json['audienceScope'] as String?,
      ),
      audienceSummary: json['audienceSummary'] as String? ?? '全体员工',
      audienceCount: (json['audienceCount'] as num?)?.toInt(),
      kind: NoticeKind.fromName(json['kind'] as String?),
      actionRoute: json['actionRoute'] as String?,
      sourceEvent: json['sourceEvent'] as String?,
      dueAt: json['dueAt'] == null
          ? null
          : ChinaDateTime.tryParse(json['dueAt'] as String?),
      taskCompleted: json['taskCompleted'] as bool? ?? false,
      taskCompletedAt: json['taskCompletedAt'] == null
          ? null
          : ChinaDateTime.tryParse(json['taskCompletedAt'] as String?),
      // 后端缺省 interactionMode 时按类型派生（健壮兜底）
      interactionMode: rawMode == NoticeInteractionMode.none
          ? type.interactionMode
          : rawMode,
      subjectName: json['subjectName'] as String?,
      eventLabel: json['eventLabel'] as String?,
      ackCount: (json['ackCount'] as num?)?.toInt() ?? 0,
      blessingCount: (json['blessingCount'] as num?)?.toInt() ?? 0,
      myAcked: json['myAcked'] as bool? ?? false,
      myBlessing: json['myBlessing'] as String?,
      recentAckers: (json['recentAckers'] as List<dynamic>? ?? const [])
          .cast<String>(),
      recentBlessings: (json['recentBlessings'] as List<dynamic>? ?? const [])
          .map((e) => NoticeBlessing.fromJson(e as Map<String, dynamic>))
          .toList(),
      blessingTemplates:
          (json['blessingTemplates'] as List<dynamic>? ?? const [])
              .cast<String>(),
      subjects: (json['subjects'] as List<dynamic>? ?? const [])
          .map(
            (e) => NoticeCelebrationSubject.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
      // V459 审核待办弹卡字段
      interactive: json['interactive'] as bool? ?? false,
      aggregateKind: json['aggregateKind'] as String?,
      aggregateId: json['aggregateId'] as String?,
      resolvedAt: json['resolvedAt'] == null
          ? null
          : ChinaDateTime.tryParse(json['resolvedAt'] as String?),
      resolvedReason: json['resolvedReason'] as String?,
    );
  }

  static NoticeType _typeFrom(String? name) => switch (name) {
    'policy' => NoticeType.policy,
    'benefit' => NoticeType.benefit,
    'system' => NoticeType.system,
    'urgent' => NoticeType.urgent,
    'task' => NoticeType.task,
    'approval' => NoticeType.approval,
    'workflow' => NoticeType.workflow,
    'birthday' => NoticeType.birthday,
    'anniversary' => NoticeType.anniversary,
    'wedding' => NoticeType.wedding,
    'newborn' => NoticeType.newborn,
    _ => NoticeType.announcement,
  };

  static NoticePriority _priorityFrom(String? name) => switch (name) {
    'important' => NoticePriority.important,
    'urgent' => NoticePriority.urgent,
    _ => NoticePriority.normal,
  };
}

/// V459 弹卡真态出参：resolved=true 即收卡；claimedByName 非空显示「XX 正在审核」。
class PendingReviewStatus {
  const PendingReviewStatus({
    required this.noticeId,
    required this.resolved,
    this.resolvedAt,
    this.claimedByName,
    this.claimedAt,
  });

  factory PendingReviewStatus.fromJson(Map<String, dynamic> json) {
    return PendingReviewStatus(
      noticeId: json['noticeId'] as String,
      resolved: json['resolved'] as bool? ?? false,
      resolvedAt: json['resolvedAt'] == null
          ? null
          : ChinaDateTime.tryParse(json['resolvedAt'] as String?),
      claimedByName: json['claimedByName'] as String?,
      claimedAt: json['claimedAt'] == null
          ? null
          : ChinaDateTime.tryParse(json['claimedAt'] as String?),
    );
  }

  final String noticeId;
  final bool resolved;
  final DateTime? resolvedAt;

  /// 当前认领人姓名（无人处理为 null）。
  final String? claimedByName;
  final DateTime? claimedAt;
}
