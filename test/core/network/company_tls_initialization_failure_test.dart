import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/company_tls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a missing bundled CA leaves startup usable but company connections fail closed',
    () async {
      await initializeCompanyTls(
        loadAsset: (_) async => throw StateError('Missing test asset'),
      );
      final dio = createCompanyDio(BaseOptions());
      try {
        await expectLater(
          dio.get<Object?>('https://imp.utenelec/api/auth/me'),
          throwsA(
            isA<DioException>().having(
              companyTlsFailure,
              'certificate failure',
              isA<CompanyTlsException>(),
            ),
          ),
        );
      } finally {
        dio.close(force: true);
      }
    },
  );
}
