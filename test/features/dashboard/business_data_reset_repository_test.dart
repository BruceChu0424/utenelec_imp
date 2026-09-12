import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/security/tab_scoped_store.dart';
import 'package:uten_imp/features/dashboard/models/business_data_reset_attempt.dart';
import 'package:uten_imp/features/dashboard/providers/business_data_reset_journal.dart';
import 'package:uten_imp/features/dashboard/repositories/system_test_repository.dart';

const _server = 'https://reset.test/api';
const _operator = 'c9b11073-c9d1-4e57-bc71-42ec89f4a541';
const _success = <String, Object>{
  'clearedTableCount': 269,
  'clearedRows': 697,
  'preservedTableCount': 96,
  'authorizationEpochAfter': 366,
  'deletedAttachmentFiles': 0,
};

class _MemoryScope implements TabScopedStore {
  final values = <String, String>{};
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('local storage unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<(int, Object)> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (status, body) = await respond(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiSystemTestRepository _repo(
  Dio dio,
  BusinessDataResetJournal journal, {
  String operator = _operator,
  String server = _server,
}) => ApiSystemTestRepository(
  ApiClient(dio),
  server: server,
  operatorId: operator,
  journal: journal,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'HTTP status metadata preserves existing business codes and messages',
    () {
      final error = ApiExceptionFactory.fromDioStatusCode(
        504,
        const ApiError(code: 'INTERNAL', message: 'gateway'),
      );
      expect(error.code, 'INTERNAL');
      expect(error.message, 'gateway');
      expect(error.httpStatus, 504);
      expect(
        ApiExceptionFactory.fromDioStatusCode(
          409,
          const ApiError(code: 'CONFLICT', message: 'rejected'),
        ).code,
        'CONFLICT',
      );
    },
  );

  for (final status in [502, 504]) {
    test(
      'gateway $status stores one exact pending request and never submits it again',
      () async {
        final store = _MemoryScope();
        final journal = BusinessDataResetJournal(store);
        var calls = 0;
        String? sentAttempt;
        final dio = Dio(BaseOptions(baseUrl: _server))
          ..httpClientAdapter = _Adapter((request) {
            calls++;
            sentAttempt = (request.data as Map)['attemptId'] as String;
            return (
              status,
              {'code': 'INTERNAL', 'message': 'gateway unavailable'},
            );
          });
        final repository = _repo(dio, journal);
        await expectLater(
          repository.resetBusinessData(),
          throwsA(isA<BusinessDataResetPendingException>()),
        );
        final pending = await journal.read(_server, _operator);
        expect(pending?.id, sentAttempt);
        await expectLater(
          _repo(dio, BusinessDataResetJournal(store)).resetBusinessData(),
          throwsA(isA<BusinessDataResetPendingException>()),
        );
        expect(calls, 1);
      },
    );
  }

  test(
    'a late authenticated 200 still obeys the global session fence and remains pending',
    () async {
      final scope = _MemoryScope();
      final storage = SecureStorage(
        const FlutterSecureStorage(),
        sessionScope: scope,
      );
      final journal = BusinessDataResetJournal(scope);
      await storage.saveTokens(
        accessToken: 'original-access',
        refreshToken: 'original-refresh',
      );
      var posts = 0;
      final dio = Dio(BaseOptions(baseUrl: _server));
      dio.interceptors.add(AuthInterceptor(storage: storage, baseUrl: _server));
      dio.httpClientAdapter = _Adapter((request) async {
        expect(request.headers['Authorization'], 'Bearer original-access');
        posts++;
        // Simulate the sibling 401's authoritative token clear before the reset
        // success reaches AuthInterceptor.onResponse. No real reset is executed.
        await storage.clearForLogoutIntent();
        return (200, _success);
      });
      final repository = _repo(dio, journal);
      await expectLater(
        repository.resetBusinessData(),
        throwsA(isA<BusinessDataResetPendingException>()),
      );
      expect(await journal.read(_server, _operator), isNotNull);
      await expectLater(
        repository.resetBusinessData(),
        throwsA(isA<BusinessDataResetPendingException>()),
      );
      expect(posts, 1);
    },
  );

