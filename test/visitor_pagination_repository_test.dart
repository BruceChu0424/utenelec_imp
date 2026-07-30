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
          final status = request.queryParameters['status'] as String;
          final page = request.queryParameters['page'] as int;
          return _pageJson(
            page: page,
            size: 100,
            total: status == 'pending' ? 101 : 1,
            totalPages: status == 'pending' ? 2 : 1,
          );
        }),
        SecureStorage(const FlutterSecureStorage()),
      );

      final applications = await repository.activeApplications();

      expect(applications, hasLength(5));
      expect(
        requests.map((request) => request.queryParameters['status']).toSet(),
        {'pending', 'hostReviewing', 'approved', 'checkedIn'},
      );
      expect(
        requests.where(
          (request) =>
              request.queryParameters['status'] == 'pending' &&
              request.queryParameters['page'] == 2,
        ),
        hasLength(1),
      );
      expect(
        requests.every((request) => request.queryParameters['size'] == 100),
        isTrue,
      );
    },
  );
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
