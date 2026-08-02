import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';

void main() {
  test('health probe targets actuator outside the API base path', () {
    expect(healthProbeBaseUrl('/api'), '');
    expect(
      healthProbeBaseUrl('http://localhost:8080/api'),
      'http://localhost:8080',
    );
    expect(
      healthProbeBaseUrl('https://erp.example.cn/gateway/api'),
      'https://erp.example.cn',
    );
  });

  test('only an explicit actuator UP payload marks the server healthy', () {
    expect(
      isHealthyProbeResponse(200, <String, String>{'status': 'UP'}),
      isTrue,
    );
    expect(isHealthyProbeResponse(200, '<html>SPA fallback</html>'), isFalse);
    expect(isHealthyProbeResponse(200, <String, String>{}), isFalse);
    expect(
      isHealthyProbeResponse(503, <String, String>{'status': 'DOWN'}),
      isFalse,
    );
  });
}