  test(
    'only exact target operator and attempt ID can confirm a pending reset',
    () async {
      final scope = _MemoryScope();
      final journal = BusinessDataResetJournal(scope);
      final attempt = BusinessDataResetAttempt(
        id: 'd30d2338-abdc-4241-880b-8ce14b8ae900',
        server: _server,
        operatorId: _operator,
        startedAt: DateTime.utc(2026, 9, 12),
      );
      await journal.save(attempt);
      final Map<String, Object?> completion = {
        ..._success,
        'available': true,
        'finishedAt': '2026-09-12T00:02:03Z',
        'operatorAccount': 'admin',
        'operatorId': 'someone-else',
        'attemptId': attempt.id,
      };
      final queries = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: _server))
        ..httpClientAdapter = _Adapter((request) {
          queries.add(request);
          return (200, completion);
        });
      final repository = _repo(dio, journal);
      expect(
        (await repository.lastBusinessDataResetResult())
            .confirmedPendingAttempt,
        isFalse,
      );
      completion['operatorId'] = _operator;
      completion['attemptId'] = 'another-tab-attempt';
      expect(
        (await repository.lastBusinessDataResetResult())
            .confirmedPendingAttempt,
        isFalse,
      );
      completion.remove('attemptId');
      expect(
        (await repository.lastBusinessDataResetResult())
            .confirmedPendingAttempt,
        isFalse,
      );
      expect(await journal.read(_server, _operator), isNotNull);
      expect(
        await _repo(
          dio,
          journal,
          operator: 'new-account',
        ).pendingBusinessDataReset(),
        isNull,
      );
      expect(
        await _repo(
          dio,
          journal,
          server: 'https://other.test/api',
        ).pendingBusinessDataReset(),
        isNull,
      );
      completion['attemptId'] = attempt.id;
      expect(
        (await repository.lastBusinessDataResetResult())
            .confirmedPendingAttempt,
        isTrue,
      );
      expect(await journal.read(_server, _operator), isNull);
      expect(
        queries.every(
          (request) =>
              request.method == 'GET' &&
              request.queryParameters['attemptId'] == attempt.id,
        ),
        isTrue,
      );
    },
  );

  test(
    'definitive server refusal permits a new explicit command but persistence failure sends none',
    () async {
      final scope = _MemoryScope();
      final journal = BusinessDataResetJournal(scope);
      var calls = 0;
      final dio = Dio(BaseOptions(baseUrl: _server))
        ..httpClientAdapter = _Adapter((request) {
          calls++;
          return (409, {'code': 'CONFLICT', 'message': 'outbox refused'});
        });
      final repository = _repo(dio, journal);
      await expectLater(
        repository.resetBusinessData(),
        throwsA(
          isA<ApiException>().having((error) => error.code, 'code', 'CONFLICT'),
        ),
      );
      expect(await journal.read(_server, _operator), isNull);
      await expectLater(
        repository.resetBusinessData(),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 2);
      scope.failWrites = true;
      await expectLater(
        repository.resetBusinessData(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'RESET_CONFIRMATION_UNAVAILABLE',
          ),
        ),
      );
      expect(calls, 2);
    },
  );

  test(
    'known success removes only its own receipt and never changes another operator record',
    () async {
      final scope = _MemoryScope();
      final journal = BusinessDataResetJournal(scope);
      final other = BusinessDataResetAttempt(
        id: 'other',
        server: _server,
        operatorId: 'other-user',
        startedAt: DateTime.utc(2026, 9, 12),
      );
      await journal.save(other);
      final dio = Dio(BaseOptions(baseUrl: _server))
        ..httpClientAdapter = _Adapter((request) => (200, _success));
      expect((await _repo(dio, journal).resetBusinessData()).clearedRows, 697);
      expect(await journal.read(_server, _operator), isNull);
      expect((await journal.read(_server, 'other-user'))?.id, 'other');
    },
  );
}
