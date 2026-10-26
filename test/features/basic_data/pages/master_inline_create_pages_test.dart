import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/pages/color_page.dart';
import 'package:uten_imp/features/basic_data/pages/currency_page.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/pages/account_workspace_page.dart';
import 'package:uten_imp/features/basic_data/pages/settlement_method_page.dart';
import 'package:uten_imp/features/basic_data/pages/warehouse_page.dart';
import 'package:uten_imp/features/basic_data/pages/payment_style_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Wire {
  _Wire(this.type, {bool existing = false, bool protectedParent = false}) {
    if (existing) {
      rows.add({
        'id': 'old',
        'code': 'OLD01',
        'name': '原有资料',
        'status': '使用',
        if (type == 'payment-styles') ...{
          'code': protectedParent ? 'SYS-ACCOUNT-BALANCE-CLEARING' : 'NORMAL01',
          'category': 'EXPENSE',
          'level': 0,
          'children': <Object>[],
        },
        if (type == 'currencies') 'exchangeRate': 1,
      });
    }
  }
  final String type;
  String get endpoint => type == 'settlement'
      ? '/master/reference-methods/settlement'
      : '/master/$type';
  final rows = <Map<String, dynamic>>[];
  final created = <Map<String, dynamic>>[];
  bool failReloadAfterCreate = false;
  late final api = ApiClient(
    Dio(BaseOptions(baseUrl: 'https://creation.invalid/api'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            Object data = <String, dynamic>{};
            if (request.method == 'GET' && request.path == endpoint) {
              if (failReloadAfterCreate && created.isNotEmpty) {
                handler.reject(
                  DioException.badResponse(
                    statusCode: 503,
                    requestOptions: request,
                    response: Response<dynamic>(
                      requestOptions: request,
                      statusCode: 503,
                      data: {'code': 'UNAVAILABLE', 'message': '列表刷新失败'},
                    ),
                  ),
                );
                return;
              }
              data = {
                'items': rows,
                'page': 1,
                'size': 20,
                'total': rows.length,
                'totalPages': 1,
              };
            } else if (request.method == 'GET' &&
                (request.path.endsWith('/dict') ||
                    request.path.endsWith('/tree') ||
                    request.path.endsWith('settlement-admin'))) {
              data = request.path.endsWith('/tree') && type == 'payment-styles'
                  ? rows
                  : <Object>[];
            } else if (request.method == 'GET' &&
                request.path.endsWith('/code-availability')) {
              data = {'available': true};
            } else if (request.method == 'GET' &&
                rows.any((row) => request.path == '$endpoint/${row['id']}')) {
              data = rows.firstWhere(
                (row) => request.path == '$endpoint/${row['id']}',
              );
            } else if (request.method == 'POST' && request.path == endpoint) {
              final body = Map<String, dynamic>.from(request.data as Map);
              created.add(body);
              final row = {
                'id': 'new-${created.length}',
                ...body,
                'code': 'AUTO${created.length}',
              };
              rows.add(row);
              data = row;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Wire wire, {
  bool create = true,
  bool edit = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final local = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1440, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final prefix = switch (wire.type) {
    'colors' => 'color',
    'units' => 'unit',
    'currencies' => 'currency',
    'accounts' => 'account',
    'warehouses' => 'warehouse',
    'payment-styles' => 'payment_style',
    _ => 'settlement_method',
  };
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(local),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'creation-test'),
        ),
        currentPermissionsProvider.overrideWithValue({
          '$prefix:view',
          if (create) '$prefix:create',
          if (edit) '$prefix:edit',
        }),
        isSuperAdminProvider.overrideWithValue(false),
        apiClientProvider.overrideWithValue(wire.api),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: switch (wire.type) {
          'colors' => const ColorPage(),
          'units' => const UnitPage(),
          'currencies' => const CurrencyPage(),
          'accounts' => const AccountPage(),
          'warehouses' => const WarehousePage(),
          'payment-styles' => const PaymentStylePage(),
          _ => const SettlementMethodPage(),
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MasterInlineEditController<dynamic> _controller(WidgetTester tester) => tester
    .widget<MasterInlineEditActions<dynamic>>(
      find.byWidgetPredicate((widget) => widget is MasterInlineEditActions),
    )
    .controller;

Future<void> _name(WidgetTester tester, String name) async {
  final rows = _controller(tester).appendRowsSource.value;
  final key = (rows.last.key as ValueKey).value as String;
  final activation = find.byKey(ValueKey('inline-create-activate-$key-name'));
  await tester.ensureVisible(activation);
  await tester.tap(activation);
  await tester.pump();
  final field = find.byKey(ValueKey('inline-create-cell-$key-name'));
  await tester.ensureVisible(field);
  await tester.enterText(field, name);
  await tester.pump();
}

void main() {
  for (final protected in [false, true]) {
    testWidgets(
      'payment-style subtree creation respects protected parent=$protected and create-only mode',
      (tester) async {
        final wire = _Wire(
          'payment-styles',
          existing: true,
          protectedParent: protected,
        );
        await _pump(tester, wire);
        await tester.tap(find.text('编辑模式'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('所选类别及下级'));
        await tester.pumpAndSettle();
        // ignore: avoid_dynamic_calls
        final config =
            (tester.state(find.byType(PaymentStylePage)) as dynamic)
                    .inlineCreation
                as MasterInlineCreateConfig;
        expect(config.canCreate, !protected);
        if (!protected) {
          expect(config.defaults['parentId'], 'old');
          expect(_controller(tester).active, isTrue);
          expect(_controller(tester).appendRowsSource.value, hasLength(3));
        }
        expect(wire.created, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'confirmed creations are not repeated after the final refresh fails',
    (tester) async {
      final wire = _Wire('colors')..failReloadAfterCreate = true;
      await _pump(tester, wire);
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await _name(tester, '已保存新增');
      await _name(tester, '第二条新增');
      final controller = _controller(tester);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenButton &&
              widget.child is Text &&
              ((widget.child as Text).data?.startsWith('保存 ') ?? false),
        ),
      );
      await tester.pumpAndSettle();
      expect(wire.created.map((body) => body['name']), ['已保存新增', '第二条新增']);
      expect(controller.dirty, isFalse);
      expect(
        controller.creationDraftKeys.every(
          (key) => !controller.creationIsUncertain(key),
        ),
        isTrue,
      );
      wire.failReloadAfterCreate = false;
      await tester.tap(find.text('重试').first);
      await tester.pumpAndSettle();
      await controller.save(
        (_, _) async => fail('No existing row should be saved'),
      );
      expect(wire.created.map((body) => body['name']), ['已保存新增', '第二条新增']);
      expect(controller.dirty, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  for (final entry in {
    'accounts': AccountPage,
    'warehouses': WarehousePage,
    'payment-styles': PaymentStylePage,
    'settlement': SettlementMethodPage,
  }.entries) {
    testWidgets(
      '${entry.key} creation retains real business fields and never submits draft identity',
      (tester) async {
        final wire = _Wire(entry.key);
        await _pump(tester, wire);
        // Read the actual page adapter rather than reimplementing its request mapping.
        // ignore: avoid_dynamic_calls
        final config =
            (tester.state(find.byType(entry.value)) as dynamic).inlineCreation
                as MasterInlineCreateConfig;
        final fields = {for (final field in config.fields) field.key: field};
        expect(config.canCreate, isTrue);
        expect(fields['name']!.required, isTrue);
        expect(fields.keys, isNot(contains('id')));
        final values = <String, dynamic>{...config.defaults, 'name': '直接新增'};
        switch (entry.key) {
          case 'accounts':
            expect(fields['currencyId']!.required, isTrue);
            expect(fields['styleId']!.required, isTrue);
            expect(fields['styleId']!.customBuilder, isNotNull);
            expect(fields.keys, isNot(contains('balanceCurrent')));
            values.addAll({
              'currencyId': 'currency-uuid',
              'styleId': 'style-uuid',
            });
          case 'warehouses':
            expect(fields.keys, isNot(contains('isLineSide')));
            expect(fields.keys, isNot(contains('parentId')));
            values.addAll({'accountable': 'true', 'defective': 'false'});
          case 'settlement':
            expect(
              fields.keys,
              containsAll([
                'termsBase',
                'dueRule',
                'defaultDueDays',
                'fixedDayOfMonth',
                'monthsAhead',
              ]),
            );
            values.addAll({
              'defaultDueDays': 30,
              'monthsAhead': 0,
              'fixedDayOfMonth': 17,
            });
          case 'payment-styles':
            expect(
              fields.keys,
              containsAll([
                'parentId',
                'sortOrder',
                'receipt',
                'payment',
                'departmental',
              ]),
            );
            values['payment'] = 'true';
        }
        await tester.runAsync(
          () => config.onCreate('inline-new:not-a-business-uuid', values),
        );
        expect(wire.created, hasLength(1));
        final body = wire.created.single;
        expect(body, isNot(contains('id')));
        expect(body.values, isNot(contains('inline-new:not-a-business-uuid')));
        if (entry.key == 'warehouses') {
          expect(body['accountable'], isTrue);
          expect(body['defective'], isFalse);
        } else if (entry.key == 'payment-styles') {
          expect(body['category'], 'EXPENSE');
          expect(body['payment'], isTrue);
          expect(body['parentId'], isNull);
        } else if (entry.key == 'settlement') {
          expect((body['terms'] as Map)['fixedDayOfMonth'], isNull);
          expect((body['terms'] as Map)['defaultDueDays'], 30);
        } else {
          expect(body['currencyId'], 'currency-uuid');
          expect(body['styleId'], 'style-uuid');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final type in ['colors', 'units', 'currencies']) {
    testWidgets(
      '$type empty table create-only saves consecutive new rows with automatic codes',
      (tester) async {
        final wire = _Wire(type);
        await _pump(tester, wire);
        await tester.tap(find.text('编辑模式'));
        await tester.pumpAndSettle();
        expect(_controller(tester).appendRowsSource.value, hasLength(3));
        expect(wire.created, isEmpty);
        await _name(tester, '新增资料一');
        expect(_controller(tester).appendRowsSource.value, hasLength(4));
        await _name(tester, '新增资料二');
        expect(_controller(tester).appendRowsSource.value, hasLength(5));
        final save = find.byWidgetPredicate(
          (widget) =>
              widget is UtenButton &&
              widget.child is Text &&
              ((widget.child as Text).data?.startsWith('保存 ') ?? false),
        );
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(wire.created.map((body) => body['name']), ['新增资料一', '新增资料二']);
        for (final body in wire.created) {
          expect(body['code'], anyOf(isNull, ''));
          expect(body, isNot(contains('id')));
          expect(body['status'], '使用');
          expect(body, isNot(contains('legacyId')));
        }
        expect(_controller(tester).dirty, isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$type create permission keeps existing records read-only', (
      tester,
    ) async {
      await _pump(tester, _Wire(type, existing: true));
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('inline-activate-old-name')),
        findsNothing,
      );
      expect(find.text('原有资料'), findsOneWidget);
      expect(_controller(tester).appendRowsSource.value, hasLength(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$type editing without create permission does not manufacture new rows',
      (tester) async {
        await _pump(
          tester,
          _Wire(type, existing: true),
          create: false,
          edit: true,
        );
        await tester.tap(find.text('编辑模式'));
        await tester.pumpAndSettle();
        expect(_controller(tester).appendRowsSource.value, isEmpty);
        expect(
          find.byKey(const ValueKey('inline-activate-old-name')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
