import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/models/notice_audience.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';

void main() {
  test(
    'selected audience is sent to publish and parsed from response',
    () async {
      late RequestOptions captured;
      final repository = DioNoticeRepository(
        _api((request) {
          captured = request;
          return _noticeJson();
        }),
      );

      final result = await repository.publish(
        title: '停电通知',
        content: '今晚 20:00 停电检修',
        type: NoticeType.announcement,
        audienceScope: NoticeAudienceScope.selected,
        departmentIds: const ['department-1', 'department-2'],
        employeeIds: const ['employee-1'],
      );

      expect(captured.method, 'POST');
      expect(captured.path, '/notices');
      expect(captured.data, containsPair('audienceScope', 'selected'));
      expect(
        captured.data,
        containsPair('departmentIds', ['department-1', 'department-2']),
      );
      expect(captured.data, containsPair('employeeIds', ['employee-1']));
      expect(result.audienceScope, NoticeAudienceScope.selected);
      expect(result.audienceSummary, '生产部等 2 个部门、张三');
      expect(result.audienceCount, 18);
    },
  );

  test('audience preview uses server-resolved recipient count', () async {
    late RequestOptions captured;
    final repository = DioNoticeRepository(
      _api((request) {
        captured = request;
        return {'summary': '生产部、张三', 'recipientCount': 12};
      }),
    );

    final result = await repository.previewAudience(
      departmentIds: const ['department-1'],
      employeeIds: const ['employee-1'],
    );

    expect(captured.path, '/notices/audience/preview');
    expect(captured.data, {
      'departmentIds': ['department-1'],
      'employeeIds': ['employee-1'],
    });
    expect(result.summary, '生产部、张三');
    expect(result.recipientCount, 12);
  });

  test('employee audience search only sends a non-empty keyword', () async {
    late RequestOptions captured;
    final repository = DioNoticeRepository(
      _api((request) {
        captured = request;
        return [
          {
            'id': 'employee-1',
            'name': '张三',
            'code': 'E001',
            'departmentName': '生产部',
          },
        ];
      }),
    );

    final result = await repository.searchAudienceEmployees(search: ' 张三 ');

    expect(captured.method, 'GET');
    expect(captured.path, '/notices/audience/employees');
    expect(captured.queryParameters, {'search': '张三'});
    expect(result.single.name, '张三');
    expect(result.single.departmentName, '生产部');
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

Map<String, dynamic> _noticeJson() => {
  'id': 'notice-1',
  'title': '停电通知',
  'content': '今晚 20:00 停电检修',
  'type': 'announcement',
  'publisher': '李经理',
  'publishedAt': '2026-07-30T12:00:00Z',
  'isRead': false,
  'topPriority': false,
  'priority': 'normal',
  'attachments': <String>[],
  'audienceScope': 'selected',
  'audienceSummary': '生产部等 2 个部门、张三',
  'audienceCount': 18,
};
