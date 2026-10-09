// 通知分组模型：把「关于同一业务对象」的多条通知叠成一组。
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
// 3. 解析不出锚点（公告/庆典/纯队列页路由）→ null → 独立卡片，不参与分组。
//
// 注意：回执类通知**故意不**向后端申请绑定 aggregate——办结撤回
// （resolveReviewNotices）会按聚合把全部接收人置已读+已办结，回执若挂上
// 同聚合会被别人的后续动作误撤（SalesQuoteNoticeService 对核价回执的
// 注释即此口径）。分组是纯展示层关注点，锚点在前端解析，不动服务端语义。

import 'notice.dart';

/// 一个通知分组的锚点：kind（业务对象类型）+ id（业务主键）。
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
  return _routeKeyOf(notice.actionRoute);
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

  /// 组内补录一条后重排（装配期使用；页面不直接调）。
  void add(Notice notice) {
    notices.add(notice);
    notices.sort(_groupOrder);
  }

  /// 组内是否只有一条（渲染为普通卡片，不带叠放形态）。
  bool get isSingle => notices.length == 1;

  /// 组内全部通知 id（管理模式按组勾选用）。
  Set<String> get ids => notices.map((n) => n.id).toSet();

  int get unreadCount => notices.where((n) => !n.isRead).length;

  /// 卡面通知：优先组内最新的**未读**（有未读时它是真正待看的），全部已读
  /// 取最新一条（代表这件事的当前进展）。
  Notice get face {
    var candidates = notices.where((n) => !n.isRead).toList();
    if (candidates.isEmpty) candidates = notices;
    var latest = candidates.first;
    for (final n in candidates) {
      if (n.publishedAt.isAfter(latest.publishedAt)) latest = n;
    }
    return latest;
  }
}

/// 按服务端返回顺序装配分组。
///
/// 组的位置 = 组内第一条（服务端序里最新的一条）出现的位置，保持
/// 「置顶优先、发布时间倒序」的服务端排序不被打乱；无锚点的通知各自成
/// 单条组（isSingle），与分组走同一套渲染/选择逻辑。
List<NoticeGroup> groupNotices(List<Notice> notices) {
  final byKey = <NoticeGroupKey, NoticeGroup>{};
  final result = <NoticeGroup>[];
  for (final notice in notices) {
    final key = noticeGroupKeyOf(notice);
    if (key == null) {
      // 无锚点：用通知自身 id 做键，保证唯一、永不与他组合并。
      result.add(NoticeGroup(NoticeGroupKey('_solo', notice.id), [notice]));
      continue;
    }
    final existing = byKey[key];
    if (existing != null) {
      existing.add(notice);
      continue;
    }
    final group = NoticeGroup(key, [notice]);
    byKey[key] = group;
    result.add(group);
  }
  return result;
}
