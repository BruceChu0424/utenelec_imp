import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/remote_access_repository.dart';
import 'package:uten_imp/features/auth/repositories/auth_repository.dart';
import 'package:uten_imp/features/auth/repositories/remote_mfa_repository.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  String? path;
  Object? body;
  Map<String, dynamic> response = {};
  int calls = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    calls++;
    return response;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.body = body;
    calls++;
    return response;
  }

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    this.path = path;
    this.body = body;
    calls++;
    return response;
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    this.path = path;
    this.body = body;
    calls++;
    return response;
  }
}

void main() {
  test(
    'policy command carries the observed version and never changes user grants',
    () async {
      final api = _Api();
      await DioRemoteAccessRepository(
        api,
      ).save(enabled: true, maxUsers: 5, expectedVersion: 7);
      expect(api.path, '/admin/remote-access/policy');
      expect(api.body, {'enabled': true, 'maxUsers': 5, 'expectedVersion': 7});
      await DioRemoteAccessRepository(api).revoke('employee-1');
      expect(api.path, '/admin/users/employee-1/remote-access');
      expect(api.body, {'remoteAccess': false});
    },
  );
  test('unknown or incomplete server status cannot appear healthy', () {
    expect(() => RemoteAccessStatus.fromJson({}), throwsA(anything));
    expect(
      () => RemoteAccessPolicy.fromJson({'enabled': true, 'maxUsers': 5}),
      throwsFormatException,
    );
    expect(
      () => RemoteAccessStatus.fromJson({
        'currentAccessChannel': 'office-guessed',
      }),
      throwsFormatException,
    );
  });
  test(
    'MFA mutations only send the code; six digits including leading zeros survive',
    () async {
      final api = _Api()..response = {'verifiedUntil': '2026-10-17T20:00:00Z'};
      final repo = DioRemoteMfaRepository(api);
      await repo.verify('001234');
      expect(api.path, '/auth/mfa/verify');
      expect(api.body, {'otpCode': '001234'});
      final calls = api.calls;
      await expectLater(repo.verify('123'), throwsFormatException);
      expect(api.calls, calls);
    },
  );
  test(
    'unconfirmed disable/reset never claims session revocation success',
    () async {
      final api = _Api();
      await expectLater(
        DioRemoteMfaRepository(api).disable('123456'),
        throwsFormatException,
      );
      await expectLater(
        DioRemoteAccessRepository(api).resetMfa('u1', 'Identity checked'),
        throwsFormatException,
      );
      api.response = {'reauthenticationRequired': true};
      await DioRemoteAccessRepository(api).resetMfa('u1', ' Identity checked ');
      expect(api.path, '/auth/mfa/users/u1/reset');
      expect(api.body, {'reason': 'Identity checked'});
    },
  );
  test(
    'password login remains compatible and OTP login explicitly adds its code',
    () async {
      final api = _Api()
        ..response = {
          'accessToken': 'access',
          'refreshToken': 'refresh',
          'expiresIn': 900,
          'mustChangePassword': false,
          'user': {
            'id': 'u1',
            'loginAccount': 'worker',
            'permissions': <String>[],
            'superAdmin': false,
          },
        };
      final repo = DioAuthRepository(api);
      await repo.login('worker', 'password');
      expect(api.body, {'loginAccount': 'worker', 'password': 'password'});
      await repo.loginWithOtp('worker', 'password', '001234');
      expect(api.body, {
        'loginAccount': 'worker',
        'password': 'password',
        'otpCode': '001234',
      });
    },
  );
}
