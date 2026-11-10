import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_log.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_store.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/core/network/business_precision_coordinator.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/step_up_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/visitor_auth_interceptor.dart';
import 'package:uten_imp/core/network/step_up_coordinator.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'each recovered network attempt has a terminal diagnostic event',
    () async {
      final prior = AppDiagnostics.log;
      final log = DiagnosticLog(_LogStore());
      AppDiagnostics.log = log;
      addTearDown(() => AppDiagnostics.log = prior);
      final world = await _World.create(refreshRequired: true);
      addTearDown(world.dispose);
      await world.api.post(
        '/finance/receipts',
        body: {'requestId': 'private-business-input'},
      );
      final text = utf8.decode(await log.export());
      final events = const LineSplitter()
          .convert(text)
          .map((line) => jsonDecode(line) as Map)
          .where((row) => row['path'] == '/finance/receipts')
          .toList();
      expect(
        events.where((row) => row['event'] == 'request.begin'),
        hasLength(2),
      );
      expect(
        events.where(
          (row) => row['event'] == 'request.failed' && row['status'] == 401,
        ),
        hasLength(1),
      );
      expect(
        events.where(
          (row) => row['event'] == 'request.end' && row['status'] == 200,
        ),
        hasLength(1),
      );
      expect(text, isNot(contains('private-business-input')));
      expect(text, isNot(contains('old-access')));
    },
  );

  test(
    'a prior unknown write stays unknown after a later explicit refusal',
    () async {
      final world = await _World.create(
        refreshRequired: true,
        precisionRequired: true,
      );
      addTearDown(world.dispose);
      final transport = BusinessPrecisionTransport();
      const body = {'requestId': 'same-request', 'amount': '1.00000000000001'};
      world.unknownNext = true;
      await expectLater(
        transport.run(() => world.api.post('/finance/receipts', body: body)),
        throwsA(isA<ApiException>()),
      );
      transport.beginRun(unknown: true);
      await expectLater(
        transport.run(() => world.api.post('/finance/receipts', body: body)),
        throwsA(isA<ApiException>()),
      );
      expect(
        world.prompts,
        0,
        reason: 'The earlier unknown write cannot gain a precision replay',
      );
      expect(world.applied, 0);
      expect(world.businessRequests, 3);
      expect(world.refreshes, 1);
      expect(transport.canAsk, false);
      final attempt =
          (transport.snapshot()['attempts'] as Map).values.single as Map;
      expect(attempt['uncertain'], true);
    },
  );

  test(
    'a second 401 cannot loop through the complete replay pipeline',
    () async {
      final world = await _World.create(refreshRequired: true);
      addTearDown(world.dispose);
      world.alwaysUnauthorized = true;
      await expectLater(
        world.api.post(
          '/finance/receipts',
          body: {'requestId': 'same-request'},
        ),
        throwsA(isA<ApiException>()),
      );
      expect(world.refreshes, 1);
      expect(world.businessRequests, 2);
      expect(world.applied, 0);
      expect(world.writeRevisions, 0);
    },
  );

  for (final changedVisitor in [false, true]) {
    test(
      'visitor replay keeps its original owner (identity change=$changedVisitor)',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final storage = SecureStorage(const FlutterSecureStorage());
        await storage.saveVisitorTokens(
          accessToken: 'visitor-old',
          refreshToken: 'visitor-refresh',
        );
        const baseUrl = 'https://visitor.example/api';
        var refreshes = 0, applied = 0, businessRequests = 0;
        ResponseBody respond(RequestOptions options) {
          if (options.path == '/visitor/auth/refresh') {
            refreshes++;
            return _json(200, {
              'accessToken': 'visitor-new',
              'refreshToken': 'visitor-refresh-new',
            });
          }
          businessRequests++;
          if (options.headers['Authorization'] != 'Bearer visitor-new') {
            return _json(401, {'code': 'UNAUTHORIZED'});
          }
          applied++;
          return _json(200, {'applied': true});
        }

        Dio fresh() =>
            Dio(BaseOptions(baseUrl: baseUrl))
              ..httpClientAdapter = _Adapter(respond);
        final dio = fresh();
        addTearDown(() => dio.close(force: true));
        dio.interceptors.add(
          VisitorAuthInterceptor(
            storage: storage,
            baseUrl: baseUrl,
            dioFactory: fresh,
            replay: (options) async {
              if (changedVisitor) {
                await storage.saveVisitorTokens(
                  accessToken: 'another-visitor',
                  refreshToken: 'another-refresh',
                );
              }
              return dio.fetch<dynamic>(options);
            },
          ),
        );
        final api = ApiClient(dio);
        final transport = BusinessPrecisionTransport();
        final operation = transport.run(
          () => api.post(
            '/visitor/confirmation',
            body: {'requestId': 'visitor-request'},
          ),
        );
        if (changedVisitor) {
          await expectLater(
            operation,
            throwsA(
              isA<ApiException>().having(
                (error) => error.code,
                'code',
                'SESSION_CHANGED',
              ),
            ),
          );
          expect(applied, 0);
          expect(
            businessRequests,
            1,
            reason: 'No old request may dispatch for the new visitor',
          );
          expect(await storage.getVisitorAccessToken(), 'another-visitor');
          return;
        }
        await operation;
        expect(applied, 1);
        expect(refreshes, 1);
        final attempt =
            (transport.snapshot()['attempts'] as Map).values.single as Map;
        expect(attempt['uncertain'], false);
        expect(attempt['completedMutation'], true);
      },
    );
  }

  test(
    '401 recovery completes successful write revision and precision state',
    () async {
      final world = await _World.create(refreshRequired: true);
      addTearDown(world.dispose);
      final transport = BusinessPrecisionTransport();
      expect(
        await transport.run(
          () => world.api.post(
            '/finance/receipts',
            body: {'requestId': 'same-request', 'amount': '1.00000000000001'},
          ),
        ),
        {'applied': true},
      );
      expect(
        world.writeRevisions,
        1,
        reason: 'A recovered server success must still retire stale lists',
      );
      final attempt =
          (transport.snapshot()['attempts'] as Map).values.single as Map;
      expect(attempt['uncertain'], false);
      expect(attempt['completedMutation'], true);
      expect(world.applied, 1);
      expect(world.refreshes, 1);
      expect(world.businessRequests, 2);
    },
  );

  for (final refresh in [false, true]) {
    test(
      'step-up then precision preserves the not-written receipt (401=$refresh)',
      () async {
        final world = await _World.create(
          refreshRequired: refresh,
          stepUpRequired: true,
          precisionRequired: true,
        );
        addTearDown(world.dispose);
        final transport = BusinessPrecisionTransport();
        expect(
          await transport.run(
            () => world.api.post(
              '/finance/receipts',
              body: {'requestId': 'same-request', 'amount': '1.00000000000001'},
            ),
          ),
          {'applied': true},
        );
        expect(world.prompts, 1);
        expect(world.passwordPrompts, 1);
        expect(world.applied, 1);
        expect(world.refreshes, refresh ? 1 : 0);
        expect(world.writeRevisions, 1);
        expect(world.businessRequests, refresh ? 4 : 3);
        final attempt =
            (transport.snapshot()['attempts'] as Map).values.single as Map;
        expect(attempt['uncertain'], false);
        expect(attempt['completedMutation'], true);
      },
    );
  }
}

