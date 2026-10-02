import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/production/models/production_daily_report_create_request.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_create_recovery_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../helpers/badge_summary_fixture.dart';

const _server = 'https://original.invalid/api';
const _owner = AuthenticatedScope(userId: 'original-user');
final _scope = StateProvider<AuthenticatedScope?>((_) => _owner);
final _backend = StateProvider<String>((_) => _server);
final _permissions = StateProvider<Set<String>>(
  (_) => {Perm.productionDailyReportView},
);
final _firstMe = Provider<Future<SessionSnapshot?>?>((_) => null);

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async {
    ref.watch(_scope);
    ref.watch(_backend);
    final first = ref.read(_firstMe);
    return first == null ? SessionSnapshot() : await first;
  }

  void emit(AsyncValue<SessionSnapshot?> next) => state = next;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: ref.watch(_scope)?.userId ?? 'none',
      code: 'reader',
      name: '当前读者',
    ),
  );
}

FrozenDailyReportCreate _command({
  String server = _server,
  String? actorId,
  String user = 'original-user',
}) {
  final vectors =
      jsonDecode(
            File(
              'test/fixtures/daily_report_create_fingerprints.json',
            ).readAsStringSync(),
          )
          as List;
  return FrozenDailyReportCreate.capture(
    body: Map<String, dynamic>.from((vectors.first as Map)['body'] as Map),
    server: server,
    userId: user,
    actorId: actorId,
  );
}

FormDraft _draft(FrozenDailyReportCreate command, {bool original = true}) =>
    FormDraft(
      id: 'local-1',
      title: 'PRIVATE staff price 999',
      module: BadgeModule.workshop,
      route: '/production/daily-reports/new',
      permission: Perm.productionDailyReportCreate,
      draftKind: 'productionDailyReport',
      updatedAt: DateTime.utc(2026, 10),
      revision: 'revision-1',
      data: {
        'remark': 'PRIVATE staff price 999',
        'idempotencyKey': command.idempotencyKey,
        'attachments': {
          'items': [
            {
              'filename': 'PRIVATE-name.pdf',
              'bytes': [1, 2, 3],
            },
          ],
        },
        'rows': [
          {'qty': '37', 'price': '999', 'contactPhone': 'PRIVATE-phone'},
        ],
        if (original) dailyReportCreateCommandKey: command.toJson(),
        dailyReportCreateStateKey: 'UNKNOWN',
        formDraftUnknownSubmissionKey: true,
      },
    );
String get _key => '${formDraftStoragePrefix(_server, _owner)}local-1';

Map<String, dynamic> _receipt(
  FrozenDailyReportCreate command, {
  String status = 'COMMITTED',
  bool deleted = false,
}) => {
  'status': status,
  'idempotencyKey': command.idempotencyKey,
  'requestHash': command.requestHash,
  if (status == 'COMMITTED') ...{
    'fullPayloadVersion': 1,
    'fullPayloadHash': command.fullPayloadHash,
  },
  if (status != 'UNKNOWN') ...{
    'reportId': 'report-1',
    'detail': {
      'id': 'report-1',
      'billNo': 'SR-ORIGINAL',
      'status': 1,
      'deleted': deleted,
      'items': <Object?>[],
    },
  },
};
Map<String, dynamic> _proof(FrozenDailyReportCreate command) {
  final receipt = DailyReportCreateResolution.fromJson(_receipt(command))
    ..verify(command);
  return receipt.toCheckpoint();
}

class _Storage extends MemoryFormDraftStorage {
  bool failCas = false;
  int casAttempts = 0;
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    casAttempts++;
    if (failCas) return false;
    return super.compareAndSet(key, expectedValue: expectedValue, value: value);
  }
}

ProviderContainer _container(_Storage storage, {Set<String>? permissions}) =>
    ProviderContainer(
      overrides: [
        formDraftStorageProvider.overrideWithValue(storage),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_backend)),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        if (permissions != null) _permissions.overrideWith((_) => permissions),
      ],
    );

