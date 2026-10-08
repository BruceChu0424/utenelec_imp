import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';
import 'package:uten_imp/core/network/session_event_bus.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/quality/repositories/production_fqc_repository.dart';
import 'package:uten_imp/features/quality/services/quality_batch_submission.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final method in ['GET', 'POST']) {
    test(
      'unscoped $method retry cannot promote expired impersonation to staff',
      () async {
        final storage = _Storage()
          ..impersonation = _impersonation('same-target');
        final headers = <String>[];
        final notices = <ImpersonationExpiryNotice?>[];
        final subscription = SessionEventBus.instance.onImpersonationExpired
            .listen(notices.add);
        addTearDown(subscription.cancel);
        late RequestOptions original;
        final dio = _dio(storage, (options) async {
          original = options;
          headers.add(options.headers['Authorization'] as String);
          return _response({'ok': true});
        });
        await dio.request<dynamic>(
          '/business',
          options: Options(method: method),
        );
        storage.impersonation = _expired(storage.impersonation!);
        final outcome = await dio
            .fetch<dynamic>(original)
            .then<Object?>((_) => null, onError: (Object error) => error);
        expect(
          headers,
          ['Bearer imp-same-target'],
          reason:
              'The old logical request must never reach the adapter with staff credentials',
        );
        expect(
          outcome,
          isA<DioException>().having(
            (error) => (error.response?.data as Map?)?['code'],
            'code',
            'SESSION_CHANGED',
          ),
        );
        await pumpEventQueue();
        expect(notices, hasLength(1));
        expect(notices.single?.lineage, 'same-target');
        expect(notices.single?.staffLineage, 'initial');
        expect(notices.single?.staffIntent, 1);
        expect(notices.single?.baseUrl, 'https://erp.example.test/api');

        // Clearing expiry does not revive the retained request; a new UI request
        // may use the restored staff identity only through new RequestOptions.
        storage.impersonation = null;
        await expectLater(
          dio.fetch<dynamic>(original),
          throwsA(isA<DioException>()),
        );
        expect(headers, hasLength(1));
        await dio.request<dynamic>(
          '/business',
          options: Options(method: method),
        );
        expect(headers, ['Bearer imp-same-target', 'Bearer initial-access']);
      },
    );
  }

  test(
    'a fresh unscoped request also refuses an expired impersonation record',
    () async {
      final storage = _Storage()
        ..impersonation = _expired(_impersonation('expired-before-request'));
      var calls = 0;
      final api = _api(storage, (_) async {
        calls++;
        return _response({'ok': true});
      });
      await expectLater(
        api.post('/business'),
        _throwsBoundary('SESSION_CHANGED'),
      );
      expect(calls, 0);
    },
  );

  test(
    'explicit staff management remains reachable with expired impersonation',
    () async {
      final storage = _Storage()
        ..impersonation = _expired(_impersonation('expired-target'));
      final headers = <String>[];
      final api = _api(storage, (options) async {
        headers.add(options.headers['Authorization'] as String);
        return _response({'ok': true});
      });
      await api.post('/admin/impersonation/start');
      await api.post('/auth/step-up');
      expect(headers, ['Bearer initial-access', 'Bearer initial-access']);
    },
  );

  test(
    'an operation-scoped management request refuses expired impersonation',
    () async {
      final storage = _Storage()
        ..impersonation = _impersonation('initial-target');
      var calls = 0;
      final api = _api(storage, (_) async {
        calls++;
        return _response({'ok': true});
      });
      final scope = await api.captureRequestScope(isCurrent: () => true);
      storage.impersonation = _expired(storage.impersonation!);
      await expectLater(
        scope.run(() => api.post('/auth/step-up')),
        _throwsBoundary('SESSION_CHANGED'),
      );
      expect(calls, 0);
    },
  );

  test(
    'a failed identity read finishes even while the other storage read is pending',
    () async {
      final storage = _Storage();
      final release = Completer<void>();
      storage.beforeImpersonationRead = () => release.future;
      storage.failNextRead = true;
      final api = _api(
        storage,
        (_) async => throw StateError('must not dispatch'),
      );
      try {
        await expectLater(
          api
              .captureRequestScope(isCurrent: () => true)
              .timeout(const Duration(seconds: 2)),
          _throwsBoundary('SESSION_STATE_UNAVAILABLE'),
        );
      } finally {
        release.complete();
      }
    },
  );

  for (final failAfter401 in [2, 3]) {
    test(
      'a storage failure during 401 step $failAfter401 completes with a session boundary error',
      () async {
        final storage = _Storage();
        var calls = 0;
        final api = _api(storage, (_) async {
          calls++;
          storage.snapshot = _session(
            'initial',
            1,
            generation: 2,
            access: 'sibling-refreshed',
          );
          storage.failAtAuthRead = storage.authReads + failAfter401;
          return _response({
            'code': 'UNAUTHORIZED',
            'message': 'expired',
          }, status: 401);
        });
        await expectLater(
          api
              .post('/business', body: const {})
              .timeout(const Duration(seconds: 3)),
          _throwsBoundary('SESSION_STATE_UNAVAILABLE'),
        );
        expect(calls, 1);
      },
    );
  }

  test(
    'a changed session response cannot continue the old quality batch',
    () async {
      final storage = _Storage();
      final requests = <String>[];
      final api = _api(storage, (options) async {
        requests.add(options.headers['Authorization'] as String);
        if (requests.length == 1) storage.snapshot = _session('new-login', 2);
        return _response({'processedCount': 1});
      });
      final batch = _batch();
      await expectLater(
        batch.send(
          iqc: DioProcurementInspectionRepository(api),
          fqc: ProductionFqcRepository(api),
          requestScope: await api.captureRequestScope(isCurrent: () => true),
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SESSION_CHANGED',
          ),
        ),
      );
      expect(requests, ['Bearer initial-access']);
      expect(batch.completedReceiptCount, 0);
      expect(batch.complete, isFalse);
    },
  );

  test(
    'switching after a valid acknowledgement stops before the next receipt',
    () async {
      final storage = _Storage();
      final requests = <String>[];
      final api = _api(storage, (options) async {
        requests.add(options.headers['Authorization'] as String);
        return _response({'processedCount': 1});
      });
      final batch = _batch();
      await expectLater(
        batch.send(
          requestScope: await api.captureRequestScope(isCurrent: () => true),
          iqc: DioProcurementInspectionRepository(api),
          fqc: ProductionFqcRepository(api),
          onProgress: () => storage.snapshot = _session('new-login', 2),
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'SESSION_CHANGED',
          ),
        ),
      );
      expect(requests, ['Bearer initial-access']);
      expect(batch.completedReceiptCount, 1);
      expect(batch.acknowledgedIqcIds, ['inspection-1']);
    },
  );

  test('same-lineage refresh permits remaining IQC and FQC commands', () async {
    final storage = _Storage();
    final headers = <String>[];
    final api = _api(storage, (options) async {
      headers.add(options.headers['Authorization'] as String);
      return _response({'processedCount': 1});
    });
    final batch = _batch();
    await _send(
      batch,
      api,
      onProgress: () {
        storage.snapshot = _session(
          'initial',
          1,
          generation: 8,
          access: 'refreshed-access',
        );
      },
    );
    expect(headers, [
      'Bearer initial-access',
      'Bearer refreshed-access',
      'Bearer refreshed-access',
    ]);
    expect(batch.complete, isTrue);
  });

  for (final change in [
    'intent-only',
    'same-account-login',
    'enter-imp',
    'switch-imp',
    'exit-imp',
  ]) {
    test(
      'a $change boundary preserves ack and cannot rebind this batch on retry',
      () async {
        final storage = _Storage();
        if (change == 'switch-imp' || change == 'exit-imp') {
          storage.impersonation = _impersonation('first');
        }
        final paths = <String>[];
        final api = _api(storage, (options) async {
          paths.add(options.path);
          return _response({'processedCount': 1});
        });
        final batch = _batch();
        final keys = jsonEncode(batch.exportDraft()['receipts']);
        await expectLater(
          _send(
            batch,
            api,
            onProgress: () {
              switch (change) {
                case 'intent-only':
                  storage.snapshot = _session('initial', 2);
                case 'same-account-login':
                  storage.snapshot = _session('replacement-login', 2);
                case 'enter-imp':
                  storage.impersonation = _impersonation('first');
                case 'switch-imp':
                  storage.impersonation = _impersonation('second');
                case 'exit-imp':
                  storage.impersonation = null;
              }
            },
          ),
          _throwsBoundary('SESSION_CHANGED'),
        );
        expect(paths, hasLength(1));
        expect(batch.completedReceiptCount, 1);
        expect(jsonEncode(batch.exportDraft()['receipts']), keys);
        await expectLater(
          _send(batch, api),
          _throwsBoundary('SESSION_CHANGED'),
        );
        expect(
          paths,
          hasLength(1),
          reason: 'Capturing the new identity cannot revive the old batch',
        );
      },
    );
  }

  test(
    'session-state read failure stops this attempt, then retries the original unacknowledged keys',
    () async {
      final storage = _Storage();
      final commands = <Object?>[];
      final api = _api(storage, (options) async {
        commands.add(options.data);
        return _response({'processedCount': 1});
      });
      final batch = _batch();
      await expectLater(
        _send(
          batch,
          api,
          onProgress: () {
            storage.failNextRead = true;
          },
        ),
        _throwsBoundary('SESSION_STATE_UNAVAILABLE'),
      );
      expect(commands, hasLength(1));
      expect(batch.completedReceiptCount, 1);
      await _send(batch, api);
      expect(commands, hasLength(3));
      final second = commands[1] as Map;
      expect(
        ((second['items'] as List).single as Map)['idempotencyKey'],
        'original-key-2',
      );
      expect((commands.last as Map)['idempotencyKey'], 'original-fqc-key');
    },
  );

  test(
    'an ordinary 409 continues, but a concurrent identity boundary takes precedence',
    () async {
      for (final switchSession in [false, true]) {
        final storage = _Storage();
        var calls = 0;
        final api = _api(storage, (options) async {
          calls++;
          if (calls == 1) {
            if (switchSession) storage.snapshot = _session('replacement', 2);
            return _response({
              'code': 'CONFLICT',
              'message': 'quantity changed',
            }, status: 409);
          }
          return _response({'processedCount': 1});
        });
        await expectLater(
          _send(_batch(), api),
          _throwsBoundary(switchSession ? 'SESSION_CHANGED' : 'CONFLICT'),
        );
        expect(calls, switchSession ? 1 : 2);
      }
    },
  );

  test(
    'initial capture cannot adopt a new intent during its storage read',
    () async {
      final storage = _Storage();
      final blocked = Completer<void>();
      storage.beforeAuthRead = () => blocked.future;
      var epoch = 0;
      final api = _api(
        storage,
        (_) async => throw StateError('must not dispatch'),
      );
      final capture = api.captureRequestScope(isCurrent: () => epoch == 0);
      final assertion = expectLater(
        capture,
        _throwsBoundary('SESSION_CHANGED'),
      );
      epoch++;
      storage.snapshot = _session('same-user-new-login', 2);
      blocked.complete();
      await assertion;
    },
  );

  for (final boundary in ['session', 'page', 'server']) {
    test(
      '$boundary change during asynchronous audit cannot dispatch with new credentials',
      () async {
        final storage = _Storage();
        final entered = Completer<void>(), release = Completer<void>();
        var current = true;
        var calls = 0;
        final dio = _dio(
          storage,
          (_) async {
            calls++;
            return _response({'processedCount': 1});
          },
          beforeAuth: [
            InterceptorsWrapper(
              onRequest: (options, handler) async {
                entered.complete();
                await release.future;
                handler.next(options);
              },
            ),
          ],
        );
        final api = ApiClient(dio);
        final scope = await api.captureRequestScope(isCurrent: () => current);
        final assertion = expectLater(
          _send(_batch(), api, scope: scope),
          _throwsBoundary('SESSION_CHANGED'),
        );
        await entered.future;
        if (boundary == 'session') {
          storage.snapshot = _session('replacement', 2);
        }
        if (boundary == 'page') current = false;
        if (boundary == 'server') {
          current = false;
          dio.options.baseUrl = 'https://other.example.test/api';
        }
        release.complete();
        await assertion;
        expect(calls, 0);
      },
    );
  }

  test(
    'an identity switch while AuthInterceptor reads storage is checked again before the header is sent',
    () async {
      final storage = _Storage();
      final entered = Completer<void>(), release = Completer<void>();
      var calls = 0;
      final dio = _dio(
        storage,
        (_) async {
          calls++;
          return _response({'ok': true});
        },
        beforeAuth: [
          InterceptorsWrapper(
            onRequest: (options, handler) {
              storage.beforeImpersonationRead = () async {
                entered.complete();
                await release.future;
                storage.beforeImpersonationRead = null;
              };
              handler.next(options);
            },
          ),
        ],
      );
      final api = ApiClient(dio);
      final scope = await api.captureRequestScope(isCurrent: () => true);
      final assertion = expectLater(
        scope.run(() => api.post('/business', body: const {})),
        _throwsBoundary('SESSION_CHANGED'),
      );
      await entered.future;
      storage.snapshot = _session('replacement', 2);
      release.complete();
      await assertion;
      expect(calls, 0);
    },
  );

  test(
    '401 replay rechecks the original binding after its own asynchronous audit',
    () async {
      final storage = _Storage();
      final replayEntered = Completer<void>(),
          releaseReplay = Completer<void>();
      var businessCalls = 0, refreshCalls = 0;
      Future<ResponseBody> reply(RequestOptions options) async {
        if (options.path == '/auth/refresh') {
          refreshCalls++;
          return _response({
            'accessToken': 'refreshed',
            'refreshToken': 'refreshed-r',
          });
        }
        businessCalls++;
        return _response({
          'code': 'UNAUTHORIZED',
          'message': 'expired',
        }, status: 401);
      }

      Dio retryFactory() {
        final dio = Dio(buildApiBaseOptions('https://erp.example.test/api'));
        dio.httpClientAdapter = _Adapter(reply);
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              if (options.path != '/auth/refresh') {
                replayEntered.complete();
                await releaseReplay.future;
              }
              handler.next(options);
            },
          ),
        );
        return dio;
      }

      final api = ApiClient(_dio(storage, reply, factory: retryFactory));
      final assertion = expectLater(
        _send(_batch(), api),
        _throwsBoundary('SESSION_CHANGED'),
      );
      await replayEntered.future;
      storage.impersonation = _impersonation('entered-during-replay');
      releaseReplay.complete();
      await assertion;
      expect(refreshCalls, 1);
      expect(businessCalls, 1);
    },
  );

  test(
    'an existing logical request cannot be repinned from staff to impersonation',
    () async {
      final storage = _Storage();
      late RequestOptions original;
      var calls = 0;
      final dio = _dio(storage, (options) async {
        original = options;
        calls++;
        return _response({'ok': true});
      });
      await dio.post<dynamic>('/business');
      storage.impersonation = _impersonation('new-target');
      await expectLater(
        dio.fetch<dynamic>(original),
        throwsA(
          isA<DioException>().having(
            (error) => (error.response?.data as Map?)?['code'],
            'code',
            'SESSION_CHANGED',
          ),
        ),
      );
      expect(calls, 1);
      expect(original.headers['Authorization'], 'Bearer initial-access');
    },
  );
}

