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
  'deletedAttachmentFiles': 4,
  'deadBackgroundEventsCleared': 2,
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
    if (body is String) {
      // 网关(nginx)自己生成的错误页：HTML，不是后端统一错误格式。
      return ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
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
      expect(error.hasResponseCode, isTrue);
      expect(
        ApiExceptionFactory.fromDioStatusCode(
          409,
          const ApiError(code: 'CONFLICT', message: 'rejected'),
        ).code,
        'CONFLICT',
      );
      // 没有统一错误体(网关错误页)：错误码是本端按 HTTP 状态补的。
      final gateway = ApiExceptionFactory.fromDioStatusCode(502, null);
      expect(gateway.code, 'INTERNAL');
      expect(gateway.httpStatus, 502);
      expect(gateway.hasResponseCode, isFalse);
      // 框架默认错误页的 JSON 没有 code：同样不算服务端给出的错误码。
      final springDefault = ApiExceptionFactory.fromDioStatusCode(
        500,
        ApiError.fromJson(const {
          'timestamp': '2026-10-05T01:00:00Z',
          'status': 500,
          'error': 'Internal Server Error',
          'path': '/api/system-test/business-data/reset',
        }),
      );
      expect(springDefault.code, 'UNKNOWN');
      expect(springDefault.hasResponseCode, isFalse);
    },
  );

  // 说明不了服务端有没有执行完的响应：记一条待确认，绝不再发第二次。
  const springDefaultError = <String, Object>{
    'timestamp': '2026-10-05T01:00:00Z',
    'status': 500,
    'error': 'Internal Server Error',
    'path': '/api/system-test/business-data/reset',
  };
  for (final (label, status, body) in <(String, int?, Object?)>[
    ('gateway 502 page', 502, '<html><body>502 Bad Gateway</body></html>'),
    ('gateway 503 page', 503, '<html><body>503 Unavailable</body></html>'),
    ('gateway 504 page', 504, '<html><body>504 Gateway Time-out</body></html>'),
    ('bare 500 page', 500, '<html><body>500 Internal Error</body></html>'),
    ('framework default 500 JSON without code', 500, springDefaultError),
    (
      'server says the outcome is uncertain',
      500,
      const {
        'code': 'RESET_OUTCOME_UNCERTAIN',
        'message': '业务数据清空未确认完成，请重新登录核对本次结果(事务提交或完成回执写入失败)',
      },
    ),
    ('response without status or body', null, null),
  ]) {
    test(
      '$label stores one exact pending request and never submits it again',
      () async {
        final store = _MemoryScope();
        final journal = BusinessDataResetJournal(store);
        var calls = 0;
        String? sentAttempt;
        final dio = Dio(BaseOptions(baseUrl: _server))
          ..httpClientAdapter = _Adapter((request) {
            calls++;
            sentAttempt = (request.data as Map)['attemptId'] as String;
            if (status == null) {
              throw DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response(requestOptions: request),
              );
            }
            return (status, body!);
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

  // 服务端带统一错误码说明的失败(含 500)是确定的失败：原文照登，本地记录撤销，
  // 之后用户明确再点一次才会再发。
  const deletedThenDbFailed =
      '本次已经物理删除了 2 个测试文件(无法恢复)，但业务数据没有清空，所以这些测试单据上的附件现在打不开。'
      '原因：业务数据清空执行失败，已整体回滚：磁盘空间不足。请重新点「确认清空」；如果再次出现，请联系开发人员。'
      '已删除的文件下次不会重复处理。';
  for (final (status, code, message) in [
    (500, 'INTERNAL', deletedThenDbFailed),
    (
      500,
      'RESET_SERVER_MISCONFIGURED',
      '服务器上清空程序的数据库账号配置有误，本次没有删除任何文件，也没有清空数据。请联系开发人员处理。',
    ),
    (503, 'PRIMARY_UNAVAILABLE', '云端暂不可写：本地主库不可达，恢复网络后重试'),
  ]) {
    test('server $code/$status is a definite failure shown verbatim', () async {
      final store = _MemoryScope();
      final journal = BusinessDataResetJournal(store);
      var calls = 0;
      final dio = Dio(BaseOptions(baseUrl: _server))
        ..httpClientAdapter = _Adapter((request) {
          calls++;
          return (status, {'code': code, 'message': message});
        });
      final repository = _repo(dio, journal);
      await expectLater(
        repository.resetBusinessData(),
        throwsA(
          isA<ApiException>()
              .having((error) => error.code, 'code', code)
              .having((error) => error.message, 'message', message)
              .having(
                (error) => error is BusinessDataResetPendingException,
                'pending',
                isFalse,
              ),
        ),
      );
      expect(await journal.read(_server, _operator), isNull);
      await expectLater(
        repository.resetBusinessData(),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 2);
    });
  }

  test(
    'only responses that cannot prove the outcome keep the reset pending',
    () {
      for (var status = 500; status < 600; status++) {
        expect(
          isBusinessDataResetOutcomeUncertain(
            ApiException('INTERNAL', '服务器繁忙，请稍后再试', httpStatus: status),
          ),
          isTrue,
          reason: 'HTTP $status without a server error code proves nothing',
        );
        expect(
          isBusinessDataResetOutcomeUncertain(
            ApiException(
              'INTERNAL',
              'server explained the failure',
              httpStatus: status,
              hasResponseCode: true,
            ),
          ),
          isFalse,
          reason: 'HTTP $status with a server error code is a definite failure',
        );
      }
      for (final error in [
        NetworkException(),
        NetworkTimeoutException(),
        BusinessDataResetPendingException(),
        ApiException(
          'RESET_OUTCOME_UNCERTAIN',
          'commit acknowledgement lost',
          httpStatus: 500,
          hasResponseCode: true,
        ),
        ApiException(
          'SESSION_CHANGED',
          '登录状态已切换，本次旧请求结果已忽略',
          httpStatus: 409,
          hasResponseCode: true,
        ),
        ApiException(
          'SESSION_STATE_UNAVAILABLE',
          '账号状态暂时无法确认',
          httpStatus: 409,
          hasResponseCode: true,
        ),
      ]) {
        expect(
          isBusinessDataResetOutcomeUncertain(error),
          isTrue,
          reason: error.code,
        );
      }
      for (final status in [400, 401, 403, 409, 422, 429]) {
        expect(
          isBusinessDataResetOutcomeUncertain(
            ApiException('REFUSED', 'request rejected', httpStatus: status),
          ),
          isFalse,
        );
      }
      // 本端在发请求之前就停下(没有 HTTP 状态)：请求没发出，不是待确认。
      expect(
        isBusinessDataResetOutcomeUncertain(
          ApiException('RESET_CONFIRMATION_UNAVAILABLE', '无法保存清空请求的待确认记录'),
        ),
        isFalse,
      );
    },
  );

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

  // ADR-067 §9：服务端受理/失败回执把本地待确认记录确定地收尾，不靠「查不到完成回执」猜。
  group('server receipts settle a pending reset', () {
    final startedAt = DateTime.utc(2026, 9, 20, 15, 40);
    Future<(ApiSystemTestRepository, BusinessDataResetJournal)> pending(
      Map<String, Object?> lastResult, {
      required DateTime now,
    }) async {
      final scope = _MemoryScope();
      final journal = BusinessDataResetJournal(scope);
      await journal.save(
        BusinessDataResetAttempt(
          id: 'attempt-pending',
          server: _server,
          operatorId: _operator,
          startedAt: startedAt,
        ),
      );
      final dio = Dio(BaseOptions(baseUrl: _server))
        ..httpClientAdapter = _Adapter((request) => (200, lastResult));
      final repository = ApiSystemTestRepository(
        ApiClient(dio),
        server: _server,
        operatorId: _operator,
        journal: journal,
        now: () => now,
      );
      return (repository, journal);
    }

    test('never received: retired only after the grace window', () async {
      final notReceived = <String, Object?>{
        'available': false,
        'attemptReceived': false,
      };
      final (early, earlyJournal) = await pending(
        notReceived,
        now: startedAt.add(const Duration(seconds: 5)),
      );
      final earlyResult = await early.lastBusinessDataResetResult();
      expect(earlyResult.retiredPendingReason, isNull);
      expect(await earlyJournal.read(_server, _operator), isNotNull);

      final (late, lateJournal) = await pending(
        notReceived,
        now: startedAt.add(businessDataResetNeverReceivedGrace),
      );
      final lateResult = await late.lastBusinessDataResetResult();
      expect(lateResult.retiredPendingReason, contains('没有收到本次清空请求'));
      expect(lateResult.confirmedPendingAttempt, isFalse);
      expect(await lateJournal.read(_server, _operator), isNull);
    });

    test('received and still running keeps the pending record', () async {
      final (repository, journal) = await pending({
        'available': false,
        'attemptReceived': true,
        'attemptReceivedByCurrentServer': true,
      }, now: startedAt.add(const Duration(minutes: 30)));
      final result = await repository.lastBusinessDataResetResult();
      expect(result.retiredPendingReason, isNull);
      expect(result.attemptReceived, isTrue);
      expect(await journal.read(_server, _operator), isNotNull);
    });

    test('received by a previous server process retires the record', () async {
      final (repository, journal) = await pending({
        'available': false,
        'attemptReceived': true,
        'attemptReceivedByCurrentServer': false,
      }, now: startedAt.add(const Duration(seconds: 1)));
      final result = await repository.lastBusinessDataResetResult();
      expect(result.retiredPendingReason, contains('重启'));
      expect(await journal.read(_server, _operator), isNull);
    });

    test(
      'explicit failure retires the record with the server reason',
      () async {
        const summary =
            '失败原因：后台事件排队中 2 条。没有删除文件，也没有清空数据。'
            '完整原因(含文件名)请在清空弹窗点「重新检查」查看。';
        final (repository, journal) = await pending({
          'available': false,
          'attemptReceived': true,
          'attemptReceivedByCurrentServer': true,
          'attemptFailed': true,
          'attemptFailureMessage': summary,
          'attemptDeletedAttachmentFiles': 0,
        }, now: startedAt.add(const Duration(seconds: 1)));
        final result = await repository.lastBusinessDataResetResult();
        expect(result.retiredPendingReason, '上次清空没有完成：$summary');
        expect(await journal.read(_server, _operator), isNull);
      },
    );

    test(
      'a failure after some files were deleted states the deleted count',
      () async {
        const summary = '失败原因：删除文件失败。完整原因(含文件名)请在清空弹窗点「重新检查」查看。';
        final (repository, journal) = await pending({
          'available': false,
          'attemptReceived': true,
          'attemptReceivedByCurrentServer': true,
          'attemptFailed': true,
          'attemptFailureMessage': summary,
          'attemptDeletedAttachmentFiles': 3,
        }, now: startedAt.add(const Duration(seconds: 1)));
        final result = await repository.lastBusinessDataResetResult();
        expect(result.attemptDeletedAttachmentFiles, 3);
        expect(
          result.retiredPendingReason,
          '上次清空没有完成：$summary(已物理删除 3 个测试文件，数据没有清空)',
        );
        expect(await journal.read(_server, _operator), isNull);
      },
    );

    test('the deleted count is not repeated when the summary states it', () {
      const summary =
          '失败原因：删除用完 5 分钟。本次已物理删除 7 个测试文件，数据没有清空。'
          '完整原因(含文件名)请在清空弹窗点「重新检查」查看。';
      expect(
        businessDataResetFailureNotice(
          const BusinessDataResetLastResult(
            available: false,
            attemptFailed: true,
            attemptFailureMessage: summary,
            attemptDeletedAttachmentFiles: 7,
          ),
        ),
        '上次清空没有完成：$summary',
      );
      expect(
        businessDataResetFailureNotice(
          const BusinessDataResetLastResult(
            available: false,
            attemptFailed: true,
          ),
        ),
        '上次清空没有完成：服务器已拒绝本次请求',
      );
    });

    test('an older completion by the same operator never retires it', () async {
      final (repository, journal) = await pending({
        ..._success,
        'available': true,
        'finishedAt': '2026-09-20T05:43:30Z',
        'operatorAccount': 'admin',
        'operatorId': _operator,
        'attemptId': 'some-earlier-attempt',
        'attemptReceived': true,
        'attemptReceivedByCurrentServer': true,
      }, now: startedAt.add(const Duration(hours: 2)));
      final result = await repository.lastBusinessDataResetResult();
      expect(result.retiredPendingReason, isNull);
      expect(result.confirmedPendingAttempt, isFalse);
      expect(await journal.read(_server, _operator), isNotNull);
    });
  });

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
      final result = await _repo(dio, journal).resetBusinessData();
      expect(result.clearedRows, 697);
      expect(result.deletedAttachmentFiles, 4);
      expect(result.deadBackgroundEventsCleared, 2);
      expect(await journal.read(_server, _operator), isNull);
      expect((await journal.read(_server, 'other-user'))?.id, 'other');
    },
  );

  test(
    'preview reads the single server check without sending a command',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: _server))
        ..httpClientAdapter = _Adapter((request) {
          requests.add(request);
          return (
            200,
            {
              'locations': 5,
              'presentFiles': 3,
              'absentFiles': 1,
              'inspectedObjects': 4,
              'inspectionComplete': false,
              'allListedMissing': false,
              'kinds': [
                {'label': '业务附件', 'files': 3},
                {'label': 'AI识别原件', 'files': 2},
              ],
              'deadBackgroundEvents': [
                {'label': '货品单重重算', 'events': 2},
              ],
              'refusals': [
                {
                  'code': 'VERSION_MISMATCH',
                  'count': 1,
                  'message': '1 个文件在存储里的内容和登记的不是同一份(文件被替换过)',
                },
              ],
            },
          );
        });
      final journal = BusinessDataResetJournal(_MemoryScope());
      final preview = await _repo(dio, journal).previewBusinessDataReset();
      expect(requests.single.method, 'GET');
      expect(requests.single.path, '/system-test/business-data/preview');
      expect(preview.locations, 5);
      expect(preview.presentFiles, 3);
      expect(preview.absentFiles, 1);
      expect(preview.inspectedObjects, 4);
      expect(preview.inspectionComplete, isFalse);
      expect(preview.inspectionSkipped, isFalse, reason: '字段缺失按做了核对处理');
      expect(preview.allListedMissing, isFalse);
      expect(preview.kinds.map((kind) => '${kind.label}:${kind.files}'), [
        '业务附件:3',
        'AI识别原件:2',
      ]);
      expect(preview.deadBackgroundEventCount, 2);
      expect(preview.deadBackgroundEvents.single.label, '货品单重重算');
      expect(preview.refused, isTrue);
      expect(preview.refusals.single.code, 'VERSION_MISMATCH');
      expect(preview.refusals.single.count, 1);
      expect(preview.refusals.single.message, '1 个文件在存储里的内容和登记的不是同一份(文件被替换过)');
      expect(await journal.read(_server, _operator), isNull);
    },
  );

  test('an empty check is not refused', () {
    final preview = BusinessDataResetPreview.fromJson(const {
      'locations': 0,
      'presentFiles': 0,
      'absentFiles': 0,
      'inspectedObjects': 0,
      'inspectionComplete': true,
      'allListedMissing': false,
      'kinds': <Object>[],
      'deadBackgroundEvents': <Object>[],
      'refusals': <Object>[],
    });
    expect(preview.refused, isFalse);
    expect(preview.inspectionComplete, isTrue);
    expect(preview.inspectionSkipped, isFalse);
    expect(preview.deadBackgroundEventCount, 0);
    expect(
      BusinessDataResetPreview.fromJson(const {
        'locations': 4,
        'inspectionComplete': false,
        'inspectionSkipped': true,
      }).inspectionSkipped,
      isTrue,
    );
  });

  test('last result carries dead events and the failed attempt deletions', () {
    final result = BusinessDataResetLastResult.fromJson(const {
      ..._success,
      'available': true,
      'attemptReceived': true,
      'attemptFailed': true,
      'attemptFailureMessage': '失败原因：删除文件失败。',
      'attemptDeletedAttachmentFiles': 5,
    });
    expect(result.deadBackgroundEventsCleared, 2);
    expect(result.attemptDeletedAttachmentFiles, 5);
    final copied = result.retiredPendingAttempt('reason');
    expect(copied.deadBackgroundEventsCleared, 2);
    expect(copied.attemptDeletedAttachmentFiles, 5);
    expect(copied.retiredPendingReason, 'reason');
  });
}
