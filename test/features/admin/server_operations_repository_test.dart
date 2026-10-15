import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/server_operations_repository.dart';
import 'package:uten_imp/features/admin/repositories/server_storage_repository.dart';

void main() {
  test(
    'check uses only explicit check endpoint; update and schedule bind the confirmed version',
    () async {
      final api = _Api();
      final repository = DioServerOperationsRepository(api);
      await repository.status();
      expect(api.writes, isEmpty);
      await repository.startUpdate(
        requestId: 'r1',
        expectedSourceRevision: 's1',
        expectedCurrentVersion: 'v2.5.16',
      );
      expect(api.writes.single.$1, '/admin/server-operations/updates/check');
      expect(api.writes.single.$2, {
        'requestId': 'r1',
        'expectedSourceRevision': 's1',
        'expectedCurrentVersion': 'v2.5.16',
      });
      await repository.startUpdate(
        requestId: 'r2',
        expectedSourceRevision: 's1',
        expectedCurrentVersion: 'v2.5.16',
        mode: 'SCHEDULE_UPDATE',
        targetVersion: 'v2.5.18',
        scheduledAt: '2026-10-15T18:00:00Z',
      );
      expect(api.writes.last.$1, '/admin/server-operations/updates');
      expect(api.writes.last.$2['scheduledAt'], '2026-10-15T18:00:00Z');
      expect(api.writes.last.$2['targetVersion'], 'v2.5.18');
      expect(await repository.latestJob(), isNull);
    },
  );

  test(
    'mismatched update or cleanup receipts cannot be presented as our success',
    () async {
      final api = _Api()..wrongRequest = true;
      await expectLater(
        DioServerOperationsRepository(api).startUpdate(
          requestId: 'r1',
          expectedSourceRevision: 's1',
          expectedCurrentVersion: 'v2.5.16',
        ),
        throwsFormatException,
      );
      await expectLater(
        DioServerStorageRepository(
          api,
        ).cleanup(previewId: 'p1', requestId: 'r1'),
        throwsFormatException,
      );
    },
  );

  test('source success requires actual host-applied readback', () async {
    final api = _Api()..sourceApplied = false;
    await expectLater(
      DioServerOperationsRepository(
        api,
      ).saveSource({'requestId': 'r1', 'expectedRevision': 's1'}),
      throwsFormatException,
    );
  });
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool wrongRequest = false, sourceApplied = true;
  final writes = <(String, Map<String, dynamic>)>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.endsWith('/latest') ? {'job': null} : {'available': true};
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final data = Map<String, dynamic>.from(body! as Map);
    writes.add((path, data));
    return path.endsWith('/cleanup')
        ? {
            'requestId': wrongRequest ? 'other' : data['requestId'],
            'status': 'SUCCEEDED',
          }
        : {
            'id': 'job-1',
            'requestId': wrongRequest ? 'other' : data['requestId'],
            'state': 'QUEUED',
            'phase': 'CHECKING',
          };
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {
    'revision': 's2',
    'endpoint': 'https://oss.example.test',
    'bucket': 'bucket',
    'objectPrefix': 'releases',
    'applied': sourceApplied,
  };
}