Matcher _throwsBoundary(String code) =>
    throwsA(isA<ApiException>().having((error) => error.code, 'code', code));

Future<void> _send(
  QualityBatchSubmission batch,
  ApiClient api, {
  void Function()? onProgress,
  AuthenticatedRequestScope? scope,
}) async => batch.send(
  iqc: DioProcurementInspectionRepository(api),
  fqc: ProductionFqcRepository(api),
  onProgress: onProgress,
  requestScope: scope ?? await api.captureRequestScope(isCurrent: () => true),
);

ImpersonationRecord _impersonation(String lineage) => ImpersonationRecord(
  accessToken: 'imp-$lineage',
  lineage: lineage,
  windowExpiresAtEpochMs: DateTime.now()
      .add(const Duration(minutes: 5))
      .millisecondsSinceEpoch,
);

ImpersonationRecord _expired(ImpersonationRecord record) => ImpersonationRecord(
  accessToken: record.accessToken,
  lineage: record.lineage,
  generation: record.generation,
  windowExpiresAtEpochMs: DateTime.now()
      .subtract(const Duration(seconds: 1))
      .millisecondsSinceEpoch,
);

AuthTokenSnapshot _session(
  String lineage,
  int intent, {
  String? access,
  int? generation,
}) => AuthTokenSnapshot(
  accessToken: access ?? '$lineage-access',
  refreshToken: '$lineage-refresh',
  generation: generation ?? intent,
  intentGeneration: intent,
  sessionLineage: lineage,
);

