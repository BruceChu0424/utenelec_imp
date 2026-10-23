import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/dashboard/providers/local_system_test_policy.dart';

void main() {
  test(
    'only debug builds targeting literal loopback may use local test tools',
    () {
      for (final target in [
        'http://localhost:8080/api',
        'http://127.0.0.1:8080/api',
        'http://[::1]:8080/api',
      ]) {
        expect(permitsLocalSystemTests(target, debugBuild: true), isTrue);
        expect(permitsLocalSystemTests(target, debugBuild: false), isFalse);
      }
      for (final target in [
        '/api',
        '',
        'https://192.168.1.240/api',
        'https://imp.company.example/api',
        'http://127.0.0.1.example.com/api',
        'http://127.0.0.1@192.168.1.240/api',
        'http://127.0.0.1/api?target=production',
        'http://127.0.0.1/api#production',
      ]) {
        expect(
          permitsLocalSystemTests(target, debugBuild: true),
          isFalse,
          reason: target,
        );
      }
    },
  );
}
