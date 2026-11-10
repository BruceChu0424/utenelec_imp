// 通知分组模型：把「关于同一业务对象」或「同一系统通知主题」叠成一组。
//
// 分组锚点按优先级取：
// 1. 服务端聚合 (aggregateKind, aggregateId)——V459 审核待办弹卡自带；
// 2. action_route 里的单据详情路由——结果回执类通知（排产/报工/入库/财务
//    驳回/核价结果…）没有聚合，但落点都指向源单据详情页，例如销售收到的
//    订单链通知全部指向 /sales/orders/{orderId}，按尾段主键即可归到同一单。
//    已知前缀归一成与服务端聚合同名的 kind，让两类锚点自然合流
//    （如 /sales/orders/{id} → SALES_ORDER，与「全部完工可发货」弹卡同组）；
//    其余「尾段是 UUID」的详情路由以父路径为 kind 兜底；
//    带业务主键查询参数的页面（?caseId= / ?analysisId= / ?requestId=）同样解析。
// 3. 没有业务锚点的系统/紧急通知，按来源事件或精确主题叠放；
//    状态告警保留指标与严重档，主机告警忽略每次事件 UUID，更新保留版本标题。
// 4. 其余公告/庆典/纯工作队列通知 → null → 独立卡片，不参与分组。
//
// 注意：回执类通知**故意不**向后端申请绑定 aggregate——办结撤回
// （resolveReviewNotices）会按聚合把全部接收人置已读+已办结，回执若挂上
// 同聚合会被别人的后续动作误撤（SalesQuoteNoticeService 对核价回执的
// 注释即此口径）。分组是纯展示层关注点，锚点在前端解析，不动服务端语义。

import 'dart:convert';

import 'notice.dart';

/// 一个通知分组的锚点：业务类型 + 主键，或展示专用的主题键。
class NoticeGroupKey {
  const NoticeGroupKey(this.kind, this.id);

  final String kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is NoticeGroupKey && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => '$kind/$id';
}

/// 已知详情路由前缀 → 服务端聚合 kind 归一表。
///
/// key 是去掉尾段主键后的路径段（'/' 连接，与 [Uri.pathSegments] 对应）；
/// 未命中走父路径兜底（保持唯一性即可，不追求与服务端命名一致）。
const Map<String, String> _routeKindByParent = {
  'sales/orders': 'SALES_ORDER',
  'sales/quotes': 'SALES_QUOTE',
  'sales/shipments': 'SALES_SHIPMENT',
  'sales/customer-shipments': 'SALES_SHIPMENT',
  'warehouse/DRAW': 'STOCK_DOCUMENT',
  'warehouse/FINISHED_IN': 'STOCK_DOCUMENT',
  'purchase/orders': 'PROCUREMENT_ORDER',
  'purchase/requests': 'PURCHASE_REQUEST',
  'subcontract/orders': 'SUBCONTRACT_ORDER',
  'subcontract/applications': 'SUBCONTRACT_APPLICATION',
  'production/plans': 'PRODUCTION_PLAN',
  'production/daily-reports': 'PRODUCTION_DAILY_REPORT',
  'procurement/iqc-rejections': 'IQC_REJECTION_CASE',
  'expense': 'EXPENSE_CLAIM',
};

/// 带业务主键查询参数的页面 → (聚合 kind, 参数名)。
const Map<String, (String, String)> _routeKeyByQueryPage = {
  '/subcontract/short-deliveries': (
    'SUBCONTRACT_SHORT_DELIVERY_CASE',
    'caseId',
  ),
  '/production/material-analysis': (
    'PRODUCTION_MATERIAL_ANALYSIS',
    'analysisId',
  ),
  '/stock/count-requests': ('STOCK_COUNT_REQUEST', 'requestId'),
};

/// 服务端主键是 UUID；只认 UUID 形态的尾段，避免把 /sales/new 这类
/// 静态段误当业务主键分组。
final RegExp _uuidLike = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// 通知的分组锚点；解析不出返回 null（独立卡片）。
NoticeGroupKey? noticeGroupKeyOf(Notice notice) {
  final aggregateKind = notice.aggregateKind;
  final aggregateId = notice.aggregateId;
  if (aggregateKind != null &&
      aggregateKind.isNotEmpty &&
      aggregateId != null &&
      aggregateId.isNotEmpty) {
    return NoticeGroupKey(aggregateKind, aggregateId);
  }
  return _routeKeyOf(notice.actionRoute) ?? _systemTopicKeyOf(notice);
}