class _Storage extends SecureStorage {
  _Storage() : super(const FlutterSecureStorage());
  AuthTokenSnapshot snapshot = _session('initial', 1);
  ImpersonationRecord? impersonation;
  Future<void> Function()? beforeAuthRead;
  Future<void> Function()? beforeImpersonationRead;
  bool failNextRead = false;
  int authReads = 0;
  int? failAtAuthRead;
  @override
  Future<AuthTokenSnapshot> getAuthTokenSnapshot() async {
    authReads++;
    await beforeAuthRead?.call();
    if (failNextRead || authReads == failAtAuthRead) {
      failNextRead = false;
      throw StateError('synthetic unavailable storage');
    }
    return snapshot;
  }

  @override
  Future<ImpersonationRecord?> getImpersonationRecord() async {
    await beforeImpersonationRead?.call();
    return impersonation;
  }

  @override
  Future<bool> saveTokensIfUnchanged({
    required AuthTokenSnapshot expected,
    required String accessToken,
    String? refreshToken,
  }) async {
    if (!snapshot.isSameSession(expected)) return false;
    snapshot = AuthTokenSnapshot(
      accessToken: accessToken,
      refreshToken: refreshToken ?? snapshot.refreshToken,
      generation: snapshot.generation + 1,
      intentGeneration: snapshot.intentGeneration,
      sessionLineage: snapshot.sessionLineage,
    );
    return true;
  }
}

