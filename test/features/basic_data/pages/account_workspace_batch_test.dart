import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/pages/account_workspace_page.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

final _grants = StateProvider<Set<String>>(
  (_) => {
    Perm.accountView,
    Perm.accountEdit,
    Perm.accountCreate,
    Perm.accountStatus,
    Perm.accountDelete,
  },
);
final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'operator-a'),
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api(super.dio);
  int captures = 0;
  Future<void> Function(int capture)? beforeCapture;
  @override
  Future<AuthenticatedRequestScope> captureRequestScope({
    required bool Function() isCurrent,
  }) {
    captures++;
    final captured = super.captureRequestScope(isCurrent: isCurrent);
    final waiting = beforeCapture?.call(captures);
    if (waiting == null) return captured;
    return captured.then((scope) async {
      await waiting;
      return scope;
    });
  }
}

class _Wire {
  final rows = <String, Map<String, dynamic>>{
    for (final id in ['a', 'b', 'c', 'd'])
      id: {
        'id': id,
        'code': 'ZH-$id',
        'name': {'a': '一号银行户', 'b': '二号现金户', 'c': '三号备用户', 'd': '停用账户'}[id],
        'accountType': id == 'b' ? 'CASH' : 'BANK',
        'currencyId': 'cny',
        'currencyName': '人民币',
        'status': id == 'd' ? '禁用' : '使用',
      },
  };
  final requests = <({String method, String path})>[];
  final writes = <({String method, String path, Map<String, dynamic>? body})>[];
  final scopes = <AuthenticatedRequestScope?>[];
  final protected = {'b'};
  final errors = <String, int>{};
  Future<void> Function(RequestOptions)? beforeWrite;
  int pageSize = 20;
  int active = 0;
  int maxActive = 0;
  late final _Api api = () {
    final dio = Dio(BaseOptions(baseUrl: 'https://account.invalid/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          requests.add((method: request.method, path: request.path));
          try {
            Object? body;
            if (request.method == 'PATCH' || request.method == 'DELETE') {
              final scope = AuthenticatedRequestScope.attach(request);
              scope?.checkCurrent();
              scopes.add(scope);
              writes.add((
                method: request.method,
                path: request.path,
                body: request.data is Map
                    ? Map<String, dynamic>.from(request.data as Map)
                    : null,
              ));
              active++;
              if (active > maxActive) maxActive = active;
              try {
                await beforeWrite?.call(request);
                scope?.checkCurrent();
                final id = request.path.split('/')[3];
                if (protected.contains(id) || errors.containsKey(id)) {
                  handler.reject(
                    DioException(
                      requestOptions: request,
                      type: DioExceptionType.badResponse,
                      response: Response<dynamic>(
                        requestOptions: request,
                        statusCode: errors[id] ?? 409,
                        data: {
                          'code': 'CONFLICT',
                          'message':
                              '账户仍被已审核资金单据使用，不能${request.method == 'DELETE' ? '删除' : '停用'}',
                        },
                      ),
                    ),
                  );
                  return;
                }
                if (request.method == 'DELETE') {
                  rows.remove(id);
                } else {
                  rows[id]!['status'] = (request.data as Map)['status'];
                }
                body = <String, dynamic>{};
              } finally {
                active--;
              }
            } else if (request.path == '/master/accounts/facets') {
              body = {
                'fields': {
                  'status': [
                    {'value': '使用', 'count': 3},
                    {'value': '禁用', 'count': 1},
                  ],
                },
                'nullCounts': <String, int>{},
              };
            } else if (request.path == '/master/accounts') {
              final all = rows.values
                  .where(
                    (row) =>
                        request.queryParameters['status'] == null ||
                        row['status'] == request.queryParameters['status'],
                  )
                  .toList();
              final page =
                  (request.queryParameters['page'] as num?)?.toInt() ?? 1;
              body = {
                'items': all
                    .skip((page - 1) * pageSize)
                    .take(pageSize)
                    .toList(),
                'page': page,
                'size': pageSize,
                'total': all.length,
                'totalPages': (all.length / pageSize).ceil(),
              };
            } else if (request.path.endsWith('/dict') ||
                request.path.endsWith('/tree')) {
              body = <Map<String, dynamic>>[];
            } else {
              body = <String, dynamic>{};
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                data: body,
                statusCode: 200,
              ),
            );
          } catch (error) {
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: request,
                  statusCode: 409,
                  data: {'code': 'SESSION_CHANGED', 'message': '$error'},
                ),
              ),
            );
          }
        },
      ),
    );
    return _Api(dio);
  }();
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Wire wire, {
  double width = 1450,
  double scale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(wire.api),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
        isSuperAdminProvider.overrideWithValue(false),
        accountRepositoryProvider.overrideWithValue(
          DioAccountRepository(wire.api),
        ),
      ],
      child: MaterialApp(
        theme: buildDarkTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const AccountPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(AccountPage)));
}

