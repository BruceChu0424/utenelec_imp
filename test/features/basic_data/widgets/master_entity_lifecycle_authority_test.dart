import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

typedef _Row = ({String id, String name, int version});
const _rows = [
  (id: 'one', name: '私有货品一', version: 7),
  (id: 'two', name: '私有货品二', version: 11),
];
final _identity = StateProvider<String>((_) => 'A');
final _allowed = StateProvider<bool>((_) => true);
final _category = StateProvider<String>((_) => 'cat-a');

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Fixture {
  _Fixture([this.entity = 'goods']);
  final String entity;
  late MasterEntityPaneController<_Row, _Row> pane;
  final writes = <({String path, Map<String, dynamic> body})>[];
  final gate = Completer<void>();
  bool pending = false;
  bool fail = false;
  bool partial = false;
  late final api = () {
    final dio = Dio(BaseOptions(baseUrl: 'https://pane.invalid/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          final body = Map<String, dynamic>.from(request.data as Map);
          writes.add((path: request.path, body: body));
          if (pending) await gate.future;
          if (fail) {
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: request,
                  statusCode: 409,
                  data: {'code': 'CONFLICT', 'message': 'PRIVATE-OLD-ERROR'},
                ),
              ),
            );
            return;
          }
          final items = body['items'] as List<dynamic>? ?? const [];
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: {
                'succeeded': partial ? 0 : items.length,
                'failed': partial ? items.length : 0,
                'results': [
                  for (final item in items)
                    {
                      'id': (item as Map)['id'],
                      'ok': !partial,
                      if (partial) 'label': 'PRIVATE-OLD-LABEL',
                      if (partial) 'reason': 'PRIVATE-OLD-REASON',
                    },
                ],
              },
            ),
          );
        },
      ),
    );
    return ApiClient(dio);
  }();
}

class _Host extends ConsumerWidget {
  const _Host(this.fixture);
  final _Fixture fixture;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = ref.watch(_allowed);
    return MasterEntityDetailPane<_Row, _Row>(
      categoryId: ref.watch(_category),
      externalKeyword: null,
      config: MasterEntityPaneConfig(
        noun: '资料',
        icon: Icons.inventory_2_outlined,
        defaultCodePrefix: 'QA',
        columns: [
          MasterColumnDef(
            key: 'name',
            label: '名称',
            width: 250,
            value: (row) => row.name,
          ),
        ],
        idOf: (row) => row.id,
        statusOf: (_) => '使用',
        labelOf: (row) => row.name,
        versionOf: (row) => row.version,
        loadCategory: (id) async => ProductCategoryDetail(
          id: id,
          code: 'QA',
          name: '测试分类',
          level: 0,
          path: '测试分类',
          childCount: 0,
        ),
        loadPage: (_) async => const PagedResult<_Row>(
          items: _rows,
          page: 1,
          size: 20,
          total: 2,
          totalPages: 1,
        ),
        loadFacets: (_) async =>
            const MasterPaneFacets(fields: {}, nullCounts: {}),
        batchEntityPath: '/master/${fixture.entity}',
        statusResourceOf: (id) => '/master/${fixture.entity}/$id',
        canCreate: false,
        canEdit: allowed,
        canDelete: allowed,
        canStatus: allowed,
        toolbarLeadingActions: (pane) {
          fixture.pane = pane;
          return const [];
        },
      ),
    );
  }
}

Future<({ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester,
  _Fixture fixture,
) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(body: _Host(fixture)),
      ),
      GoRoute(
        path: '/other',
        builder: (_, _) => const Scaffold(body: Text('另一页面')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(fixture.api),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWith(
          (ref) => AuthenticatedScope(userId: ref.watch(_identity)),
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_allowed)
              ? {'goods:view', 'goods:status', 'goods:delete'}
              : {'goods:view'},
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    container: ProviderScope.containerOf(tester.element(find.byType(_Host))),
    router: router,
  );
}

Future<void> _start(
  WidgetTester tester,
  _Fixture fixture,
  String action, [
  Set<String>? ids,
]) async {
  switch (action) {
    case 'toggle':
      unawaited(fixture.pane.toggleStatus(_rows.first));
    case 'status':
      unawaited(fixture.pane.batchSetStatus(ids ?? {'one', 'two'}, '禁用'));
    case 'delete':
      unawaited(fixture.pane.batchDelete(ids ?? {'one', 'two'}));
  }
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester, String action) async {
  if (action == 'delete') {
    await tester.tap(find.widgetWithText(UtenButton, '删除'));
  } else {
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
  }
  await tester.pump();
}

