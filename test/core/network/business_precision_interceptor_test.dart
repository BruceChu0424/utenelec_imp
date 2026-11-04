import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/core/network/business_precision_coordinator.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

Map<String, dynamic> _require(
  String key, {
  bool notWritten = true,
  bool selectionRejected = false,
}) => {
  'code': 'PRECISION_CHOICE_REQUIRED',
  'message': '请选择本次精度',
  'details': {
    'calculationKey': key,
    'groupKey': key,
    'label': '本次报表比率',
    'maxScale': 30,
    'suggestedScale': 2,
    'reason': 'NON_TERMINATING',
    'notWritten': notWritten,
    if (selectionRejected) 'selectionRejected': true,
  },
};

class _Request {
  _Request(RequestOptions options)
    : body = options.data is Map
          ? jsonDecode(jsonEncode(options.data))
          : options.data,
      headers = Map<String, dynamic>.from(options.headers),
      query = Map<String, dynamic>.from(options.queryParameters);
  final Object? body;
  final Map<String, dynamic> headers, query;
  Map<String, dynamic> get choices {
    final header = headers[businessPrecisionHeader];
    return header is String
        ? Map<String, dynamic>.from(
            (jsonDecode(utf8.decode(base64Url.decode(header)))
                    as Map)['choices']
                as Map,
          )
        : {};
  }
}

class _Adapter implements HttpClientAdapter {
  final requests = <_Request>[];
  final _arrived = StreamController<int>.broadcast();
  late FutureOr<ResponseBody> Function(RequestOptions, _Request) respond;
  Future<void> count(int count) async {
    if (requests.length >= count) {
      return;
    }
    await _arrived.stream.firstWhere((n) => n >= count);
  }

  ResponseBody json(Map<String, dynamic> body, {int status = 200}) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    final request = _Request(options);
    requests.add(request);
    _arrived.add(requests.length);
    return respond(options, request);
  }

  @override
  void close({bool force = false}) {
    _arrived.close();
  }
}

