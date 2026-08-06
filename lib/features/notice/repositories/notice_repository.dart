// 通知仓库（真实后端）
// 后端：server .../features/notice/NoticeController（/api/notices）

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/notice.dart';
import '../models/notice_audience.dart';

abstract interface class NoticeRepository {
  /// 当前用户可见通知列表（置顶优先 + 时间倒序）
  Future<List<Notice>> list({bool? onlyUnread});

  Future<Notice?> getById(String id);

  Future<Notice> markRead(String id);

  Future<void> completeTodo(String id);

  /// 全部标记已读
  Future<void> markAllRead();

  /// 未读数（Dashboard 角标）
  Future<int> unreadCount();

  /// 按业务事件来源统计未读数（如销售订单完工提醒徽章）。
  Future<int> unreadCountBySource(List<String> events);

  /// 按业务事件来源批量标记已读（如打开进度页清空完工徽章）。
  Future<void> markReadBySource(List<String> events);

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

  /// 「点击收到」回执（acknowledge 模式，幂等）。返回最新计数与本人状态。
  Future<Notice> acknowledge(String id);

  /// 「送上祝福」（bless 模式，upsert）。返回最新通知（含 myBlessing）。
  Future<Notice> bless(String id, String content);

  /// 撤回本人祝福。
  Future<Notice> withdrawBlessing(String id);

  /// 祝福墙分页列表。
  Future<List<NoticeBlessing>> listBlessings(String id, {int page = 0, int size = 20});

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
  Future<int> unreadCount() async {
    final json = await _api.get(ApiEndpoints.noticesUnreadCount);
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<int> unreadCountBySource(List<String> events) async {
    if (events.isEmpty) return 0;
    final json = await _api.get(
      ApiEndpoints.noticesUnreadCountBySource,
      query: {'events': events.join(',')},
    );
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> markReadBySource(List<String> events) async {
    if (events.isEmpty) return;
    await _api.post(
      ApiEndpoints.noticesReadBySource,
      query: {'events': events.join(',')},
    );
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
        if (blessingTemplates.isNotEmpty) 'blessingTemplates': blessingTemplates,
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
      recentAckers:
          (json['recentAckers'] as List<dynamic>? ?? const []).cast<String>(),
      recentBlessings:
          (json['recentBlessings'] as List<dynamic>? ?? const [])
              .map((e) => NoticeBlessing.fromJson(e as Map<String, dynamic>))
              .toList(),
      blessingTemplates:
          (json['blessingTemplates'] as List<dynamic>? ?? const [])
              .cast<String>(),
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
