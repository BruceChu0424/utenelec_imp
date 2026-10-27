import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';

Map<String, dynamic> _receipt({
  bool account = true,
  String id = 'employee-1',
}) => {
  'employee': {
    'id': id,
    'code': 'UT0001',
    'fullName': '同名员工',
    'phone': '138****0000',
    'status': 'probation',
    'accountStatus': account ? 'active' : null,
  },
  'temporaryPassword': account ? 'Synthetic-One-Time!42' : null,
  'loginAccount': account ? '13800000000' : null,
};

DioEmployeeRepository _repository(
  Map<String, dynamic> receipt, {
  void Function(RequestOptions)? capture,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        capture?.call(request);
        handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: request,
            statusCode: 200,
            data: receipt,
          ),
        );
      },
    ),
  );
  return DioEmployeeRepository(ApiClient(dio));
}

EmployeeOnboardingInput _input(AccountInput account) => EmployeeOnboardingInput(
  profile: const {'fullName': '同名员工'},
  employment: const {'departmentId': 'department-1'},
  account: account,
);

void main() {
  test(
    'nested account intent preserves explicit false and legacy omission',
    () {
      expect(const AccountInput().toJson(), isEmpty);
      expect(const AccountInput(openAccount: false).toJson(), {
        'openAccount': false,
      });
      expect(const AccountInput(openAccount: true).toJson(), {
        'openAccount': true,
      });
    },
  );

  test(
    'explicit record-only onboarding accepts an employee without credentials',
    () async {
      late RequestOptions captured;
      final result = await _repository(
        _receipt(account: false),
        capture: (request) => captured = request,
      ).create(_input(const AccountInput(openAccount: false)));
      expect(captured.method, 'POST');
      expect(captured.path, '/org/employees');
      final payload = captured.data as Map<String, dynamic>;
      expect(payload['account'], {'openAccount': false});
      expect(result.employee.id, 'employee-1');
      expect(result.employee.accountStatus, isNull);
      expect(result.loginAccount, isNull);
      expect(result.temporaryPassword, isNull);
      expect(result.hasAccountCredentials, isFalse);
    },
  );

  for (final account in [
    const AccountInput(),
    const AccountInput(openAccount: true),
  ]) {
    test(
      'onboarding issuance requires a real credential receipt intent=${account.openAccount}',
      () async {
        final result = await _repository(_receipt()).create(_input(account));
        expect(result.loginAccount, '13800000000');
        expect(result.temporaryPassword, 'Synthetic-One-Time!42');
        await expectLater(
          _repository(_receipt(account: false)).create(_input(account)),
          throwsA(isA<FormatException>()),
        );
      },
    );
  }

  test(
    'record-only request cannot silently accept a server-created login account',
    () async {
      await expectLater(
        _repository(
          _receipt(),
        ).create(_input(const AccountInput(openAccount: false))),
        throwsA(isA<FormatException>()),
      );
    },
  );

  for (final account in <Object?>[null, '', '   ']) {
    test(
      'provisioning never invents a missing login account from masked phone/code value=$account',
      () async {
        await expectLater(
          _repository({
            ..._receipt(),
            'loginAccount': account,
          }).provisionAccount('employee-1'),
          throwsA(isA<FormatException>()),
        );
      },
    );
  }

  test(
    'provisioning reply must belong to the exact selected employee UUID',
    () async {
      await expectLater(
        _repository(
          _receipt(id: 'other-employee'),
        ).provisionAccount('employee-1'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'existing-employee provision endpoint returns the supplied username without inferring it',
    () async {
      late RequestOptions captured;
      final result = await _repository(
        {..._receipt(), 'loginAccount': 'actual-server-login'},
        capture: (request) => captured = request,
      ).provisionAccount('employee-1');
      expect(captured.path, '/org/employees/employee-1/account');
      expect(captured.method, 'POST');
      expect(captured.data, isNull);
      expect(result.loginAccount, 'actual-server-login');
    },
  );
}