/// 仅展示归组，不绑定后端 aggregate，不把「查看一组」当作收到或办结。
///
/// sourceEvent 的真实约定由 ServerStatusAlertScheduler / LoginFailureAlertScheduler /
/// ServerUpdateNoticePublisher 维护。未知事件不猜测其主键结构；没有事件的旧系统
/// 通知才使用精确标题兜底。人工公告、庆典和无业务锚点的待办各自保留。
NoticeGroupKey? _systemTopicKeyOf(Notice notice) {
  if ((notice.type != NoticeType.system && notice.type != NoticeType.urgent) ||
      notice.kind != NoticeKind.normal ||
      notice.interactive) {
    return null;
  }
  final event = notice.sourceEvent?.trim() ?? '';
  final title = notice.title.trim();
  final String topic;
  if (event.startsWith('SERVER_STATUS_ALERT:') &&
      event.length > 'SERVER_STATUS_ALERT:'.length) {
    // CRITICAL、WARNING、RECOVERED 分别归组，恢复不掩盖未读危急告警。
    // 登录失败事件的来源指纹同样完整保留，不能把不同来源混为一件事。
    topic = event;
  } else if (((event.startsWith('SERVER_HOST_ALERT:') &&
              event.length > 'SERVER_HOST_ALERT:'.length) ||
          (event.startsWith('SERVER_UPDATE:') &&
              event.length > 'SERVER_UPDATE:'.length) ||
          event.isEmpty) &&
      title.isNotEmpty) {
    // 主机事件 UUID 随每次发生变化；标题是接口当前提供的稳定人话分类。
    // 更新事件 hash 包含 revision，标题含版本；同版本通知可归到同一叠。
    final family = event.isEmpty ? 'legacy' : event.split(':').first;
    topic = '$family:$title';
  } else {
    return null;
  }
  // 用结构编码避免标题、发布者或路由自带分隔符时误碰撞。
  return NoticeGroupKey(
    '_system_topic',
    jsonEncode([
      notice.type.name,
      notice.priority.name,
      notice.interactionMode.name,
      notice.publisher.trim(),
      notice.actionRoute?.trim() ?? '',
      topic,
    ]),
  );
}

NoticeGroupKey? _routeKeyOf(String? actionRoute) {
  if (actionRoute == null || actionRoute.isEmpty) return null;
  final uri = Uri.tryParse(actionRoute);
  if (uri == null) return null;

  // 带业务主键查询参数的队列/工作台页（?caseId= / ?analysisId= / ?requestId=）。
  final queryPage = _routeKeyByQueryPage[uri.path];
  if (queryPage != null) {
    final (kind, param) = queryPage;
    final id = uri.queryParameters[param];
    return (id != null && _uuidLike.hasMatch(id))
        ? NoticeGroupKey(kind, id)
        : null;
  }

  // 详情路由：尾段是 UUID → 按父路径（归一后）分组。
  final segments = uri.pathSegments;
  if (segments.length < 2) return null;
  final last = segments.last;
  if (!_uuidLike.hasMatch(last)) return null;
  final parent = segments.sublist(0, segments.length - 1).join('/');
  return NoticeGroupKey(_routeKindByParent[parent] ?? parent, last);
}

/// 组内排序：未读在前，各按发布时间倒序（id 兜底保证稳定）。
int _groupOrder(Notice a, Notice b) {
  if (a.isRead != b.isRead) return a.isRead ? 1 : -1;
  final byTime = b.publishedAt.compareTo(a.publishedAt);
  if (byTime != 0) return byTime;
  return a.id.compareTo(b.id);
}

/// 一组相关通知。
class NoticeGroup {
  NoticeGroup(this.key, List<Notice> notices)
    : notices = [...notices]..sort(_groupOrder);

  final NoticeGroupKey key;
  final List<Notice> notices;

  /// 组内是否只有一条（渲染为普通卡片，不带叠放形态）。
  bool get isSingle => notices.length == 1;

  /// 组内全部通知 id（管理模式按组勾选用）。
  Set<String> get ids => notices.map((n) => n.id).toSet();

  int get unreadCount => notices.where((n) => !n.isRead).length;

  /// 卡面通知：优先组内最新的**未读**（有未读时它是真正待看的），全部已读
  /// 取最新一条（代表这件事的当前进展）。
  Notice get face => notices.first;
}

/// 按服务端返回顺序装配分组。
///
/// 组的位置 = 组内第一条（服务端序里最新的一条）出现的位置，保持
/// 「置顶优先、发布时间倒序」的服务端排序不被打乱；无锚点的通知各自成
/// 单条组（isSingle），与分组走同一套渲染/选择逻辑。
List<NoticeGroup> groupNotices(List<Notice> notices) {
  final byKey = <NoticeGroupKey, List<Notice>>{};
  for (final notice in notices) {
    final key = noticeGroupKeyOf(notice) ?? NoticeGroupKey('_solo', notice.id);
    (byKey[key] ??= []).add(notice);
  }
  // Map 保留首次出现顺序，每组仅排序一次；重复告警很多时不逐次重排全组。
  return [
    for (final entry in byKey.entries) NoticeGroup(entry.key, entry.value),
  ];
}
