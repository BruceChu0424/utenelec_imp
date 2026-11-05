import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/core/network/business_precision_coordinator.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/finance/repositories/finance_repository.dart';
import 'package:uten_imp/features/finance/widgets/finance_document_review_command.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/finance_command_test_support.dart';
import '../../support/finance_document_command_fixture.dart';
import '../../support/native_detail_reader_overrides.dart';

const _document = '00000000-0000-0000-0000-000000000801';
final _token = List.filled(64, 'a').join();
final _granted = StateProvider<Set<String>>((_) => {});

Map<String, dynamic> _source(
  FinanceDocType type, {
  bool gl = false,
  bool deleted = false,
}) => financeReviewedDetailFixture({
  'id': _document,
  'billNo': '原财务对照单',
  'makerId': financeCommandTestActor,
  'status': gl ? 1 : 0,
  'glStatus': gl ? 1 : 0,
  'deleted': deleted,
  'version': type == FinanceDocType.receipt || type == FinanceDocType.payment
      ? 7
      : null,
  'amountLocalExact': '2.000000000000000000000001',
  'items': <Object>[],
}, type);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: financeCommandTestActor, code: 'fixture', name: '匿名测试人员'),
  );
}

class _Request {
  _Request(
    this.method,
    this.path,
    this.body,
    this.choices,
    this.query,
    this.contentType,
  );
  final String method, path;
  final Map<String, dynamic> body, choices, query;
  final String? contentType;
}

class _Transport implements HttpClientAdapter {
  final requests = <_Request>[],
      writes = <_Request>[],
      receiptReads = <String>[],
      historyReads = <String>[];
  final receipts = <String, Map<String, dynamic>>{};
  bool loseReply = true,
      requirePrecision = false,
      wrongSuccess = false,
      forbidReceipts = false;
  int? detailError;
  int committed = 0;
  FinanceDocType type = FinanceDocType.expense;
  bool gl = false;
  String get base => '/finance/${type.pathSegment}/$_document';
  Map<String, dynamic> _choices(RequestOptions o) {
    final value = o.headers[businessPrecisionHeader];
    return value is String
        ? Map<String, dynamic>.from(
            (jsonDecode(utf8.decode(base64Url.decode(value))) as Map)['choices']
                as Map,
          )
        : {};
  }

  ResponseBody _json(Object? value, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(value),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
  Map<String, dynamic> _receipt(_Request request) => {
    'found': true,
    'outcome': 'SUCCEEDED',
    'actorId': financeCommandTestActor,
    'requestId': request.body['requestId'],
    'operation': request.method == 'DELETE'
        ? 'FINANCE_DOCUMENT_DELETE'
        : 'FINANCE_DOCUMENT_GL_CONFIRM',
    'method': request.method,
    'path': request.path,
    'requestBody': request.body,
    'precisionChoices': request.choices,
    'precisionContext': {
      'available': true,
      'choices': request.choices,
      'usedChoices': request.choices,
    },
    'result': request.method == 'DELETE'
        ? {
            'id': _document,
            'status': 0,
            'deleted': !wrongSuccess,
            'items': <Object>[],
          }
        : {
            'id': _document,
            'status': 1,
            'glStatus': wrongSuccess ? 1 : 2,
            'items': <Object>[],
          },
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    final bytes = stream == null
        ? <int>[]
        : await stream.expand((chunk) => chunk).toList();
    final data = bytes.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    final request = _Request(
      o.method,
      o.path,
      data,
      _choices(o),
      Map<String, dynamic>.from(o.queryParameters),
      o.contentType,
    );
    requests.add(request);
    if (o.method == 'GET') {
      if (o.path.contains('/review-operations/')) {
        receiptReads.add(o.path);
        if (forbidReceipts) {
          return _json({'code': 'FORBIDDEN', 'message': '没有读取权限'}, 403);
        }
        return _json(receipts[o.path.split('/').last] ?? {'found': false});
      }
      if (o.path == '$base/history') {
        historyReads.add(o.path);
        return _json(_source(type, gl: gl, deleted: true));
      }
      if (o.path == base) {
        if (detailError != null) {
          return _json({
            'code': detailError == 404 ? 'NOT_FOUND' : 'FORBIDDEN',
            'message': '当前单据不可读取',
          }, detailError!);
        }
        return _json(_source(type, gl: gl));
      }
      return _json({
        'items': <Object>[],
        'total': 0,
        'page': 1,
        'size': 100,
        'totalPages': 0,
      });
    }
    if (o.path.endsWith('/cancel')) {
      throw StateError('This fixture never auto-cancels an unknown write');
    }
    writes.add(request);
    if (requirePrecision && request.choices.isEmpty) {
      return _json({
        'code': 'PRECISION_CHOICE_REQUIRED',
        'message': '选择原计算精度',
        'details': {
          'calculationKey': 'finance.allocation',
          'groupKey': 'finance.allocation',
          'label': '分摊计算',
          'maxScale': 30,
          'suggestedScale': 4,
          'reason': 'NON_TERMINATING',
          'notWritten': true,
        },
      }, 422);
    }
    final id = data['requestId'] as String;
    final result = receipts.putIfAbsent(id, () {
      committed++;
      return _receipt(request);
    });
    if (loseReply) {
      throw DioException(
        requestOptions: o,
        type: DioExceptionType.receiveTimeout,
      );
    }
    return _json(result);
  }

  @override
  void close({bool force = false}) {}
}

class _Environment {
  _Environment(this.container, this.dio, this.router);
  final ProviderContainer container;
  final Dio dio;
  final GoRouter? router;
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    router?.dispose();
    container.dispose();
    dio.close(force: true);
  }
}

