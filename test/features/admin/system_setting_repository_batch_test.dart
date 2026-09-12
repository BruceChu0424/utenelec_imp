import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/admin/repositories/system_setting_repository.dart';

void main() {
  const changes = [(key: 'lockout_minutes', value: '20', expectedValue: '15')];
  test(
    'settings batch uses one body-only password and includes the expected value',
    () async {
      final api = _Api([
        {'key': 'lockout_minutes', 'value': '20'},
      ]);
      final result = await DioSystemSettingRepository(
        api,
      ).updateBatch(changes, 'confirmed');
      expect(result.single.value, '20');
      expect(api.path, ApiEndpoints.adminSystemSettings);
      expect(api.body, {
        'password': 'confirmed',
        'changes': [
          {'key': 'lockout_minutes', 'value': '20', 'expectedValue': '15'},
        ],
      });
    },
  );
  test(
    'empty or incorrect successful response is not presented as a completed save',
    () async {
      for (final response in <List<Map<String, dynamic>>>[
        [],
        [
          {'key': 'lockout_minutes', 'value': '15'},
        ],
      ]) {
        await expectLater(
          DioSystemSettingRepository(
            _Api(response),
          ).updateBatch(changes, 'confirmed'),
          throwsFormatException,
        );
      }
    },
  );
}

class _Api extends ApiClient {
  _Api(this.response) : super(Dio());
  final List<Map<String, dynamic>> response;
  String? path;
  Object? body;
  @override
  Future<List<Map<String, dynamic>>> putList(
    String path, {
    Object? body,
  }) async {
    this.path = path;
    this.body = body;
    return response;
  }
}