QualityBatchSubmission _batch() => QualityBatchSubmission(
  receipts: [
    for (var index = 1; index <= 2; index++)
      QualityReceiptSubmission(
        receiptType: 'PURCHASE',
        receiptId: 'receipt-$index',
        label: 'R$index',
        items: [
          ProcurementInspectionDecideItem(
            inspectionItemId: 'inspection-$index',
            expectedRemainingBaseQty: 1,
            passBaseQty: 1,
            failBaseQty: 0,
            idempotencyKey: 'original-key-$index',
          ),
        ],
      ),
  ],
  fqcInspectionIds: ['fqc-1'],
  reason: null,
  fqcKey: 'original-fqc-key',
);

ApiClient _api(
  _Storage storage,
  Future<ResponseBody> Function(RequestOptions) reply,
) {
  return ApiClient(_dio(storage, reply));
}

Dio _dio(
  _Storage storage,
  Future<ResponseBody> Function(RequestOptions) reply, {
  List<Interceptor> beforeAuth = const [],
  Dio Function()? factory,
}) {
  final dio = Dio(buildApiBaseOptions('https://erp.example.test/api'));
  dio.interceptors.addAll(beforeAuth);
  dio.interceptors.add(
    AuthInterceptor(
      storage: storage,
      baseUrl: dio.options.baseUrl,
      dioFactory: factory,
    ),
  );
  dio.httpClientAdapter = _Adapter(reply);
  return dio;
}

ResponseBody _response(Object body, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final Future<ResponseBody> Function(RequestOptions) reply;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => reply(options);
  @override
  void close({bool force = false}) {}
}