Future<_Environment> _open(
  WidgetTester tester,
  _Transport transport,
  MemoryFormDraftStorage storage, {
  bool gl = false,
  bool write = true,
  bool read = true,
  String? resume,
  String? detailResume,
  bool standaloneDetail = false,
  bool imperativeUnderRecoveryHost = false,
  FinanceDocDetail? reviewSnapshot,
  Future<void> Function()? beforeDispatch,
}) async {
  transport.gl = gl;
  final dio = Dio(BaseOptions(baseUrl: 'https://finance-command.test/api'))
    ..httpClientAdapter = transport;
  final permissions = {
    if (read) FinanceDocConfig.by(transport.type).listPerm,
    if (write)
      (gl
          ? Perm.financeExpenseGlConfirm
          : FinanceDocConfig.by(transport.type).deletePerm!),
  };
  final container = ProviderContainer(
    overrides: [
      ...nativeDetailReaderOverrides(
        includeSession: false,
        includeServer: false,
      ),
      apiBaseUrlProvider.overrideWithValue('https://finance-command.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: financeCommandTestActor),
      ),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_granted)),
      _granted.overrideWith((_) => permissions),
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      formDraftStorageProvider.overrideWithValue(storage),
      apiClientProvider.overrideWithValue(ApiClient(dio)),
    ],
  );
  GoRouter? router;
  Widget child;
  if (detailResume != null) {
    router = GoRouter(
      initialLocation: detailResume,
      routes: [
        GoRoute(
          path: '/finance/:segment/:id',
          builder: (_, s) => FinanceDocDetailPage(
            docType: transport.type,
            id: s.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/:rest(.*)',
          builder: (_, _) => const Scaffold(body: Text('完成返回')),
        ),
      ],
    );
    child = MaterialApp.router(
      routerConfig: router,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );
  } else if (standaloneDetail) {
    child = MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FinanceDocDetailPage(
        docType: transport.type,
        id: _document,
        reviewSnapshot: reviewSnapshot,
      ),
    );
  } else if (imperativeUnderRecoveryHost) {
    router = GoRouter(
      initialLocation:
          '/host?draftForm=financeDocumentReview&reviewOperation=delete&draftId=unrelated-host-draft',
      routes: [
        GoRoute(
          path: '/host',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => FinanceDocDetailPage(
                    docType: transport.type,
                    id: _document,
                    reviewSnapshot: reviewSnapshot,
                  ),
                ),
              ),
              child: const Text('打开普通原单'),
            ),
          ),
        ),
      ],
    );
    child = MaterialApp.router(
      routerConfig: router,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );
  } else {
    child = MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showFinanceDocumentReviewCommand(
              context,
              type: transport.type,
              documentId: _document,
              unapprove: false,
              glConfirm: gl,
              deleteDraft: !gl,
              reviewedDetail: FinanceDocDetail.fromJson(
                _source(transport.type, gl: gl),
              ),
              resumeDraftId: resume,
              confirmationMessage: '核对所查看版本后确认操作。',
              beforeDispatch: beforeDispatch,
            ),
            child: const Text('打开原操作'),
          ),
        ),
      ),
    );
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: child),
  );
  await tester.pumpAndSettle();
  if (imperativeUnderRecoveryHost) {
    await tester.tap(find.text('打开普通原单'));
    await tester.pumpAndSettle();
  } else if (detailResume == null && !standaloneDetail) {
    await tester.tap(find.text('打开原操作'));
    await tester.pumpAndSettle();
  }
  return _Environment(container, dio, router);
}

