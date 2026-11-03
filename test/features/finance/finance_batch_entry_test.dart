import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/models/finance_entry_request.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/audit_screenshot_support.dart';

void main() {
  test('client grouping preview uses the shared server contract', () {
    final contract =
        jsonDecode(
              File(
                'contracts/finance-entry-grouping-v1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    for (final scenario
        in (contract['cases'] as List).cast<Map<String, dynamic>>()) {
      final keys = (scenario['entries'] as List)
          .cast<Map<String, dynamic>>()
          .map(
            (entry) => financeEntryGroupKey(Map<String, dynamic>.from(entry)),
          )
          .toSet();
      expect(
        keys.length,
        scenario['groups'],
        reason: scenario['name'] as String,
      );
    }
  });

  test(
    'two-of-three pricing works in all orders and keeps explicit amount',
    () {
      for (final inputs in [
        ['qty', 'price'],
        ['price', 'qty'],
        ['qty', 'amount'],
        ['amount', 'qty'],
        ['price', 'amount'],
        ['amount', 'price'],
      ]) {
        final row = FinanceGridRow(mode: ItemMode.allocate)
          ..enableEntryPricing();
        final fields = {
          'qty': row.qty,
          'price': row.price,
          'amount': row.amount,
        };
        final values = {'qty': '4', 'price': '2.5', 'amount': '10'};
        for (final input in inputs) {
          fields[input]!.text = values[input]!;
        }
        expect(double.parse(row.qty.text), 4, reason: inputs.toString());
        expect(double.parse(row.price.text), 2.5, reason: inputs.toString());
        expect(double.parse(row.amount.text), 10, reason: inputs.toString());
        row.dispose();
      }
      final row = FinanceGridRow(mode: ItemMode.allocate)..enableEntryPricing();
      row.amount.text = '0.000000000000000000000001';
      expect(row.amount.text, '0.000000000000000000000001');
      row.dispose();
    },
  );

  for (final type in FinanceDocType.values) {
    testWidgets(
      '${type.name} creation puts settlement terms in the common selectable grid',
      (tester) async {
        final env = await _open(tester, type);
        final table = _table(tester);
        expect(table.selectable, isTrue);
        expect(
          table.columns.map((column) => column.key),
          containsAll([
            'entryAccount',
            'entryCurrency',
            'exchangeRate',
            'amount',
          ]),
        );
        if (type == FinanceDocType.payment || type == FinanceDocType.receipt) {
          expect(
            table.columns.map((column) => column.key),
            containsAll(['entryParty', 'entryFee', 'entryBankReference']),
          );
          expect(find.text('请先引用已入账的应付；暂不支持给供应商预付'), findsNothing);
        }
        await tester.tap(find.text('添加行').first);
        await tester.pumpAndSettle();
        expect(table.controller.rows, hasLength(2));
        expect(tester.takeException(), isNull);
        await env.close(tester);
      },
    );
  }

  testWidgets(
    'row reference imports its supplier and preserves entered bank reference',
    (tester) async {
      final env = await _open(tester, FinanceDocType.payment);
      final row = _table(tester).controller[0];
      row.entry.partyId = 'supplier-A';
      row.entry.bankReference.text = 'OPTIONAL-REFERENCE';
      row.entry.touch();
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用应付').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ar-ap-select-ap-cny')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ar-ap-confirm')));
      await tester.pumpAndSettle();
      final imported = _table(tester).controller.rows.single;
      expect(imported.appliedLedgerId, 'ap-cny');
      expect(imported.entry.partyId, 'supplier-A');
      expect(imported.entry.currencyId, 'cny');
      expect(imported.exchangeRate.text, '1');
      expect(imported.entry.bankReference.text, 'OPTIONAL-REFERENCE');
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets(
    'batch fill applies only selected rows and cancel preserves input',
    (tester) async {
      final env = await _open(tester, FinanceDocType.expense);
      final table = _table(tester);
      await tester.tap(find.text('添加行').first);
      await tester.pumpAndSettle();
      table.controller.setSelected([table.controller[0]], true);
      await tester.tap(find.text('批量填写').first);
      await tester.pumpAndSettle();
      final field = find
          .byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.labelText == '金额',
          )
          .last;
      await tester.enterText(field, '12.500000000000000000000001');
      await tester.tap(find.text('填入所选行'));
      await tester.pumpAndSettle();
      expect(table.controller[0].amount.text, '12.500000000000000000000001');
      expect(table.controller[1].amount.text, isEmpty);
      await tester.tap(find.text('批量填写').first);
      await tester.pumpAndSettle();
      await tester.enterText(field, '999');
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      expect(table.controller[0].amount.text, '12.500000000000000000000001');
      await env.close(tester);
    },
  );

  testWidgets(
    'mixed suppliers preview two documents and submit one atomic batch',
    (tester) async {
      final env = await _open(tester, FinanceDocType.payment);
      final table = _table(tester);
      final rows = table.controller;
      final first = rows[0];
      _payment(first, 'supplier-A', 'ledger-1', '10');
      final second = table.createBlankRow!();
      _payment(second, 'supplier-A', 'ledger-2', '20');
      final third = table.createBlankRow!();
      _payment(third, 'supplier-B', 'ledger-3', '30');
      rows.addRows([second, third]);
      await tester.pumpAndSettle();
      expect(find.text('预计生成 2 张单据'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(env.api.bodies, hasLength(1));
      expect(env.api.paths.single, '/finance/payments/batch');
      expect((env.api.bodies.single['documents'] as List), hasLength(3));
      expect(find.text('已完成'), findsOneWidget);
      await env.close(tester);
    },
  );

  testWidgets(
    'unknown result keeps original command across hard close and replays exactly',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      var env = await _open(tester, FinanceDocType.payment, storage: storage);
      _payment(
        _table(tester).controller[0],
        'supplier-A',
        'ledger-1',
        '0.000000000000000000000001',
      );
      env.api.timeout = true;
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final original = jsonEncode(env.api.bodies.single);
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      await env.close(tester);
      env = await _open(
        tester,
        FinanceDocType.payment,
        storage: storage,
        location: draft.resumeLocation,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(jsonEncode(env.api.bodies.single), original);
      expect(find.text('已完成'), findsOneWidget);
      await env.close(tester);
    },
  );

  testWidgets(
    '1000 rapid edits preserve distinct currencies, selection and draft values',
    (tester) async {
      final env = await _open(tester, FinanceDocType.payment);
      final table = _table(tester);
      final additions = List.generate(999, (_) => table.createBlankRow!());
      table.controller.addRows(additions);
      for (var index = 0; index < table.controller.length; index++) {
        final row = table.controller[index];
        _payment(
          row,
          'supplier-${index % 8}',
          'ledger-$index',
          '$index.000000000000000000000001',
        );
      }
      for (var index = 1; index < table.controller.length; index += 2) {
        final row = table.controller[index];
        row.entry.currencyId = 'usd';
        row.currencyId = 'usd';
        row.exchangeRate.text = '7.2';
        row.entry.accountAmount.text = row.amount.text;
        row.entry.touch();
      }
      table.controller.setSelected([
        table.controller[1],
        table.controller[999],
      ], true);
      await tester.pumpAndSettle();
      final state =
          tester.state(find.byType(FinanceDocEditPage))
              as FormDraftMixin<FinanceDocEditPage>;
      var saved = false;
      final saving = state.saveFormDraftNow().whenComplete(() => saved = true);
      for (var frame = 0; frame < 2000 && !saved; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
      expect(saved, isTrue);
      await saving;
      final snapshot = state.captureFormDraft();
      expect(snapshot['rows'], hasLength(1000));
      expect(
        (snapshot['rows'] as List)
            .cast<Map<String, dynamic>>()
            .map((row) => (row['entry'] as Map<String, dynamic>)['currencyId'])
            .toSet(),
        {'cny', 'usd'},
      );
      expect(snapshot['selected'], [1, 999]);
      expect(
        ((snapshot['rows'] as List).last as Map)['amount'],
        '999.000000000000000000000001',
      );
      expect(env.api.bodies, isEmpty);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets('desktop and narrow layouts retain the row grid and save action', (
    tester,
  ) async {
    if (Platform.environment['UTEN_CAPTURE_FINANCE_ENTRY'] == 'true') {
      await loadAuditScreenshotFonts(tester);
    }
    for (final layout in [
      (const Size(1600, 1000), 1.0),
      (const Size(390, 844), 1.0),
      (const Size(1600, 1000), 1.5),
    ]) {
      final size = layout.$1;
      final capture = GlobalKey();
      final env = await _open(
        tester,
        FinanceDocType.payment,
        size: size,
        capture: capture,
        zoom: layout.$2,
      );
      _payment(
        _table(tester).controller[0],
        'supplier-A',
        'ledger-1',
        '1200.50',
      );
      await env.container.read(financeNameServiceProvider).loadSupplierNames([
        'supplier-A',
      ]);
      await tester.pumpAndSettle();
      expect(find.text('保存').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['UTEN_CAPTURE_FINANCE_ENTRY'] == 'true') {
        await saveAuditScreenshot(
          tester,
          capture,
          'finance-entry-${size.width.toInt()}${layout.$2 == 1 ? '' : '-zoom150'}',
        );
      }
      await env.close(tester);
    }
  });
}

void _payment(FinanceGridRow row, String party, String ledger, String amount) {
  row.entry.partyId = party;
  row.entry.accountId = 'account-cny';
  row.entry.currencyId = 'cny';
  row.entry.methodId = 'method';
  row.currencyId = 'cny';
  row.appliedLedgerId = ledger;
  row.appliedBillNo = ledger;
  row.balanceOriginalText = amount;
  row.amount.text = amount;
  row.exchangeRate.text = '1';
  row.entry.touch();
}

UtenEditableGrid<FinanceGridRow> _table(WidgetTester tester) =>
    tester.widget(find.byType(UtenEditableGrid<FinanceGridRow>));

class _Environment {
  _Environment(this.api, this.container, this.router);
  final _Api api;
  final ProviderContainer container;
  final GoRouter router;
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    container.dispose();
  }
}

Future<_Environment> _open(
  WidgetTester tester,
  FinanceDocType type, {
  MemoryFormDraftStorage? storage,
  String? location,
  GlobalKey? capture,
  Size size = const Size(1800, 1100),
  double zoom = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final api = _Api();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://finance-batch.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'fixture'),
      ),
      currentPermissionsProvider.overrideWithValue({
        for (final type in FinanceDocType.values) ...{
          FinanceDocConfig.by(type).createPerm!,
          FinanceDocConfig.by(type).listPerm,
        },
      }),
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      formDraftStorageProvider.overrideWithValue(
        storage ?? MemoryFormDraftStorage(),
      ),
    ],
  );
  final base = '/finance/${type.pathSegment}';
  final router = GoRouter(
    initialLocation: location ?? '$base/new',
    routes: [
      DraftAwareGoRoute(
        path: '$base/new',
        builder: (_, _) => RepaintBoundary(
          key: capture,
          child: UtenDisplayZoomBox(
            fontFactor: zoom,
            child: FinanceDocEditPage(docType: type),
          ),
        ),
      ),
      GoRoute(
        path: base,
        builder: (_, _) => const Scaffold(body: Text('已完成')),
      ),
      GoRoute(
        path: '$base/:id',
        builder: (_, _) => const Scaffold(body: Text('已完成')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: auditScreenshotTheme(buildLightTheme()),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Environment(api, container, router);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final bodies = <Map<String, dynamic>>[];
  final paths = <String>[];
  bool timeout = false;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/finance/ar-ap'
      ? {
          'items': [
            {
              'id': 'ap-cny',
              'direction': 'AP',
              'billNo': 'AP-CNY-001',
              'supplierId': 'supplier-A',
              'currencyId': 'cny',
              'currencyCode': 'CNY',
              'currencyName': '人民币',
              'amountOriginal': 30,
              'amountSettled': 0,
              'amountBalanceOriginal': 30,
            },
          ],
          'total': 1,
          'page': 1,
          'size': 50,
        }
      : {'items': <dynamic>[], 'total': 0};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('suppliers') && path.contains('lookup')) {
      return [
        {'id': 'supplier-A', 'name': '供应商甲', 'status': '使用'},
      ];
    }
    if (path.endsWith('/accounts') || path.contains('/accounts/')) {
      return [
        {
          'id': 'account-cny',
          'name': '人民币账户',
          'currencyId': 'cny',
          'currencyCode': 'CNY',
          'currencyName': '人民币',
          'baseCurrency': true,
          'status': '使用',
        },
      ];
    }
    if (path.contains('currencies')) {
      return [
        {
          'id': 'cny',
          'code': 'CNY',
          'name': '人民币',
          'baseCurrency': true,
          'exchangeRate': '1',
        },
        {
          'id': 'usd',
          'code': 'USD',
          'name': '美元',
          'baseCurrency': false,
          'exchangeRate': '7.2',
        },
      ];
    }
    if (path.contains('payment-styles')) {
      return [
        {
          'id': 'style',
          'name': '办公费用',
          'status': '使用',
          'children': <dynamic>[],
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    paths.add(path);
    bodies.add(Map<String, dynamic>.from(body as Map));
    if (timeout) throw NetworkTimeoutException();
    final groups = (body['documents'] as List)
        .cast<Map<String, dynamic>>()
        .map((entry) => financeEntryGroupKey(Map<String, dynamic>.from(entry)))
        .toSet();
    return {
      'items': [
        for (var index = 0; index < groups.length; index++)
          {'id': 'created-$index', 'items': <dynamic>[], 'status': 0},
      ],
    };
  }
}