class _World {
  _World();
  late final Dio dio;
  late final ApiClient api;
  final precision = BusinessPrecisionCoordinator();
  final stepUp = StepUpCoordinator();
  int applied = 0, refreshes = 0, businessRequests = 0, writeRevisions = 0;
  int prompts = 0, passwordPrompts = 0;
  bool unknownNext = false, alwaysUnauthorized = false;

  static Future<_World> create({
    required bool refreshRequired,
    bool stepUpRequired = false,
    bool precisionRequired = false,
  }) async {
    final world = _World();
    FlutterSecureStorage.setMockInitialValues({});
    const baseUrl = 'https://replay.example/api';
    final storage = SecureStorage(const FlutterSecureStorage());
    await storage.saveTokens(
      accessToken: 'old-access',
      refreshToken: 'refresh',
      issuer: AuthBackendRealmPolicy().issuerFor(baseUrl),
    );
    ResponseBody respond(RequestOptions options) {
      if (options.path == '/auth/refresh') {
        world.refreshes++;
        return _json(200, {
          'accessToken': 'new-access',
          'refreshToken': 'refresh-new',
        });
      }
      world.businessRequests++;
      if (world.unknownNext) {
        world.unknownNext = false;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      }
      if (world.alwaysUnauthorized ||
          refreshRequired &&
              options.headers['Authorization'] == 'Bearer old-access') {
        return _json(401, {'code': 'UNAUTHORIZED'});
      }
      if (stepUpRequired &&
          options.headers[StepUpInterceptor.header] != 'step-up') {
        return _json(403, {'code': 'REAUTH_REQUIRED'});
      }
      if (precisionRequired &&
          options.headers[businessPrecisionHeader] == null) {
        return _json(422, {
          'code': 'PRECISION_CHOICE_REQUIRED',
          'details': {
            'calculationKey': 'test.current',
            'groupKey': 'test.current',
            'label': '本次精度',
            'maxScale': 30,
            'suggestedScale': 2,
            'reason': 'NON_TERMINATING',
            'notWritten': true,
          },
        });
      }
      world.applied++;
      return _json(200, {'applied': true});
    }

    Dio fresh() =>
        Dio(BaseOptions(baseUrl: baseUrl))
          ..httpClientAdapter = _Adapter(respond);
    world.dio = fresh();
    final auth = AuthInterceptor(
      storage: storage,
      baseUrl: baseUrl,
      dioFactory: fresh,
      replay: world.dio.fetch<dynamic>,
    );
    world.dio.interceptors.add(auth);
    world.stepUp.register(() async {
      world.passwordPrompts++;
      return 'step-up';
    });
    world.dio.interceptors.add(
      StepUpInterceptor(
        world.dio,
        coordinator: world.stepUp,
        identity: AuthInterceptor.retainedIdentity,
        isCurrent: auth.requestBelongsToCurrentIdentity,
      ),
    );
    world.dio.interceptors.add(
      DataWriteRevisionInterceptor((_) => world.writeRevisions++),
    );
    world.precision.register((_) async {
      world.prompts++;
      return const BusinessPrecisionChoice(5, 'HALF_UP');
    });
    world.api = ApiClient(
      world.dio,
      precisionCoordinator: world.precision,
      precisionIdentity: AuthInterceptor.retainedIdentity,
      precisionIsCurrent: auth.requestBelongsToCurrentIdentity,
    );
    return world;
  }

  void dispose() {
    precision.clear();
    stepUp.clear();
    dio.close(force: true);
  }
}

ResponseBody _json(int status, Map<String, Object> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}

class _LogStore implements DiagnosticStore {
  final lines = StringBuffer();
  @override
  String? get directory => null;
  @override
  Future<void> append(String text) async => lines.write(text);
  @override
  Future<Uint8List> readRecent() async =>
      Uint8List.fromList(utf8.encode(lines.toString()));
  @override
  Future<void> openDirectory() async {}
}