Future<void> _receipt(WidgetTester tester, String label) async {
  await tapFinanceOriginalAction(
    tester,
    '核对原$label'
    '结果',
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(prepareFinanceCommandTest);
  testWidgets('DELETE dialog cancellation does not invoke beforeDispatch', (
    tester,
  ) async {
    final transport = _Transport()..type = FinanceDocType.expense;
    var calls = 0;
    final env = await _open(
      tester,
      transport,
      MemoryFormDraftStorage(),
      beforeDispatch: () async => calls++,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(transport.writes, isEmpty);
    await env.close(tester);
  });
  testWidgets('DELETE dispatch hook runs once after persisting the original', (
    tester,
  ) async {
    final transport = _Transport()..type = FinanceDocType.expense;
    final hold = Completer<void>();
    var calls = 0;
    late _Environment env;
    env = await _open(
      tester,
      transport,
      MemoryFormDraftStorage(),
      beforeDispatch: () {
        calls++;
        expect(env.container.read(formDraftsProvider), hasLength(1));
        return hold.future;
      },
    );
    final confirmPoint = tester.getCenter(find.text('确认删除'));
    await tester.tapAt(confirmPoint);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(calls, 1);
    expect(transport.writes, isEmpty);
    expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
    expect(find.text('正在删除'), findsOneWidget);
    await tester.tapAt(confirmPoint);
    await tester.pump(const Duration(milliseconds: 350));
    expect(calls, 1);
    hold.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(transport.writes, hasLength(1));
    expect(transport.committed, 1);
    await env.close(tester);
  });
  testWidgets('DELETE failing dispatch hook does not send or seal a write', (
    tester,
  ) async {
    final transport = _Transport()..type = FinanceDocType.expense;
    var calls = 0;
    final env = await _open(
      tester,
      transport,
      MemoryFormDraftStorage(),
      beforeDispatch: () async {
        calls++;
        throw StateError('本机草稿版本已变化');
      },
    );
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(transport.writes, isEmpty);
    expect(
      env.container.read(formDraftsProvider).any((d) => d.hasUnknownSubmission),
      isFalse,
    );
    expect(find.text('确认删除'), findsOneWidget);
    await env.close(tester);
  });
  for (final type in FinanceDocType.values) {
    testWidgets(
      '$type normal detail without GoRouter keeps its original read contract',
      (tester) async {
        final transport = _Transport()..type = type;
        final env = await _open(
          tester,
          transport,
          MemoryFormDraftStorage(),
          write: false,
          standaloneDetail: true,
        );
        expect(
          transport.requests.where(
            (r) => r.method == 'GET' && r.path == transport.base,
          ),
          hasLength(1),
        );
        expect(transport.historyReads, isEmpty);
        expect(transport.receiptReads, isEmpty);
        expect(find.textContaining('原财务对照单'), findsWidgets);
        expect(transport.writes, isEmpty);
        expect(tester.takeException(), isNull);
        await env.close(tester);
      },
    );
    testWidgets(
      '$type DELETE uses immutable JSON body then later and history404 restore reads its one original receipt',
      (tester) async {
        final transport = _Transport()..type = type,
            storage = MemoryFormDraftStorage();
        var env = await _open(tester, transport, storage);
        await tester.tap(find.text('确认删除'));
        await tester.pumpAndSettle();
        expect(transport.writes, hasLength(1));
        expect(transport.committed, 1);
        final original = transport.writes.single;
        expect(original.method, 'DELETE');
        expect(original.path, transport.base);
        expect(original.query, isEmpty);
        expect(original.contentType, contains('application/json'));
        expect(original.body.keys.toSet(), {
          'requestId',
          'expectedVersion',
          'expectedSnapshot',
        });
        expect(original.body['expectedSnapshot'], _token);
        expect(
          original.body['expectedVersion'],
          type == FinanceDocType.receipt || type == FinanceDocType.payment
              ? 7
              : null,
        );
        final draft = env.container.read(formDraftsProvider).single;
        expect(draft.hasUnknownSubmission, isTrue);
        await tester.tap(find.text('稍后核对'));
        await tester.pumpAndSettle();
        expect(env.container.read(formDraftsProvider).single.id, draft.id);
        await env.close(tester);
        transport.detailError = 404;
        env = await _open(
          tester,
          transport,
          storage,
          write: false,
          detailResume: draft.resumeLocation,
        );
        expect(transport.historyReads, isNotEmpty);
        await _receipt(tester, '删除');
        expect(transport.receiptReads, hasLength(1));
        expect(transport.writes, hasLength(1));
        expect(transport.committed, 1);
        expect(env.container.read(formDraftsProvider), isEmpty);
        await env.close(tester);
      },
    );
    test('$type historical recovery never falls back on a403', () async {
      final transport = _Transport()
        ..type = type
        ..detailError = 403;
      final dio = Dio(BaseOptions(baseUrl: 'https://finance-command.test/api'))
        ..httpClientAdapter = transport;
      await expectLater(
        FinanceRepository(ApiClient(dio), type).detailForRecovery(_document),
        throwsA(
          isA<ApiException>().having((e) => e.httpStatus, 'httpStatus', 403),
        ),
      );
      expect(transport.historyReads, isEmpty);
      expect(transport.requests, hasLength(1));
      dio.close(force: true);
    });
  }
  for (final missing in [false, true]) {
    testWidgets(
      'imperative normal detail does not inherit host recovery query missing=$missing',
      (tester) async {
        final transport = _Transport()
          ..type = FinanceDocType.expense
          ..detailError = missing ? 404 : null;
        final env = await _open(
          tester,
          transport,
          MemoryFormDraftStorage(),
          write: false,
          imperativeUnderRecoveryHost: true,
        );
        expect(
          transport.requests.where(
            (r) => r.method == 'GET' && r.path == transport.base,
          ),
          hasLength(1),
        );
        expect(transport.historyReads, isEmpty);
        expect(transport.receiptReads, isEmpty);
        expect(transport.writes, isEmpty);
        if (!missing) expect(find.textContaining('原财务对照单'), findsWidgets);
        expect(tester.takeException(), isNull);
        await env.close(tester);
      },
    );
  }
  testWidgets(
    'an explicit reviewed snapshot remains frozen without router or live-detail replacement',
    (tester) async {
      final transport = _Transport()
        ..type = FinanceDocType.expense
        ..detailError = 404;
      final env = await _open(
        tester,
        transport,
        MemoryFormDraftStorage(),
        write: false,
        standaloneDetail: true,
        reviewSnapshot: FinanceDocDetail.fromJson(
          _source(FinanceDocType.expense),
        ),
      );
      expect(
        transport.requests.where((r) => r.path == transport.base),
        isEmpty,
      );
      expect(transport.historyReads, isEmpty);
      expect(transport.receiptReads, isEmpty);
      expect(find.textContaining('原财务对照单'), findsWidgets);
      expect(transport.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );
  testWidgets(
    'GL_CONFIRM original4DOWN survives later restore and lost write permission without a re-dispatch',
    (tester) async {
      var asks = 0;
      var release = BusinessPrecisionCoordinator.instance.register((_) async {
        asks++;
        return const BusinessPrecisionChoice(4, 'DOWN');
      });
      final transport = _Transport()
            ..type = FinanceDocType.expense
            ..requirePrecision = true,
          storage = MemoryFormDraftStorage();
      var env = await _open(tester, transport, storage, gl: true);
      await tester.tap(find.text('确认财务确认'));
      await tester.pumpAndSettle();
      expect(asks, 1);
      expect(transport.writes, hasLength(2));
      expect(transport.committed, 1);
      final original = transport.writes.last;
      expect(original.method, 'POST');
      expect(original.path, '${transport.base}/gl-confirm');
      expect(original.body['expectedVersion'], isNull);
      expect(original.body['expectedSnapshot'], _token);
      expect(original.choices['finance.allocation'], {
        'scale': 4,
        'rounding': 'DOWN',
      });
      final draft = env.container.read(formDraftsProvider).single;
      await tester.tap(find.text('稍后核对'));
      await tester.pumpAndSettle();
      await env.close(tester);
      release();
      release = BusinessPrecisionCoordinator.instance.register((_) async {
        asks++;
        return const BusinessPrecisionChoice(4, 'HALF_UP');
      });
      env = await _open(
        tester,
        transport,
        storage,
        gl: true,
        write: false,
        resume: draft.id,
      );
      await _receipt(tester, '财务确认');
      expect(asks, 1);
      expect(transport.receiptReads, hasLength(1));
      expect(transport.writes, hasLength(2));
      expect(transport.committed, 1);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await env.close(tester);
      release();
    },
  );
  for (final gl in [false, true]) {
    testWidgets(
      '${gl ? 'GL_CONFIRM' : 'DELETE'} rejects a wrong success and preserves its sealed original',
      (tester) async {
        final transport = _Transport()
              ..type = FinanceDocType.expense
              ..wrongSuccess = true
              ..loseReply = false,
            storage = MemoryFormDraftStorage();
        final env = await _open(tester, transport, storage, gl: gl);
        await tester.tap(find.text(gl ? '确认财务确认' : '确认删除'));
        await tester.pumpAndSettle();
        expect(transport.committed, 1);
        expect(
          env.container.read(formDraftsProvider).single.hasUnknownSubmission,
          isTrue,
        );
        await _receipt(tester, gl ? '财务确认' : '删除');
        expect(
          env.container.read(formDraftsProvider).single.hasUnknownSubmission,
          isTrue,
        );
        expect(transport.writes, hasLength(1));
        await env.close(tester);
      },
    );
    testWidgets(
      '${gl ? 'GL_CONFIRM' : 'DELETE'} receipt403 cannot retire the original and read loss hides recovery actions',
      (tester) async {
        final transport = _Transport()..type = FinanceDocType.expense,
            storage = MemoryFormDraftStorage();
        final env = await _open(tester, transport, storage, gl: gl);
        await tester.tap(find.text(gl ? '确认财务确认' : '确认删除'));
        await tester.pumpAndSettle();
        transport.forbidReceipts = true;
        await _receipt(tester, gl ? '财务确认' : '删除');
        expect(
          env.container.read(formDraftsProvider).single.hasUnknownSubmission,
          isTrue,
        );
        final persisted = await storage.readAll('');
        env.container.read(_granted.notifier).state = {};
        await tester.pumpAndSettle();
        expect(find.text('核对原${gl ? '财务确认' : '删除'}结果'), findsNothing);
        expect(transport.receiptReads, hasLength(1));
        expect(transport.writes, hasLength(1));
        expect(await storage.readAll(''), persisted);
        await env.close(tester);
      },
    );
  }
}