class _Api extends ApiClient {
  _Api(this.response) : super(Dio());
  Map<String, dynamic> response;
  Completer<Map<String, dynamic>>? gate;
  Object? error;
  final requests = <({String path, Object? body})>[];
  int businessWrites = 0;
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    requests.add((path: path, body: body));
    if (path != '/production/daily-reports/create-receipt') {
      businessWrites++;
      throw StateError('readonly recovery attempted $path');
    }
    if (error != null) throw error!;
    return gate?.future ?? response;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Storage storage,
  _Api api, {
  Future<SessionSnapshot?>? firstMe,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: '/production/daily-reports/create-recovery',
    routes: [
      GoRoute(
        path: '/production/daily-reports/create-recovery',
        builder: (_, _) =>
            const ProductionDailyReportCreateRecoveryPage(draftId: 'local-1'),
      ),
      GoRoute(
        path: '/production/daily-reports',
        builder: (_, _) => const Scaffold(body: Text('report list')),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      formDraftStorageProvider.overrideWithValue(storage),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_backend)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshots.new),
      _firstMe.overrideWithValue(firstMe),
      apiClientProvider.overrideWithValue(api),
      productionDailyReportRepositoryProvider.overrideWithValue(
        ProductionDailyReportRepository(api),
      ),
      sharedPreferencesProvider.overrideWithValue(prefs),
      fixedBadgeSummaryOverride(),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    router.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  test(
    'malformed protocol fields cannot bypass public sensitive projection',
    () async {
      final command = _command(), storage = _Storage();
      final record = _draft(command).toJson();
      final data = Map<String, dynamic>.from(record['data'] as Map)
        ..[dailyReportCreateCommandKey] = 'PRIVATE encoded body'
        ..[dailyReportCreateReceiptKey] = {
          'requestHash': {'secret': 'PRIVATE'},
        };
      storage.records[_key] = jsonEncode({...record, 'data': data});
      final container = _container(
        storage,
        permissions: {
          Perm.productionDailyReportView,
          Perm.productionDailyReportCreate,
        },
      );
      addTearDown(container.dispose);
      final store = container.read(formDraftsProvider.notifier);
      await store.ready;
      final public = container.read(formDraftsProvider).single.data;
      expect(public.containsKey(dailyReportCreateCommandKey), isFalse);
      expect(public[dailyReportCreateReceiptKey], isEmpty);
      expect(storage.casAttempts, 0);
    },
  );

  for (final writable in [false, true]) {
    test(
      'public draft never leaks original JSON; writable=$writable',
      () async {
        final command = _command(), storage = _Storage();
        storage.records[_key] = jsonEncode(_draft(command).toJson());
        final container = _container(
          storage,
          permissions: {
            Perm.productionDailyReportView,
            if (writable) Perm.productionDailyReportCreate,
          },
        );
        addTearDown(container.dispose);
        final store = container.read(formDraftsProvider.notifier);
        await store.ready;
        final visible = container.read(formDraftsProvider).single;
        expect(
          (visible.data[dailyReportCreateCommandKey] as Map).containsKey(
            'bodyJson',
          ),
          isFalse,
        );
        if (!writable) {
          expect(jsonEncode(visible.toJson()), isNot(contains('PRIVATE')));
        }
        final original = await store.readDailyReportCreateRecovery('local-1');
        expect(original!.data, _draft(command).data);
      },
    );
  }
  test(
    'view-only confirmation preserves exact request, raw input and files and cannot edit',
    () async {
      final command = _command(), storage = _Storage();
      storage.records[_key] = jsonEncode(_draft(command).toJson());
      final container = _container(storage);
      addTearDown(container.dispose);
      final store = container.read(formDraftsProvider.notifier);
      await store.ready;
      await expectLater(
        store.save(_draft(command), expectedRevision: 'revision-1'),
        throwsStateError,
      );
      final confirmed = await store.confirmDailyReportCreateRecovery(
        'local-1',
        expectedRevision: 'revision-1',
        receipt: _proof(command),
      );
      expect(confirmed.data[dailyReportCreateCommandKey], command.toJson());
      expect(confirmed.data['rows'], _draft(command).data['rows']);
      expect(
        confirmed.data['attachments'],
        _draft(command).data['attachments'],
      );
      expect(confirmed.data['createdReportId'], 'report-1');
      expect(confirmed.hasUnknownSubmission, isFalse);
      expect(confirmed.revision, isNot('revision-1'));
      expect(storage.casAttempts, 1);
      expect(
        jsonEncode(container.read(formDraftsProvider).single.toJson()),
        isNot(contains('PRIVATE')),
      );
    },
  );
  for (final lifecycle in [
    'COMPLETED',
    'DISCARDED',
    'SUBMITTED',
    'DELETED',
    'ARCHIVED',
  ]) {
    test('$lifecycle cannot be read or revived by a receipt', () async {
      final command = _command(), storage = _Storage();
      final record = {
        ..._draft(command).toJson(),
        if (lifecycle == 'COMPLETED')
          'completed': true
        else
          'lifecycle': lifecycle,
      };
      final original = storage.records[_key] = jsonEncode(record);
      final container = _container(storage);
      addTearDown(container.dispose);
      final store = container.read(formDraftsProvider.notifier);
      await store.ready;
      expect(container.read(formDraftsProvider), isEmpty);
      expect(await store.readDailyReportCreateRecovery('local-1'), isNull);
      await expectLater(
        store.confirmDailyReportCreateRecovery(
          'local-1',
          expectedRevision: 'revision-1',
          receipt: _proof(command),
        ),
        throwsA(isA<FormDraftConflict>()),
      );
      expect(storage.records[_key], original);
      expect(storage.casAttempts, 0);
    });
  }
  for (final mismatch in [
    'idempotencyKey',
    'requestHash',
    'fullPayloadHash',
    'fullPayloadVersion',
    'status',
  ]) {
    test('stored confirmation rejects $mismatch mismatch', () async {
      final command = _command(), storage = _Storage();
      final original = storage.records[_key] = jsonEncode(
        _draft(command).toJson(),
      );
      final container = _container(storage);
      addTearDown(container.dispose);
      final store = container.read(formDraftsProvider.notifier);
      await store.ready;
      final proof = _proof(command)
        ..[mismatch] = mismatch == 'fullPayloadVersion' ? 2 : 'other';
      await expectLater(
        store.confirmDailyReportCreateRecovery(
          'local-1',
          expectedRevision: 'revision-1',
          receipt: proof,
        ),
        throwsStateError,
      );
      expect(storage.records[_key], original);
      expect(storage.casAttempts, 0);
    });
  }
  for (final failure in ['revision', 'cas', 'server', 'actor', 'user']) {
    test('$failure conflict leaves original storage untouched', () async {
      final command = _command(
        server: failure == 'server' ? 'https://other.invalid/api' : _server,
        actorId: failure == 'actor' ? 'other-actor' : null,
        user: failure == 'user' ? 'other-user' : 'original-user',
      );
      final storage = _Storage()..failCas = failure == 'cas';
      final original = storage.records[_key] = jsonEncode(
        _draft(command).toJson(),
      );
      final container = _container(storage);
      addTearDown(container.dispose);
      final store = container.read(formDraftsProvider.notifier);
      await store.ready;
      await expectLater(
        store.confirmDailyReportCreateRecovery(
          'local-1',
          expectedRevision: failure == 'revision' ? 'stale' : 'revision-1',
          receipt: _proof(command),
        ),
        throwsA(anything),
      );
      expect(storage.records, {_key: original});
    });
  }
  for (final status in ['UNKNOWN', 'LEGACY_UNCONFIRMED', 'COMMITTED']) {
    testWidgets(
      'view-only native page resolves $status with only original readonly request',
      (tester) async {
        final command = _command(), storage = _Storage();
        final original = storage.records[_key] = jsonEncode(
          _draft(command).toJson(),
        );
        final api = _Api(_receipt(command, status: status));
        await _pump(tester, storage, api);
        await tester.pumpAndSettle();
        expect(api.requests, hasLength(1));
        expect(api.requests.single.body, command.requestBody);
        expect(api.businessWrites, 0);
        expect(find.textContaining('PRIVATE'), findsNothing);
        expect(find.text('继续处理待上传附件'), findsNothing);
        final saved = jsonDecode(storage.records[_key]!) as Map;
        if (status == 'COMMITTED') {
          expect(find.text('已确认原提交创建了生产日报'), findsOneWidget);
          expect((saved['data'] as Map)['createdReportId'], 'report-1');
        } else {
          expect(storage.records[_key], original);
          expect(
            find.text(status == 'UNKNOWN' ? '创建结果仍未确认' : '旧版记录缺少完整字段证明，仍待核对'),
            findsOneWidget,
          );
        }
        await tester.tap(find.text('再次核对原提交'));
        await tester.pumpAndSettle();
        expect(api.requests, hasLength(2));
        expect(api.businessWrites, 0);
        expect(storage.casAttempts, status == 'COMMITTED' ? 1 : 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'deleted committed receipt is explicit and cannot continue attachments',
    (tester) async {
      final command = _command(), storage = _Storage();
      storage.records[_key] = jsonEncode(_draft(command).toJson());
      await _pump(tester, storage, _Api(_receipt(command, deleted: true)));
      await tester.pumpAndSettle();
      expect(find.text('已删除（原提交记录永久保留）'), findsOneWidget);
      expect(find.text('继续处理待上传附件'), findsNothing);
    },
  );
  testWidgets('first Me pending prevents even receipt reads', (tester) async {
    final command = _command(), storage = _Storage();
    storage.records[_key] = jsonEncode(_draft(command).toJson());
    final firstMe = Completer<SessionSnapshot?>(),
        api = _Api(_receipt(command));
    await _pump(tester, storage, api, firstMe: firstMe.future);
    expect(api.requests, isEmpty);
    expect(storage.casAttempts, 0);
    firstMe.complete(SessionSnapshot());
    await tester.pumpAndSettle();
    expect(api.requests, hasLength(1));
    expect(storage.casAttempts, 1);
  });
  for (final failure in ['missing-original', '403', 'wrong-hash', 'wrong-id']) {
    testWidgets(
      '$failure retains original and never adopts a guessed checkpoint',
      (tester) async {
        final command = _command(), storage = _Storage();
        final original = storage.records[_key] = jsonEncode(
          _draft(command, original: failure != 'missing-original').toJson(),
        );
        final response = _receipt(command);
        if (failure == 'wrong-hash') response['fullPayloadHash'] = 'wrong';
        if (failure == 'wrong-id') response['reportId'] = 'other';
        final api = _Api(response);
        if (failure == '403') {
          api.error = ApiException(
            'FORBIDDEN',
            'scope denied',
            httpStatus: 403,
          );
        }
        await _pump(tester, storage, api);
        await tester.pumpAndSettle();
        expect(storage.records[_key], original);
        expect(storage.casAttempts, 0);
        expect(api.businessWrites, 0);
        expect(find.text('已确认原提交创建了生产日报'), findsNothing);
        expect(api.requests.length, failure == 'missing-original' ? 0 : 1);
      },
    );
  }
  for (final transition in ['user', 'actor', 'server', 'view-revoked']) {
    testWidgets('$transition ignores a late committed receipt', (tester) async {
      final command = _command(), storage = _Storage();
      final original = storage.records[_key] = jsonEncode(
        _draft(command).toJson(),
      );
      final pending = Completer<Map<String, dynamic>>(),
          api = _Api(_receipt(command))..gate = pending;
      final container = await _pump(tester, storage, api);
      await tester.pump();
      expect(api.requests, hasLength(1));
      switch (transition) {
        case 'user':
          container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'other',
          );
        case 'actor':
          container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'original-user',
            actorId: 'other-actor',
          );
        case 'server':
          container.read(_backend.notifier).state = 'https://other.invalid/api';
        case 'view-revoked':
          container.read(_permissions.notifier).state = {};
          (container.read(sessionSnapshotProvider.notifier) as _Snapshots).emit(
            AsyncData(SessionSnapshot()),
          );
      }
      await tester.pump();
      pending.complete(_receipt(command));
      await tester.pumpAndSettle();
      expect(storage.records[_key], original);
      expect(storage.casAttempts, 0);
      expect(api.businessWrites, 0);
      expect(find.text('已确认原提交创建了生产日报'), findsNothing);
    });
  }
  for (final transition in ['user-aba', 'server-aba']) {
    testWidgets(
      '$transition discards old receipt and requires the new owned read',
      (tester) async {
        final command = _command(), storage = _Storage();
        final original = storage.records[_key] = jsonEncode(
          _draft(command).toJson(),
        );
        final stale = Completer<Map<String, dynamic>>(),
            fresh = Completer<Map<String, dynamic>>();
        final api = _Api(_receipt(command))..gate = stale;
        final container = await _pump(tester, storage, api);
        await tester.pump();
        expect(api.requests, hasLength(1));
        if (transition == 'user-aba') {
          container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'other',
          );
        } else {
          container.read(_backend.notifier).state = 'https://other.invalid/api';
        }
        await tester.pump();
        await tester.pump();
        api.gate = fresh;
        if (transition == 'user-aba') {
          container.read(_scope.notifier).state = _owner;
        } else {
          container.read(_backend.notifier).state = _server;
        }
        for (var i = 0; i < 4; i++) {
          await tester.pump();
        }
        expect(api.requests, hasLength(2));
        stale.complete(_receipt(command));
        await tester.pump();
        await tester.pump();
        expect(storage.records[_key], original);
        expect(storage.casAttempts, 0);
        fresh.complete(_receipt(command));
        await tester.pumpAndSettle();
        expect(storage.casAttempts, 1);
        expect(api.businessWrites, 0);
        expect(find.text('已确认原提交创建了生产日报'), findsOneWidget);
      },
    );
  }
  testWidgets(
    'a concurrent local revision cannot be overwritten by a late receipt',
    (tester) async {
      final command = _command(), storage = _Storage();
      storage.records[_key] = jsonEncode(_draft(command).toJson());
      final pending = Completer<Map<String, dynamic>>(),
          api = _Api(_receipt(command))..gate = pending;
      await _pump(tester, storage, api);
      await tester.pump();
      expect(api.requests, hasLength(1));
      final updated = storage.records[_key] = jsonEncode({
        ..._draft(command).toJson(),
        'revision': 'newer-local-revision',
      });
      pending.complete(_receipt(command));
      await tester.pumpAndSettle();
      expect(storage.records[_key], updated);
      expect(storage.casAttempts, 0);
      expect(find.text('已确认原提交创建了生产日报'), findsNothing);
      expect(api.businessWrites, 0);
    },
  );
}
