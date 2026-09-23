import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/visitor/repositories/visitor_repository.dart';
import 'package:uten_imp/features/visitor/repositories/visitor_staff_repository.dart';

void main() {
  test('visitor mine requests and parses a real server page', () async {
    late RequestOptions captured;
    final repository = DioVisitorRepository(
      _api((request) {
        captured = request;
        return _pageJson(page: 6, size: 100, total: 501, totalPages: 6);
      }),
      SecureStorage(const FlutterSecureStorage()),
    );

    final page = await repository.myApplications(
      status: 'approved',
      page: 6,
      size: 100,
    );

    expect(captured.path, '/visitor/applications/mine');
    expect(captured.queryParameters, {
      'page': 6,
      'size': 100,
      'status': 'approved',
    });
    expect(page.page, 6);
    expect(page.total, 501);
    expect(page.items.single.id, 'visitor-app-1');
  });

  test('approval and host queues send page, size and status filters', () async {
    final requests = <RequestOptions>[];
    final repository = VisitorStaffRepository(
      _api((request) {
        requests.add(request);
        return _pageJson();
      }),
    );

    await repository.approvalList(status: 'rejected', page: 3, size: 40);
    await repository.myAsHost(status: 'hostReviewing', page: 2, size: 30);

    expect(requests.first.path, '/visitor-approval');
    expect(requests.first.queryParameters, {
      'page': 3,
      'size': 40,
      'status': 'rejected',
    });
    expect(requests.last.path, '/visitor-approval/as-host');
    expect(requests.last.queryParameters, {
      'page': 2,
      'size': 30,
      'status': 'hostReviewing',
    });
  });

  test(
    'active conflict lookup pages by active state, not all history',
    () async {
      final requests = <RequestOptions>[];
      final repository = DioVisitorRepository(
        _api((request) {
          requests.add(request);
          final page = request.queryParameters['page'] as int;
          return _pageJson(
            page: page,
            size: 100,
            total: page == 1 ? 101 : 1,
            totalPages: page == 1 ? 2 : 1,
          );
        }),
        SecureStorage(const FlutterSecureStorage()),
      );

      final applications = await repository.activeApplications();

      // 后端多状态一次取全活跃集：每页一个请求，状态集固定。
      expect(applications, hasLength(2));
      expect(
        requests.map((request) => request.queryParameters['status']).toSet(),
        {'pending,hostReviewing,approved,checkedIn'},
      );
      expect(
        requests.where((request) => request.queryParameters['page'] == 2),
        hasLength(1),
      );
      expect(
        requests.every((request) => request.queryParameters['size'] == 100),
        isTrue,
      );
    },
  );
  // security-08 / permissions-13：访客只能按姓名先搜再选接待人(至少 2 个字、服务端最多回 5 人、
  // 只列可对外接待的员工)，不再下发部门树，结果不带部门；不足 2 个字不发请求。
  test(
    'host search needs two characters and never lists by department',
    () async {
      final requests = <RequestOptions>[];
      final repository = DioVisitorRepository(
        _api((request) {
          requests.add(request);
          return [
            {'id': 'e1', 'name': '王小明'},
          ];
        }),
        SecureStorage(const FlutterSecureStorage()),
      );

      expect(await repository.searchHosts(''), isEmpty);
      expect(await repository.searchHosts(' 王 '), isEmpty);
      expect(requests, isEmpty);

      final hosts = await repository.searchHosts('王小');
      expect(requests.single.path, '/visitor/directory/employees');
      expect(requests.single.queryParameters, {'keyword': '王小'});
      expect(hosts.single.name, '王小明');
    },
  );

  test('blacklist endpoints hit canonical paths with reason body', () async {
    final requests = <RequestOptions>[];
    final repository = VisitorStaffRepository(
      _api((request) {
        requests.add(request);
        return {
          'items': <Map<String, dynamic>>[],
          'page': 1,
          'size': 20,
          'total': 0,
          'totalPages': 0,
        };
      }),
    );

    await repository.blacklist('visitor-1', reason: '冒用凭证');
    await repository.unblacklist('visitor-1');
    final page = await repository.blacklistPage();

    expect(requests[0].path, '/security/blacklist/visitor-1');
    expect(requests[0].data, {'reason': '冒用凭证'});
    expect(requests[1].path, '/security/blacklist/visitor-1');
    expect(requests[1].method, 'DELETE');
    expect(requests[2].path, '/security/blacklist');
    expect(requests[2].queryParameters, {'page': 1, 'size': 20});
    expect(page.total, 0);
  });
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: responder(request),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _pageJson({
  int page = 1,
  int size = 20,
  int total = 1,
  int totalPages = 1,
}) => {
  'items': [
    {
      'id': 'visitor-app-1',
      'visitorName': '访客',
      'visitPurpose': '会议',
      'status': 'pending',
      'plannedVisitAt': '2026-07-31T09:00:00Z',
      'appliedAt': '2026-07-30T09:00:00Z',
    },
  ],
  'page': page,
  'size': size,
  'total': total,
  'totalPages': totalPages,
};
