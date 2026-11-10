import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/models/notice_group.dart';

/// 分组锚点解析与分组装配的契约：
/// - 服务端聚合 (aggregateKind, aggregateId) 优先；
/// - 详情路由尾段 UUID → 归一 kind（与聚合同名时合流），未知父路径兜底；
/// - 带业务主键查询参数的页面（?caseId= / ?analysisId= / ?requestId=）可解析；
/// - 无业务锚点的系统通知按真实事件或精确主题归组，不混并指标/严重档/版本；
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
  String? title,
  String publisher = '系统',
  String? sourceEvent,
  NoticePriority priority = NoticePriority.normal,
  NoticeInteractionMode interactionMode = NoticeInteractionMode.none,
  NoticeKind kind = NoticeKind.normal,
  bool interactive = false,
}) {
  return Notice(
    id: id,
    title: title ?? 't-$id',
    content: 'c',
    type: type,
    publisher: publisher,
    publishedAt: publishedAt ?? DateTime(2026, 10, 9, 12),
    isRead: isRead,
    actionRoute: actionRoute,
    aggregateKind: aggregateKind,
    aggregateId: aggregateId,
    sourceEvent: sourceEvent,
    priority: priority,
    interactionMode: interactionMode,
    kind: kind,
    interactive: interactive,
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
      'stacks repeated host alerts by precise topic, retaining every receipt',
      () {
        final groups = groupNotices([
          _n(
            'disk-new',
            title: '本机备份盘未挂载',
            type: NoticeType.urgent,
            publisher: '系统监控',
            actionRoute: '/admin/server-status',
            sourceEvent: 'SERVER_HOST_ALERT:$_uuidA',
            priority: NoticePriority.urgent,
            interactionMode: NoticeInteractionMode.acknowledge,
          ),
          _n(
            'disk-old',
            title: '本机备份盘未挂载',
            type: NoticeType.urgent,
            publisher: '系统监控',
            actionRoute: '/admin/server-status',
            sourceEvent: 'SERVER_HOST_ALERT:$_uuidB',
            priority: NoticePriority.urgent,
            interactionMode: NoticeInteractionMode.acknowledge,
            isRead: true,
          ),
          _n(
            'database',
            title: '数据库备份与恢复点检查失败',
            type: NoticeType.urgent,
            publisher: '系统监控',
            actionRoute: '/admin/server-status',
            sourceEvent: 'SERVER_HOST_ALERT:other',
            priority: NoticePriority.urgent,
            interactionMode: NoticeInteractionMode.acknowledge,
          ),
        ]);
        expect(groups, hasLength(2));
        expect(groups.first.ids, {'disk-new', 'disk-old'});
        expect(groups.first.unreadCount, 1);
        expect(groups.first.face.id, 'disk-new');
        expect(groups.last.face.id, 'database');
      },
    );

    test(
      'stable metric event groups changing titles but keeps recovery separate',
      () {
        Notice metric(String id, String event, String title) => _n(
          id,
          title: title,
          type: NoticeType.system,
          publisher: '系统监控',
          actionRoute: '/admin/server-status',
          sourceEvent: event,
        );
        final groups = groupNotices([
          metric('disk-82', 'SERVER_STATUS_ALERT:disk-1:WARNING', '系统盘使用率 82%'),
          metric('disk-81', 'SERVER_STATUS_ALERT:disk-1:WARNING', '系统盘使用率 81%'),
          metric('disk-2', 'SERVER_STATUS_ALERT:disk-2:WARNING', '附件盘使用率 82%'),
          metric('backup', 'SERVER_STATUS_ALERT:backup:CRITICAL', '备份需要尽快处理'),
          metric(
            'recovered',
            'SERVER_STATUS_ALERT:backup:RECOVERED',
            '备份已回到正常范围',
          ),
        ]);
        expect(groups, hasLength(4));
        expect(groups.first.ids, {'disk-82', 'disk-81'});
        expect(groups.skip(1).every((group) => group.isSingle), isTrue);
      },
    );

    test('login alert source fingerprints stay separate', () {
      final groups = groupNotices([
        for (final source in ['fingerprint-a', 'fingerprint-b'])
          _n(
            source,
            title: '检测到连续登录失败',
            type: NoticeType.urgent,
            sourceEvent: 'SERVER_STATUS_ALERT:LOGIN_FAILURE:$source',
          ),
      ]);
      expect(groups, hasLength(2));
    });

    test(
      'same update version stacks across revisions and new version stays separate',
      () {
        final groups = groupNotices([
          for (final (id, version, hash) in [
            ('update-1', 'v2.5.52', 'revision-a'),
            ('update-2', 'v2.5.52', 'revision-b'),
            ('update-3', 'v2.5.53', 'revision-c'),
          ])
            _n(
              id,
              title: '服务器有新版本 $version',
              type: NoticeType.system,
              actionRoute: '/admin/server-operations',
              sourceEvent: 'SERVER_UPDATE:$hash',
            ),
        ]);
        expect(groups, hasLength(2));
        expect(groups.first.ids, {'update-1', 'update-2'});
        expect(groups.last.face.title, '服务器有新版本 v2.5.53');
      },
    );

    test('legacy system notices stack only with the same exact topic', () {
      final groups = groupNotices([
        _n('a', type: NoticeType.system, title: '服务器出现需要检查的问题'),
        _n('b', type: NoticeType.system, title: '服务器出现需要检查的问题'),
        _n('c', type: NoticeType.system, title: '服务器告警记录无法读取'),
        _n('empty-1', type: NoticeType.system, title: ' '),
        _n('empty-2', type: NoticeType.system, title: ''),
      ]);
      expect(groups, hasLength(4));
      expect(groups.first.ids, {'a', 'b'});
    });

    test(
      'system topics preserve type, priority, publisher, route and interaction',
      () {
        final groups = groupNotices([
          _n('base', type: NoticeType.system, title: '同一标题'),
          _n('type', type: NoticeType.urgent, title: '同一标题'),
          _n(
            'priority',
            type: NoticeType.system,
            title: '同一标题',
            priority: NoticePriority.important,
          ),
          _n(
            'publisher',
            type: NoticeType.system,
            title: '同一标题',
            publisher: '其他发布者',
          ),
          _n(
            'route',
            type: NoticeType.system,
            title: '同一标题',
            actionRoute: '/admin/server-status',
          ),
          _n(
            'interaction',
            type: NoticeType.system,
            title: '同一标题',
            interactionMode: NoticeInteractionMode.acknowledge,
          ),
        ]);
        expect(groups, hasLength(6));
      },
    );

    test(
      'unknown events and unanchored todos never merge by generic title',
      () {
        final groups = groupNotices([
          for (final id in ['unknown-a', 'unknown-b'])
            _n(
              id,
              type: NoticeType.system,
              title: '同一标题',
              sourceEvent: 'OTHER_EVENT',
            ),
          for (final id in ['todo-a', 'todo-b'])
            _n(
              id,
              type: NoticeType.system,
              title: '同一标题',
              kind: NoticeKind.todo,
            ),
          for (final id in ['interactive-a', 'interactive-b'])
            _n(id, type: NoticeType.system, title: '同一标题', interactive: true),
        ]);
        expect(groups, hasLength(6));
      },
    );

    test('business identity takes precedence over matching system titles', () {
      final groups = groupNotices([
        _n(
          'order-a',
          type: NoticeType.system,
          title: '同一标题',
          actionRoute: '/sales/orders/$_uuidA',
        ),
        _n(
          'order-b',
          type: NoticeType.system,
          title: '同一标题',
          actionRoute: '/sales/orders/$_uuidB',
        ),
        _n(
          'aggregate',
          type: NoticeType.system,
          title: '其他标题',
          sourceEvent: 'SERVER_HOST_ALERT:event',
          aggregateKind: 'SALES_ORDER',
          aggregateId: _uuidA,
        ),
      ]);
      expect(groups, hasLength(2));
      expect(groups.first.key, const NoticeGroupKey('SALES_ORDER', _uuidA));
      expect(groups.first.ids, {'order-a', 'aggregate'});
    });

    test(
      'large repeated topic retains all notices, stable order and original input',
      () {
        final base = DateTime.utc(2026, 11, 10);
        final notices = [
          for (var i = 0; i < 30000; i++)
            _n(
              'host-$i',
              type: NoticeType.urgent,
              title: '本机备份盘未挂载',
              sourceEvent: 'SERVER_HOST_ALERT:event-$i',
              isRead: i.isEven,
              publishedAt: base.subtract(Duration(seconds: i)),
            ),
        ];
        final groups = groupNotices(notices);
        expect(groups, hasLength(1));
        expect(groups.single.notices, hasLength(30000));
        expect(groups.single.ids, hasLength(30000));
        expect(groups.single.unreadCount, 15000);
        expect(groups.single.face.id, 'host-1');
        expect(groups.single.notices.first.id, 'host-1');
        expect(groups.single.notices.last.id, 'host-29998');
        expect(notices.first.id, 'host-0');
        expect(notices.last.id, 'host-29999');
      },
    );

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
