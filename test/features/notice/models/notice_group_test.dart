import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/models/notice_group.dart';

/// 分组锚点解析与分组装配的契约：
/// - 服务端聚合 (aggregateKind, aggregateId) 优先；
/// - 详情路由尾段 UUID → 归一 kind（与聚合同名时合流），未知父路径兜底；
/// - 带业务主键查询参数的页面（?caseId= / ?analysisId= / ?requestId=）可解析；
/// - 队列页路由（无 id）、静态段（非 UUID）、公告/庆典（无路由）→ null 独立卡片；
/// - 装配保持服务端顺序；组内未读在前、各按发布时间倒序；卡面优先最新未读。
Notice _n(
  String id, {
  String? actionRoute,
  String? aggregateKind,
  String? aggregateId,
  bool isRead = false,
  DateTime? publishedAt,
  NoticeType type = NoticeType.workflow,
}) {
  return Notice(
    id: id,
    title: 't-$id',
    content: 'c',
    type: type,
    publisher: '系统',
    publishedAt: publishedAt ?? DateTime(2026, 10, 9, 12),
    isRead: isRead,
    actionRoute: actionRoute,
    aggregateKind: aggregateKind,
    aggregateId: aggregateId,
  );
}

const _uuidA = '11111111-1111-4111-8111-111111111111';
const _uuidB = '22222222-2222-4222-8222-222222222222';

void main() {
  group('noticeGroupKeyOf', () {
    test('prefers server aggregate when present', () {
      final key = noticeGroupKeyOf(
        _n(
          'a',
          actionRoute: '/sales/orders/$_uuidA',
          aggregateKind: 'SALES_ORDER',
          aggregateId: _uuidA,
        ),
      );
      expect(key, const NoticeGroupKey('SALES_ORDER', _uuidA));
    });

    test('parses detail route and canonicalizes to aggregate kind', () {
      expect(
        noticeGroupKeyOf(_n('a', actionRoute: '/sales/orders/$_uuidA')),
        const NoticeGroupKey('SALES_ORDER', _uuidA),
      );
      // 同一出货单的两个入口路由归并到同一 kind。
      expect(
        noticeGroupKeyOf(
          _n('a', actionRoute: '/sales/customer-shipments/$_uuidA'),
        )!.kind,
        'SALES_SHIPMENT',
      );
      expect(
        noticeGroupKeyOf(_n('a', actionRoute: '/warehouse/DRAW/$_uuidA'))!.kind,
        'STOCK_DOCUMENT',
      );
    });

    test('unknown detail-route parent falls back to parent path', () {
      final key = noticeGroupKeyOf(
        _n('a', actionRoute: '/warehouse/quality-results/PURCHASE/$_uuidA'),
      );
      expect(key!.kind, 'warehouse/quality-results/PURCHASE');
      expect(key.id, _uuidA);
    });

    test('parses business-key query pages', () {
      expect(
        noticeGroupKeyOf(
          _n('a', actionRoute: '/subcontract/short-deliveries?caseId=$_uuidA'),
        ),
        const NoticeGroupKey('SUBCONTRACT_SHORT_DELIVERY_CASE', _uuidA),
      );
      expect(
        noticeGroupKeyOf(
          _n(
            'a',
            actionRoute: '/production/material-analysis?analysisId=$_uuidB',
          ),
        ),
        const NoticeGroupKey('PRODUCTION_MATERIAL_ANALYSIS', _uuidB),
      );
      // 同页面不带主键（如 SALES_ORDER_APPROVED 接卡路由）不分组。
      expect(
        noticeGroupKeyOf(_n('a', actionRoute: '/production/material-analysis')),
        isNull,
      );
    });

    test('queue pages, static segments and routeless notices stay solo', () {
      expect(
        noticeGroupKeyOf(
          _n('a', actionRoute: '/finance/procurement-approvals'),
        ),
        isNull,
      );
      expect(
        noticeGroupKeyOf(_n('a', actionRoute: '/quality/task-center')),
        isNull,
      );
      // 静态段不是 UUID：不分组。
      expect(
        noticeGroupKeyOf(_n('a', actionRoute: '/sales/quotes/new')),
        isNull,
      );
      expect(noticeGroupKeyOf(_n('a')), isNull);
      expect(noticeGroupKeyOf(_n('a', type: NoticeType.birthday)), isNull);
    });
  });

  group('groupNotices', () {
    test(
      'merges route receipts with server-aggregate cards on the same object',
      () {
        final groups = groupNotices([
          _n('receipt-1', actionRoute: '/sales/orders/$_uuidA'),
          _n(
            'card-1',
            actionRoute: '/sales/orders/$_uuidA',
            aggregateKind: 'SALES_ORDER',
            aggregateId: _uuidA,
          ),
          _n('other', actionRoute: '/sales/orders/$_uuidB'),
        ]);
        expect(groups, hasLength(2));
        final merged = groups.first;
        expect(merged.notices, hasLength(2));
        expect(groups[1].isSingle, isTrue);
      },
    );

    test('keeps server order for group positions', () {
      final groups = groupNotices([
        _n('b', actionRoute: '/sales/orders/$_uuidB'),
        _n('a1', actionRoute: '/sales/orders/$_uuidA'),
        _n('a2', actionRoute: '/sales/orders/$_uuidA'),
      ]);
      // B 组在前（其第一条在服务端序里更靠前），A 组保持第二位。
      expect(groups.map((g) => g.key.id), [_uuidB, _uuidA]);
    });

    test('sorts unread first within group, both by time desc', () {
      final base = DateTime(2026, 10, 9);
      final groups = groupNotices([
        _n(
          'old-read',
          actionRoute: '/sales/orders/$_uuidA',
          isRead: true,
          publishedAt: base.subtract(const Duration(days: 3)),
        ),
        _n(
          'new-read',
          actionRoute: '/sales/orders/$_uuidA',
          isRead: true,
          publishedAt: base,
        ),
        _n(
          'unread-older',
          actionRoute: '/sales/orders/$_uuidA',
          publishedAt: base.subtract(const Duration(hours: 5)),
        ),
        _n(
          'unread-newer',
          actionRoute: '/sales/orders/$_uuidA',
          publishedAt: base.subtract(const Duration(hours: 1)),
        ),
      ]);
      expect(groups.single.notices.map((n) => n.id).toList(), [
        'unread-newer',
        'unread-older',
        'new-read',
        'old-read',
      ]);
    });

    test('face prefers latest unread over newer read notice', () {
      final base = DateTime(2026, 10, 9);
      final groups = groupNotices([
        _n(
          'read-new',
          actionRoute: '/sales/orders/$_uuidA',
          isRead: true,
          publishedAt: base,
        ),
        _n(
          'unread-old',
          actionRoute: '/sales/orders/$_uuidA',
          publishedAt: base.subtract(const Duration(days: 1)),
        ),
      ]);
      expect(groups.single.face.id, 'unread-old');
      expect(groups.single.unreadCount, 1);
    });

    test('solo notices never merge with each other', () {
      final groups = groupNotices([
        _n('a', type: NoticeType.announcement),
        _n('b', type: NoticeType.birthday),
        _n('c', actionRoute: '/finance/procurement-approvals'),
      ]);
      expect(groups, hasLength(3));
      expect(groups.every((g) => g.isSingle), isTrue);
    });
  });
}
