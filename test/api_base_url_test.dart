import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_base_url.dart';

void main() {
  test('development defaults to the local backend', () {
    expect(
      resolveApiBaseUrl('', releaseMode: false, web: false),
      'http://localhost:8080/api',
    );
  });

  test('Web release defaults to the same-origin API', () {
    expect(resolveApiBaseUrl('', releaseMode: true, web: true), '/api');
    expect(resolveApiBaseUrl('/api/', releaseMode: true, web: true), '/api');
  });

  test('non-Web release requires an explicit HTTPS URL', () {
    expect(
      () => resolveApiBaseUrl('', releaseMode: true, web: false),
      throwsStateError,
    );
    expect(
      () => resolveApiBaseUrl(
        'http://erp.example.com/api',
        releaseMode: true,
        web: false,
      ),
      throwsStateError,
    );
    expect(
      resolveApiBaseUrl(
        'https://erp.example.com/api/',
        releaseMode: true,
        web: false,
      ),
      'https://erp.example.com/api',
    );
  });

  test('release rejects loopback and malformed URLs', () {
    expect(
      () => resolveApiBaseUrl(
        'https://localhost/api',
        releaseMode: true,
        web: false,
      ),
      throwsStateError,
    );
    expect(
      () => resolveApiBaseUrl(
        'https://user@example.com/api',
        releaseMode: true,
        web: false,
      ),
      throwsStateError,
    );
    expect(
      () => resolveApiBaseUrl(
        'https://example.com/api?token=secret',
        releaseMode: true,
        web: false,
      ),
      throwsStateError,
    );
  });
}