({
  Dio dio,
  ApiClient api,
  _Adapter adapter,
  BusinessPrecisionCoordinator coordinator,
})
_world() {
  final dio = Dio(BaseOptions(baseUrl: 'https://precision.test/api'));
  final adapter = _Adapter();
  dio.httpClientAdapter = adapter;
  final coordinator = BusinessPrecisionCoordinator();
  return (
    dio: dio,
    api: ApiClient(dio, precisionCoordinator: coordinator),
    adapter: adapter,
    coordinator: coordinator,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'unknown mutation permits authoritative reads while keeping changed writes fenced',
    () async {
      final w = _world();
      addTearDown(() => w.dio.close(force: true));
      final transport = BusinessPrecisionTransport();
      var writes = 0;
      w.adapter.respond = (options, _) {
        if (options.method == 'GET') {
          return w.adapter.json({'status': 'UNKNOWN'});
        }
        if (++writes == 1) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          );
        }
        return w.adapter.json({'status': 'APPLIED'});
      };
      final original = {
        'requestId': 'original-key',
        'quantity': '1.000000000000000000000001',
      };
      await expectLater(
        transport.run(() => w.api.post('/original-command', body: original)),
        throwsA(isA<ApiException>()),
      );
      transport.beginRun(unknown: true);
      expect(await transport.run(() => w.api.get('/operation-status')), {
        'status': 'UNKNOWN',
      });
      await expectLater(
        transport.run(
          () => w.api.post(
            '/original-command',
            body: {...original, 'quantity': '2'},
          ),
        ),
        throwsA(isA<ApiException>()),
      );
      expect(writes, 1);
      expect(
        await transport.run(
          () => w.api.post('/original-command', body: original),
        ),
        {'status': 'APPLIED'},
      );
      expect(writes, 2);
      expect(w.adapter.requests.first.body, w.adapter.requests.last.body);
    },
  );
  test(
    'real auth owner admits sign-in while business precision still fences financial requests',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final dio = Dio(BaseOptions(baseUrl: 'https://precision.test/api'));
      final adapter = _Adapter();
      dio.httpClientAdapter = adapter;
      final auth = AuthInterceptor(
        storage: SecureStorage(const FlutterSecureStorage()),
        baseUrl: dio.options.baseUrl,
      );
      dio.interceptors.add(auth);
      final api = ApiClient(
        dio,
        precisionIdentity: AuthInterceptor.retainedIdentity,
        precisionIsCurrent: auth.requestBelongsToCurrentIdentity,
      );
      addTearDown(() => dio.close(force: true));
      adapter.respond = (_, _) => adapter.json({'accepted': true});
      expect(
        await api.post(
          '/auth/login',
          body: {
            'loginAccount': 'synthetic-only',
            'password': 'not-a-real-credential',
          },
        ),
        {'accepted': true},
      );
      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.headers,
        isNot(contains(businessPrecisionHeader)),
      );
      expect(
        await api.post(
          '/finance/receipts',
          body: {'amount': '1.000000000000000000000001'},
        ),
        {'accepted': true},
      );
      expect(adapter.requests, hasLength(2));
      // A public exchange cannot escape the original authentication endpoint fence.
      await expectLater(
        api.post(
          'https://other.test/api/auth/login',
          body: {'loginAccount': 'synthetic-only'},
        ),
        throwsA(isA<ApiException>()),
      );
      expect(adapter.requests, hasLength(2));
    },
  );
  test(
    'credential exchanges bypass business precision without retaining or replaying credentials',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://precision.test/api'));
      final adapter = _Adapter();
      dio.httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      var ownershipChecks = 0, prompts = 0;
      final coordinator = BusinessPrecisionCoordinator();
      coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(2, 'DOWN');
      });
      final api = ApiClient(
        dio,
        precisionCoordinator: coordinator,
        precisionIsCurrent: (_) async {
          ownershipChecks++;
          return false;
        },
      );
      adapter.respond = (_, _) =>
          adapter.json(_require('must-not-prompt-auth'), status: 422);
      for (final path in [
        '/auth/login',
        '/auth/refresh',
        '/auth/logout',
        '/auth/change-password',
        '/auth/step-up',
        '/visitor/auth/send-code',
        '/visitor/auth/login',
        '/visitor/auth/refresh',
        '/visitor/auth/logout',
      ]) {
        final countBefore = adapter.requests.length;
        await expectLater(
          api.post(path, body: {'syntheticCredential': 'test-only'}),
          throwsA(isA<ApiException>()),
        );
        expect(adapter.requests.length, countBefore + 1);
        expect(
          adapter.requests.last.headers,
          isNot(contains(businessPrecisionHeader)),
        );
      }
      expect(ownershipChecks, 0);
      expect(prompts, 0);
      await expectLater(
        api.post(
          '/finance/receipts',
          body: {'amount': '1.000000000000000000000001'},
        ),
        throwsA(isA<ApiException>()),
      );
      expect(ownershipChecks, 1);
      expect(adapter.requests, hasLength(9));
    },
  );
  test(
    'explicit rejected DOWN4 can ask same purpose for DOWN5 and conserve last source',
    () async {
      final w = _world();
      addTearDown(() => w.dio.close(force: true));
      var prompts = 0;
      w.coordinator.register((requirement) async {
        prompts++;
        expect(requirement.selectionRejected, prompts == 2);
        return BusinessPrecisionChoice(prompts == 1 ? 4 : 5, 'DOWN');
      });
      w.adapter.respond = (options, request) {
        final selected = request.choices['purchase.source-share'];
        if (selected == null) {
          return w.adapter.json(_require('purchase.source-share'), status: 422);
        }
        if ((selected as Map)['scale'] == 4) {
          return w.adapter.json(
            _require('purchase.source-share', selectionRejected: true),
            status: 422,
          );
        }
        return w.adapter.json({
          'allocated': '0.99999',
          'lastSource': '0.00001',
          'total': '1',
        });
      };
      final result = await w.api.post(
        '/source-allocation',
        body: {
          'requestId': 'same-original',
          'total': '1',
          'lastSourceCapacity': '0.00001',
        },
      );
      expect(prompts, 2);
      expect(result['allocated'], '0.99999');
      expect(result['lastSource'], '0.00001');
      expect(w.adapter.requests, hasLength(3));
      expect(w.adapter.requests[0].body, w.adapter.requests[2].body);
      expect(w.adapter.requests.last.choices['purchase.source-share'], {
        'scale': 5,
        'rounding': 'DOWN',
      });
    },
  );
  test(
    'selectionRejected after possible commit cannot reopen choice',
    () async {
      final w = _world();
      addTearDown(() => w.dio.close(force: true));
      var prompts = 0;
      w.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(4, 'DOWN');
      });
      w.adapter.respond = (options, request) => w.adapter.json(
        _require('ratio', selectionRejected: true, notWritten: false),
        status: 422,
      );
      await expectLater(
        w.api.post('/save', body: {'requestId': 'original'}),
        throwsA(isA<ApiException>()),
      );
      expect(prompts, 0);
      expect(w.adapter.requests, hasLength(1));
    },
  );

  test(
    'explicit no-write choice replays the exact detached body and query',
    () async {
      final w = _world();
      addTearDown(() => w.dio.close(force: true));
      final choice = Completer<BusinessPrecisionChoice?>();
      int prompts = 0;
      w.coordinator.register((required) {
        prompts++;
        expect(required.key, 'ratio');
        return choice.future;
      });
      w.adapter.respond = (options, request) => request.choices.isEmpty
          ? w.adapter.json(_require('ratio'), status: 422)
          : w.adapter.json({'saved': true});
      final body = {
            'requestId': 'original-request',
            'amount': '12345678901234567890.1234',
          },
          query = {'period': '2026-09'};
      final future = w.api.post('/save', body: body, query: query);
      await w.adapter.count(1);
      await Future<void>.delayed(Duration.zero);
      body['amount'] = 'changed';
      query['period'] = 'changed';
      choice.complete(const BusinessPrecisionChoice(3, 'DOWN'));
      expect((await future)['saved'], true);
      expect(prompts, 1);
      expect(w.adapter.requests, hasLength(2));
      expect(w.adapter.requests.first.body, w.adapter.requests.last.body);
      expect(w.adapter.requests.last.query, {'period': '2026-09'});
      expect(w.adapter.requests.last.choices['ratio'], {
        'scale': 3,
        'rounding': 'DOWN',
      });
    },
  );
  test('cancellation preserves input and never replays', () async {
    final w = _world();
    addTearDown(() => w.dio.close(force: true));
    w.coordinator.register((_) async => null);
    w.adapter.respond = (_, _) =>
        w.adapter.json(_require('ratio'), status: 422);
    await expectLater(
      w.api.post('/save', body: {'amount': '1.'}),
      throwsA(
        isA<ApiException>().having(
          (e) => e.details?['notWritten'],
          'proof',
          true,
        ),
      ),
    );
    expect(w.adapter.requests, hasLength(1));
  });
  for (final status in [422, 500]) {
    test('missing proof or gateway status $status never prompts', () async {
      final w = _world();
      addTearDown(() => w.dio.close(force: true));
      int prompts = 0;
      w.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(2, 'HALF_UP');
      });
      w.adapter.respond = (_, _) => w.adapter.json(
        _require('ratio', notWritten: status != 422),
        status: status,
      );
      await expectLater(w.api.post('/save'), throwsA(isA<ApiException>()));
      expect(prompts, 0);
      expect(w.adapter.requests, hasLength(1));
    });
  }
  test(
    'a repeated accepted key cannot create an endless prompt loop',
    () async {
      final w = _world();
      addTearDown(() => w.dio.close(force: true));
      int prompts = 0;
      w.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(4, 'HALF_UP');
      });
      w.adapter.respond = (_, _) =>
          w.adapter.json(_require('ratio'), status: 422);
      await expectLater(w.api.post('/save'), throwsA(isA<ApiException>()));
      expect(prompts, 1);
      expect(w.adapter.requests, hasLength(2));
    },
  );
  test(
    'eight-round budget retains choices and resumes the same current operation',
    () async {
      final w = _world();
      addTearDown(() => w.dio.close(force: true));
      int prompts = 0, checkpoints = 0;
      w.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(5, 'DOWN');
      });
      w.adapter.respond = (_, request) {
        for (var i = 1; i <= 9; i++) {
          if (!request.choices.containsKey('ratio$i')) {
            return w.adapter.json(_require('ratio$i'), status: 422);
          }
        }
        return w.adapter.json({'saved': true});
      };
      late BusinessPrecisionTransport transport;
      transport = BusinessPrecisionTransport(
        checkpoint: () async {
          checkpoints++;
          expect(
            jsonEncode(transport.snapshot()),
            isNot(contains('DO-NOT-STORE-SALARY-123.45')),
          );
        },
      );
      transport.beginRun(unknown: false);
      await expectLater(
        transport.run(
          () => w.api.post(
            '/save',
            body: {
              'requestId': 'original',
              'amount': 'DO-NOT-STORE-SALARY-123.45',
            },
          ),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.details?['continuation'],
            'continuation',
            true,
          ),
        ),
      );
      expect(prompts, 8);
      expect(transport.choices, hasLength(8));
      expect(transport.definitelyUnwritten, isTrue);
      expect(checkpoints, greaterThan(16));
      transport.beginRun(unknown: false);
      expect(
        (await transport.run(
          () => w.api.post(
            '/save',
            body: {
              'requestId': 'original',
              'amount': 'DO-NOT-STORE-SALARY-123.45',
            },
          ),
        ))['saved'],
        true,
      );
      expect(prompts, 9);
      expect(transport.choices, hasLength(9));
    },
  );
  test(
    'unknown outcome restores original headers and rejects changed bodies without another prompt',
    () async {
      final w = _world();
      addTearDown(() => w.dio.close(force: true));
      int prompts = 0;
      w.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(7, 'DOWN');
      });
      w.adapter.respond = (options, request) {
        if (w.adapter.requests.length == 1) {
          return w.adapter.json(_require('ratio'), status: 422);
        }
        if (w.adapter.requests.length == 2) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return w.adapter.json(_require('another-ratio'), status: 422);
      };
      final first = BusinessPrecisionTransport(checkpoint: () async {});
      first.beginRun(unknown: false);
      await expectLater(
        first.run(
          () => w.api.post('/save', body: {'requestId': 'one', 'amount': '1'}),
        ),
        throwsA(isA<NetworkTimeoutException>()),
      );
      final snapshot = jsonDecode(jsonEncode(first.snapshot()));
      final restored = BusinessPrecisionTransport(checkpoint: () async {})
        ..restore(snapshot)
        ..beginRun(unknown: true);
      await expectLater(
        restored.run(
          () => w.api.post('/save', body: {'requestId': 'one', 'amount': '1'}),
        ),
        throwsA(isA<ApiException>()),
      );
      expect(prompts, 1);
      expect(
        w.adapter.requests[1].headers[businessPrecisionHeader],
        w.adapter.requests[2].headers[businessPrecisionHeader],
      );
      expect(restored.definitelyUnwritten, isFalse);
      restored.beginRun(unknown: true);
      await expectLater(
        restored.run(
          () => w.api.post('/save', body: {'requestId': 'one', 'amount': '2'}),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'guard',
            'UNKNOWN_REQUEST_CHANGED',
          ),
        ),
      );
      expect(w.adapter.requests, hasLength(3));
    },
  );
  test(
    'interrupted no-write dialog is a known unwritten checkpoint with no selected default',
    () async {
      final transport = BusinessPrecisionTransport(checkpoint: () async {});
      transport.beginRun(unknown: false);
      await transport.dispatch(
        'hash',
        mutating: true,
        semanticFingerprint: 'same',
      );
      await transport.required(
        'hash',
        BusinessPrecisionRequirement.parse(_require('ratio')['details'])!,
      );
      final restored = BusinessPrecisionTransport()
        ..restore(jsonDecode(jsonEncode(transport.snapshot())));
      expect(restored.definitelyUnwritten, isTrue);
      expect(restored.choices, isEmpty);
      restored.beginRun(unknown: false);
      expect(restored.canAsk, isTrue);
    },
  );
  test(
    'read choice is scoped to one captured operation, never a global default',
    () async {
      final w = _world();
      addTearDown(() => w.dio.close(force: true));
      int prompts = 0;
      w.coordinator.register((_) async {
        prompts++;
        return const BusinessPrecisionChoice(2, 'HALF_UP');
      });
      w.adapter.respond = (_, request) => request.choices.isEmpty
          ? w.adapter.json(_require('ratio'), status: 422)
          : w.adapter.json({'rows': <Object?>[]});
      final scope = await w.api.captureRequestScope(isCurrent: () => true);
      await scope.run(() async {
        await w.api.get('/report', query: {'page': 1});
        await w.api.get('/report', query: {'page': 2});
      });
      expect(prompts, 1);
      await w.api.get('/report', query: {'page': 1});
      expect(prompts, 2);
    },
  );
}