MasterDataTableView<AccountListItem> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<AccountListItem>));

Future<void> _select(WidgetTester tester, Set<String> ids) async {
  _table(tester).onSelectedIdsChanged!(ids);
  await tester.pumpAndSettle();
}

Finder _button(String text) => find.widgetWithText(UtenButton, text);
Future<void> _confirm(WidgetTester tester, String text) async {
  await tester.tap(
    find.descendant(of: find.byType(UtenAlertDialog), matching: _button(text)),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'concurrent clean stale callbacks open one confirmation and write one batch',
    (tester) async {
      final wire = _Wire();
      await _pump(tester, wire);
      await _select(tester, {'a', 'c'});
      final staleDelete = _table(tester)
          .rowMenuBuilder!(_table(tester).items.first)
          .whereType<UtenMenuItem>()
          .singleWhere((item) => item.label.startsWith('删除选中'));
      final capturesBefore = wire.api.captures;
      final secondScope = Completer<void>();
      addTearDown(() {
        if (!secondScope.isCompleted) secondScope.complete();
      });
      wire.api.beforeCapture = (capture) => capture == capturesBefore + 2
          ? secondScope.future
          : Future<void>.value();
      final requests = [
        staleDelete.onTap() as Future<void>,
        staleDelete.onTap() as Future<void>,
      ];
      unawaited(Future.wait(requests));
      await tester.pumpAndSettle();
      expect(find.text('批量删除账户'), findsOneWidget);
      secondScope.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsOneWidget);
      expect(wire.api.captures, capturesBefore + 1);
      expect(wire.writes, isEmpty);
      await _confirm(tester, '删除');
      await tester.pumpAndSettle();
      await Future.wait(requests);
      expect(wire.writes.map((write) => write.path), [
        '/master/accounts/a',
        '/master/accounts/c',
      ]);
      expect(wire.maxActive, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'checkbox selection uses one floating group with permission-gated batch actions',
    (tester) async {
      final wire = _Wire();
      final container = await _pump(tester, wire);
      expect(_table(tester).selectable, isTrue);
      expect(find.byType(Checkbox), findsWidgets);
      await _select(tester, {'a', 'b'});
      expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
      expect(
        tester.widget<UtenButton>(_button('删除选中')).type,
        UtenButtonType.danger,
      );
      expect(
        tester.widget<UtenButton>(_button('停用选中')).type,
        UtenButtonType.danger,
      );
      final menu = _table(tester).rowMenuBuilder!(_table(tester).items.first)
          .whereType<UtenMenuItem>()
          .toList();
      expect(menu.map((item) => item.label), ['停用选中(2)', '启用选中(2)', '删除选中(2)']);
      expect(menu.every((item) => item.preserveSelectionAfterAction), isTrue);
      container.read(_grants.notifier).state = {Perm.accountView};
      await tester.pumpAndSettle();
      await _select(tester, {'a'});
      expect(_button('删除选中'), findsNothing);
      expect(_button('停用选中'), findsNothing);
      expect(_button('启用选中'), findsNothing);
      expect(wire.writes, isEmpty);
    },
  );

  testWidgets(
    'canceling either delete or status confirmation sends no request and retains selection',
    (tester) async {
      final wire = _Wire();
      await _pump(tester, wire);
      await _select(tester, {'a', 'c'});
      for (final action in ['删除选中', '停用选中']) {
        await tester.tap(_button(action));
        await tester.pumpAndSettle();
        expect(wire.writes, isEmpty);
        await _confirm(tester, '取消');
        await tester.pumpAndSettle();
        expect(_table(tester).selectedIds, {'a', 'c'});
      }
      expect(wire.writes, isEmpty);
      expect(wire.api.captures, 2);
    },
  );

  testWidgets(
    'native per-account deletion is serial and preserves only failures with exact reasons',
    (tester) async {
      final wire = _Wire();
      final container = await _pump(tester, wire);
      await _select(tester, {'a', 'b', 'c'});
      await tester.tap(_button('删除选中'));
      await tester.pumpAndSettle();
      await _confirm(tester, '删除');
      await tester.pumpAndSettle();
      expect(wire.writes.map((request) => (request.method, request.path)), [
        ('DELETE', '/master/accounts/a'),
        ('DELETE', '/master/accounts/b'),
        ('DELETE', '/master/accounts/c'),
      ]);
      expect(wire.maxActive, 1);
      expect(wire.api.captures, 1);
      expect(wire.scopes.first, isNotNull);
      expect(
        wire.scopes.every((scope) => identical(scope, wire.scopes.first)),
        isTrue,
      );
      expect(_table(tester).selectedIds, {'b'});
      expect(find.byKey(const Key('master-batch-outcome')), findsOneWidget);
      expect(find.text('二号现金户'), findsWidgets);
      expect(find.text('账户仍被已审核资金单据使用，不能删除'), findsOneWidget);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        wire.requests.any((request) => request.path.contains('/batch')),
        isFalse,
      );
      container.read(_grants.notifier).state = {Perm.accountView};
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('master-batch-outcome')), findsNothing);
      expect(_table(tester).selectedIds, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final status in ['禁用', '使用']) {
    testWidgets('explicit $status batch uses native status-only PATCH bodies', (
      tester,
    ) async {
      final wire = _Wire();
      await _pump(tester, wire);
      await _select(tester, {'a', 'c'});
      await tester.tap(_button(status == '禁用' ? '停用选中' : '启用选中'));
      await tester.pumpAndSettle();
      await _confirm(tester, '确认');
      await tester.pumpAndSettle();
      expect(wire.writes.map((request) => (request.method, request.path)), [
        ('PATCH', '/master/accounts/a/status'),
        ('PATCH', '/master/accounts/c/status'),
      ]);
      for (final write in wire.writes) {
        expect(write.body, {'status': status});
      }
      expect(_table(tester).selectedIds, isEmpty);
      expect(wire.maxActive, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'identity A-B-A while confirmation is open closes it and sends nothing',
    (tester) async {
      final wire = _Wire();
      final container = await _pump(tester, wire);
      await _select(tester, {'a', 'c'});
      await tester.tap(_button('删除选中'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsOneWidget);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'operator-b',
      );
      await tester.pump();
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'operator-a',
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(_table(tester).selectedIds, isEmpty);
      expect(wire.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['identity', 'permission']) {
    testWidgets(
      '$change change during first write stops remaining commands and old outcome',
      (tester) async {
        final gate = Completer<void>();
        final wire = _Wire()..beforeWrite = (_) => gate.future;
        final container = await _pump(tester, wire);
        await _select(tester, {'a', 'b', 'c'});
        await tester.tap(_button('删除选中'));
        await tester.pumpAndSettle();
        await _confirm(tester, '删除');
        for (var frame = 0; frame < 10 && wire.writes.isEmpty; frame++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        expect(wire.writes, hasLength(1));
        expect(find.byType(UtenBusyOverlay), findsOneWidget);
        if (change == 'identity') {
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'operator-b',
          );
          await tester.pump();
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'operator-a',
          );
        } else {
          container.read(_grants.notifier).state = {Perm.accountView};
        }
        await tester.pump();
        gate.complete();
        await tester.pumpAndSettle();
        expect(wire.writes, hasLength(1));
        expect(_table(tester).selectedIds, isEmpty);
        expect(find.byKey(const Key('master-batch-outcome')), findsNothing);
        expect(find.byType(UtenBusyOverlay), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    '403 stops later native requests and retains all unprocessed selections',
    (tester) async {
      final wire = _Wire()..errors['a'] = 403;
      await _pump(tester, wire);
      await _select(tester, {'a', 'c'});
      await tester.tap(_button('删除选中'));
      await tester.pumpAndSettle();
      await _confirm(tester, '删除');
      await tester.pumpAndSettle();
      expect(wire.writes, hasLength(1));
      expect(_table(tester).selectedIds, {'a', 'c'});
      expect(find.text('权限或登录状态已变化，该账户尚未处理'), findsOneWidget);
    },
  );

  testWidgets(
    'dirty inline edits require discard before any destructive confirmation',
    (tester) async {
      final wire = _Wire();
      await _pump(tester, wire);
      await _select(tester, {'a', 'c'});
      final staleDelete = _table(tester)
          .rowMenuBuilder!(_table(tester).items.first)
          .whereType<UtenMenuItem>()
          .singleWhere((item) => item.label.startsWith('删除选中'));
      await tester.tap(_button('编辑模式'));
      await tester.pumpAndSettle();
      final editor = tester.widget<MasterInlineEditActions<AccountListItem>>(
        find.byType(MasterInlineEditActions<AccountListItem>),
      );
      final field = MasterInlineField<AccountListItem>(
        key: 'name',
        read: (row) => row.name,
      );
      editor.controller.setValue('a', field, '未保存名称', originalValue: '一号银行户');
      await tester.pumpAndSettle();
      expect(_button('删除选中'), findsNothing);
      final capturesBefore = wire.api.captures;
      unawaited(staleDelete.onTap() as Future<void>);
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      expect(find.text('批量删除账户'), findsNothing);
      expect(wire.api.captures, capturesBefore);
      await tester.tap(find.widgetWithText(TextButton, '继续编辑'));
      await tester.pumpAndSettle();
      expect(editor.controller.dirty, isTrue);
      expect(wire.writes, isEmpty);
      unawaited(staleDelete.onTap() as Future<void>);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '放弃修改'));
      await tester.pumpAndSettle();
      expect(editor.controller.dirty, isFalse);
      expect(find.text('批量删除账户'), findsOneWidget);
      expect(wire.writes, isEmpty);
      await _confirm(tester, '删除');
      await tester.pumpAndSettle();
      expect(wire.writes.map((write) => write.path), [
        '/master/accounts/a',
        '/master/accounts/c',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'paging keeps selected identities while refresh and filters clear them',
    (tester) async {
      final wire = _Wire()..pageSize = 2;
      await _pump(tester, wire);
      await _select(tester, {'a'});
      _table(tester).onPageChange!(2);
      await tester.pumpAndSettle();
      expect(_table(tester).selectedIds, {'a'});
      await _select(tester, {'a', 'c'});
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(_table(tester).selectedIds, isEmpty);
      await _select(tester, {'a'});
      _table(tester).onFilterChanged('status', '禁用');
      await tester.pumpAndSettle();
      expect(_table(tester).selectedIds, isEmpty);
    },
  );

  testWidgets(
    '390px dark large text keeps one shared floating group and actions reachable',
    (tester) async {
      await _pump(tester, _Wire(), width: 390, scale: 1.5);
      await _select(tester, {'a', 'c'});
      expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
      await tester.ensureVisible(_button('删除选中'));
      await tester.pumpAndSettle();
      expect(_button('删除选中').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