void main() {
  for (final entity in ['goods', 'clients', 'suppliers', 'moulds']) {
    testWidgets('$entity freezes target IDs and versions before confirmation', (
      tester,
    ) async {
      final fixture = _Fixture(entity);
      await _pump(tester, fixture);
      final ids = {'one', 'two'};
      await _start(tester, fixture, 'status', ids);
      ids.clear();
      await _confirm(tester, 'status');
      await tester.pumpAndSettle();
      expect(fixture.writes.single.path, '/master/$entity/batch-status');
      expect(fixture.writes.single.body, {
        'status': '禁用',
        'items': [
          {'id': 'one', 'version': 7},
          {'id': 'two', 'version': 11},
        ],
      });
      expect(tester.takeException(), isNull);
    });
  }

  for (final action in ['toggle', 'status', 'delete']) {
    testWidgets('$action confirmation cannot write after identity A-B-A', (
      tester,
    ) async {
      final fixture = _Fixture();
      final app = await _pump(tester, fixture);
      await _start(tester, fixture, action);
      app.container.read(_identity.notifier).state = 'B';
      await tester.pump();
      app.container.read(_identity.notifier).state = 'A';
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(fixture.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'revocation then regrant rejects captured confirm callback and direct methods recheck permission',
    (tester) async {
      final fixture = _Fixture();
      final app = await _pump(tester, fixture);
      await _start(tester, fixture, 'toggle');
      final confirm = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认'))
          .onPressed!;
      app.container.read(_allowed.notifier).state = false;
      await tester.pumpAndSettle();
      await fixture.pane.toggleStatus(_rows.first);
      await fixture.pane.batchDelete({'one'});
      expect(find.byType(UtenAlertDialog), findsNothing);
      app.container.read(_allowed.notifier).state = true;
      await tester.pumpAndSettle();
      confirm();
      await tester.pumpAndSettle();
      expect(fixture.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reload during batch confirmation cancels instead of dropping original versions to null',
    (tester) async {
      final fixture = _Fixture();
      await _pump(tester, fixture);
      await _start(tester, fixture, 'status');
      await fixture.pane.reload();
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(fixture.writes, isEmpty);
    },
  );

  testWidgets(
    'category query change and real route navigation cancel old confirmations',
    (tester) async {
      final fixture = _Fixture();
      final app = await _pump(tester, fixture);
      await _start(tester, fixture, 'delete');
      app.container.read(_category.notifier).state = 'cat-b';
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      await _start(tester, fixture, 'delete');
      unawaited(app.router.push<void>('/other'));
      await tester.pumpAndSettle();
      app.router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(fixture.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late private errors and results cannot publish to a changed owner',
    (tester) async {
      final fixture = _Fixture()
        ..pending = true
        ..fail = true;
      final app = await _pump(tester, fixture);
      await _start(tester, fixture, 'delete');
      await _confirm(tester, 'delete');
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(fixture.writes, hasLength(1));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      app.container.read(_identity.notifier).state = 'B';
      await tester.pump();
      app.container.read(_identity.notifier).state = 'A';
      await tester.pump();
      fixture.gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('PRIVATE-OLD'), findsNothing);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial outcome keeps failures and closes old private content on permission loss',
    (tester) async {
      final fixture = _Fixture()..partial = true;
      final app = await _pump(tester, fixture);
      fixture.pane.selectIds({'one'});
      await tester.pumpAndSettle();
      await _start(tester, fixture, 'delete', {'one'});
      await _confirm(tester, 'delete');
      await tester.pumpAndSettle();
      expect(fixture.pane.selectedIds, {'one'});
      expect(find.text('PRIVATE-OLD-LABEL'), findsOneWidget);
      app.container.read(_allowed.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.textContaining('PRIVATE-OLD'), findsNothing);
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(fixture.pane.selectedIds, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving during a pending command removes its root portal before the old response',
    (tester) async {
      final fixture = _Fixture()
        ..pending = true
        ..fail = true;
      final app = await _pump(tester, fixture);
      await _start(tester, fixture, 'delete');
      await _confirm(tester, 'delete');
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      unawaited(app.router.push<void>('/other'));
      await tester.pumpAndSettle();
      expect(find.text('另一页面'), findsOneWidget);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      fixture.gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('PRIVATE-OLD'), findsNothing);
      expect(fixture.writes, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}
