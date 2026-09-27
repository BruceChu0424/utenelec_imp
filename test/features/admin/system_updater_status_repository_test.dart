import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';

void main() {
  test(
    'reads updater status using the local server status endpoint only',
    () async {
      final api = _Api({
        'requestedIntervalDays': 7,
        'requestedUpdatedAt': '2026-09-26T17:00:00Z',
        'appliedIntervalDays': 7,
        'configUpdatedAt': '2026-09-26T17:00:00Z',
        'checkedAt': '2026-09-27T01:01:00+08:00',
        'nextCheckAt': '2026-10-04T05:00:00+08:00',
        'lastAttemptAt': null,
        'lastResult': 'NEVER',
        'error': null,
        'available': true,
        'stale': false,
      });
      final result = await DioSystemSettingRepository(api).updaterStatus();
      expect(api.paths, ['${ApiEndpoints.adminSystemSettings}/updater-status']);
      expect(result.confirmed, isTrue);
      expect(result.nextCheckAt, '2026-10-04T05:00:00+08:00');
      expect(result.lastAttemptAt, isNull);
    },
  );

  test('absent or malformed status cannot become confirmed state', () async {
    for (final response in <Map<String, dynamic>>[
      {},
      {'requestedIntervalDays': '7', 'available': true, 'stale': false},
    ]) {
      await expectLater(
        DioSystemSettingRepository(_Api(response)).updaterStatus(),
        throwsFormatException,
      );
    }
  });

  test('matching interval with stale evidence is still unconfirmed', () async {
    final result = await DioSystemSettingRepository(
      _Api({
        'requestedIntervalDays': 0,
        'appliedIntervalDays': 0,
        'available': true,
        'stale': true,
        'lastResult': 'SUCCESS',
      }),
    ).updaterStatus();
    expect(result.confirmed, isFalse);
    expect(result.nextCheckAt, isNull);
  });
}

class _Api extends ApiClient {
  _Api(this.response) : super(Dio());
  final Map<String, dynamic> response;
  final List<String> paths = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    return response;
  }
}
