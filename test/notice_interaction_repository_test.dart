import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';

void main() {
  group('NoticeType.interactionMode', () {
    test('celebratory types map to bless', () {
      expect(NoticeType.birthday.interactionMode, NoticeInteractionMode.bless);
      expect(
        NoticeType.anniversary.interactionMode,
        NoticeInteractionMode.bless,
      );
      expect(NoticeType.wedding.interactionMode, NoticeInteractionMode.bless);
      expect(NoticeType.newborn.interactionMode, NoticeInteractionMode.bless);
      expect(NoticeType.birthday.isCelebratory, isTrue);
    });

    test('broadcast types map to acknowledge', () {
      for (final t in [
        NoticeType.announcement,
        NoticeType.policy,
        NoticeType.benefit,
        NoticeType.system,
        NoticeType.urgent,
      ]) {
        expect(
          t.interactionMode,
          NoticeInteractionMode.acknowledge,
          reason: '$t',
        );
      }
    });

    test('work types map to none', () {
      for (final t in [
        NoticeType.task,
        NoticeType.approval,
        NoticeType.workflow,
      ]) {
        expect(t.interactionMode, NoticeInteractionMode.none, reason: '$t');
      }
    });
  });

  group('NoticeInteractionMode.fromName', () {
    test('parses known values and defaults to none', () {
      expect(
        NoticeInteractionMode.fromName('bless'),
        NoticeInteractionMode.bless,
      );
      expect(
        NoticeInteractionMode.fromName('acknowledge'),
        NoticeInteractionMode.acknowledge,
      );
      expect(NoticeInteractionMode.fromName(null), NoticeInteractionMode.none);
      expect(
        NoticeInteractionMode.fromName('garbage'),
        NoticeInteractionMode.none,
      );
    });
  });

  group('DioNoticeRepository celebration + interactions', () {
    test('parses celebratory notice interaction fields', () async {
      final repo = DioNoticeRepository(_api((_) => _birthdayNoticeJson()));
      final notice = (await repo.getById('notice-1'))!;

      expect(notice.type, NoticeType.birthday);
      expect(notice.interactionMode, NoticeInteractionMode.bless);
      expect(notice.subjectName, '王小明');
      expect(notice.eventLabel, '生日快乐');
      expect(notice.blessingCount, 3);
      expect(notice.myBlessing, isNull);
      expect(notice.recentBlessings.length, 1);
      expect(notice.recentBlessings.first.senderName, '李同事');
      expect(notice.blessingTemplates.length, 2);
    });

    test('interactionMode falls back to type derivation when absent', () async {
      final repo = DioNoticeRepository(
        _api((_) => {..._birthdayNoticeJson(), 'interactionMode': null}),
      );
      final notice = (await repo.getById('notice-1'))!;
      // 后端未返回 interactionMode 时，按 type=birthday 派生为 bless
      expect(notice.interactionMode, NoticeInteractionMode.bless);
    });

    test(
      'publish sends subjectEmployeeId + blessingTemplates for celebration',
      () async {
        late RequestOptions captured;
        final repo = DioNoticeRepository(
          _api((r) {
            captured = r;
            return _birthdayNoticeJson();
          }),
        );
        await repo.publish(
          title: '祝王小明 生日快乐！',
          content: 'body',
          type: NoticeType.birthday,
          subjectEmployeeId: 'emp-1',
          blessingTemplates: const ['{name}，生日快乐！'],
        );
        expect(captured.data, containsPair('subjectEmployeeId', 'emp-1'));
        expect(
          captured.data,
          containsPair('blessingTemplates', ['{name}，生日快乐！']),
        );
        expect(captured.data, containsPair('type', 'birthday'));
      },
    );

    test(
      'publish omits subjectEmployeeId when null (null-aware element)',
      () async {
        late RequestOptions captured;
        final repo = DioNoticeRepository(
          _api((r) {
            captured = r;
            return _birthdayNoticeJson();
          }),
        );
        await repo.publish(
          title: '公告',
          content: '正文',
          type: NoticeType.announcement,
        );
        expect(
          (captured.data as Map<String, dynamic>).containsKey(
            'subjectEmployeeId',
          ),
          isFalse,
        );
        expect(
          (captured.data as Map<String, dynamic>).containsKey(
            'blessingTemplates',
          ),
          isFalse,
        );
      },
    );

    test('acknowledge POSTs /{id}/acknowledge and re-fetches', () async {
      final calls = <String>[];
      final repo = DioNoticeRepository(
        _api((r) {
          calls.add('${r.method} ${r.path}');
          if (r.method == 'POST' && r.path == '/notices/notice-1/acknowledge') {
            return {'ackCount': 5, 'myAcked': true};
          }
          return _announcementAckJson();
        }),
      );
      final notice = await repo.acknowledge('notice-1');
      expect(calls, contains('POST /notices/notice-1/acknowledge'));
      expect(notice.myAcked, isTrue);
      expect(notice.ackCount, 5);
    });

    test('bless POSTs /{id}/blessing with content', () async {
      late RequestOptions captured;
      final repo = DioNoticeRepository(
        _api((r) {
          if (r.method == 'POST' && r.path == '/notices/notice-1/blessing') {
            captured = r;
            return {'blessingCount': 4, 'myBlessing': '生日快乐！'};
          }
          return _birthdayNoticeJson();
        }),
      );
      final notice = await repo.bless('notice-1', '生日快乐！');
      expect(captured.path, '/notices/notice-1/blessing');
      expect(captured.data, containsPair('content', '生日快乐！'));
      // bless 写入后回查 getById（此处回查返回 birthdayNoticeJson：blessingCount=3）
      expect(notice.blessingCount, 3);
    });

    test('withdrawBlessing DELETEs /{id}/blessing', () async {
      final calls = <String>[];
      final repo = DioNoticeRepository(
        _api((r) {
          calls.add('${r.method} ${r.path}');
          if (r.method == 'DELETE' && r.path == '/notices/notice-1/blessing') {
            return {'blessingCount': 2};
          }
          return _birthdayNoticeJson();
        }),
      );
      await repo.withdrawBlessing('notice-1');
      expect(calls, contains('DELETE /notices/notice-1/blessing'));
    });

    test(
      'previewCelebration GETs /celebration/preview with employeeId+type',
      () async {
        late RequestOptions captured;
        final repo = DioNoticeRepository(
          _api((r) {
            captured = r;
            return {
              'subjectName': '王小明',
              'eventLabel': '入职5周年',
              'suggestedTitle': '祝王小明 入职5周年！',
              'suggestedTemplates': ['{name}，入职周年快乐！'],
            };
          }),
        );
        final preview = await repo.previewCelebration(
          employeeId: 'emp-1',
          type: NoticeType.anniversary,
        );
        expect(captured.method, 'GET');
        expect(captured.path, '/notices/celebration/preview');
        expect(captured.queryParameters, containsPair('type', 'anniversary'));
        expect(captured.queryParameters, containsPair('employeeId', 'emp-1'));
        expect(preview.subjectName, '王小明');
        expect(preview.eventLabel, '入职5周年');
        expect(preview.suggestedTemplates.single, '{name}，入职周年快乐！');
      },
    );

    test('listBlessings parses blessing wall items', () async {
      final repo = DioNoticeRepository(
        _api((_) {
          return {
            'items': [
              {
                'id': 'b1',
                'senderName': '李同事',
                'content': '生日快乐！',
                'createdAt': '2026-08-06T01:00:00Z',
                'mine': false,
              },
            ],
            'count': 1,
          };
        }),
      );
      final items = await repo.listBlessings('notice-1');
      expect(items.single.senderName, '李同事');
      expect(items.single.mine, isFalse);
    });
  });
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: responder(request),
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _birthdayNoticeJson() => {
  'id': 'notice-1',
  'title': '祝王小明 生日快乐！',
  'content': '今天是王小明的生日',
  'type': 'birthday',
  'publisher': '公司',
  'publishedAt': '2026-08-06T00:00:00Z',
  'isRead': false,
  'topPriority': false,
  'priority': 'normal',
  'attachments': <String>[],
  'audienceScope': 'all',
  'audienceSummary': '全体员工',
  'interactionMode': 'bless',
  'subjectName': '王小明',
  'eventLabel': '生日快乐',
  'ackCount': 0,
  'blessingCount': 3,
  'myAcked': false,
  'myBlessing': null,
  'recentAckers': <String>[],
  'recentBlessings': [
    {
      'id': 'b1',
      'senderName': '李同事',
      'content': '生日快乐！',
      'createdAt': '2026-08-06T01:00:00Z',
      'mine': false,
    },
  ],
  'blessingTemplates': ['{name}，生日快乐！', '{name}，愿你心想事成'],
};

Map<String, dynamic> _announcementAckJson() => {
  'id': 'notice-1',
  'title': '国庆放假',
  'content': '10月1日至7日放假',
  'type': 'announcement',
  'publisher': '人事部',
  'publishedAt': '2026-08-06T00:00:00Z',
  'isRead': true,
  'topPriority': false,
  'priority': 'normal',
  'attachments': <String>[],
  'audienceScope': 'all',
  'audienceSummary': '全体员工',
  'interactionMode': 'acknowledge',
  'subjectName': null,
  'eventLabel': null,
  'ackCount': 5,
  'blessingCount': 0,
  'myAcked': true,
  'myBlessing': null,
  'recentAckers': ['张三', '李四'],
  'recentBlessings': <Map<String, dynamic>>[],
  'blessingTemplates': <String>[],
};
