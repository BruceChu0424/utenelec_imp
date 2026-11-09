import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/widgets/finance_native_posting_accounts_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'finance_requirement_test_ui.dart';

void main() {
  for (final rejection in [
    (code: 'UNAUTHORIZED', status: 401),
    (code: 'FORBIDDEN', status: 403),
    (code: 'READ_SCOPE_CHANGED', status: 403),
  ]) {
    testWidgets('accepted mapping projection retires on ${rejection.code}', (
      tester,
    ) async {
      final api = _Api()..directoryTotal = 101;
      await _pump(tester, api);
      final finder = find.byType(MasterDataTableView<Map<String, dynamic>>);
      for (
        var attempt = 0;
        attempt < 60 &&
            tester
                    .widget<MasterDataTableView<Map<String, dynamic>>>(finder)
                    .items
                    .length !=
                101;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        tester.widget<MasterDataTableView<Map<String, dynamic>>>(finder).items,
        hasLength(101),
      );
      expect(find.text('ACCOUNT-0'), findsOneWidget);
      api.failDirectoryPage = 2;
      api.directoryReadError = ApiException(
        rejection.code,
        '原读取已被拒绝',
        httpStatus: rejection.status,
        hasResponseCode: true,
      );
      await tapFinanceAction(tester, '刷新');
      await _waitForReadError(tester, finder);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      expect(table.items, isEmpty);
      expect(table.error, '原读取已被拒绝');
      expect(find.text('ACCOUNT-0'), findsNothing);
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'mapping directory accepts every bounded batch and scroll reads nothing',
    (tester) async {
      final api = _Api()..directoryTotal = 101;
      await _pump(tester, api);
      final finder = find.byType(MasterDataTableView<Map<String, dynamic>>);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      expect(table.items, hasLength(101));
      expect(table.items.last['id'], 'version-100');
      expect(table.totalPages, 1);
      expect(table.onPageChange, isNull);
      // Progressive complete-read ladder (2026-11-08): first batch 50, then
      // aligned 50/100 batches; the reader never rereads a row.
      expect(api.directoryReads.map((q) => q['size']), [50, 50, 100]);
      expect(api.directoryReads.map((q) => q['page']), [1, 2, 2]);
      final reads = api.directoryReads.length;
      await tester.drag(finder, const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(find.text('ACCOUNT-100'), findsOneWidget);
      expect(api.directoryReads, hasLength(reads));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('mapping continuation denial never publishes its first batch', (
    tester,
  ) async {
    final api = _Api()
      ..directoryTotal = 101
      ..failDirectoryPage = 2;
    await _pump(tester, api);
    await _waitForReadError(
      tester,
      find.byType(MasterDataTableView<Map<String, dynamic>>),
    );
    final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
      find.byType(MasterDataTableView<Map<String, dynamic>>),
    );
    expect(table.items, isEmpty);
    expect(api.directoryReads.any((query) => query['page'] == 2), isTrue);
    expect(table.error, '后批无权限');
    await tester.tap(
      find
          .descendant(
            of: find.byType(MasterDataTableView<Map<String, dynamic>>),
            matching: find.byKey(
              const ValueKey('master-table-initial-read-details'),
            ),
          )
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == '后批无权限',
      ),
      findsOneWidget,
    );
    expect(api.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'unknown mapping submission freezes the reviewed UUIDs and replays the same request',
    (tester) async {
      final api = _Api()..loseFirst = true;
      await _pump(tester, api);
      await tapFinanceAction(tester, '新增对应版本');
      await _choose(tester, '会计用途', '应付账款 (AP_CONTROL)');
      await _choose(tester, '真实交易币别范围', 'USD 原币');
      await _choose(tester, '财务科目代码', '220202 原应付美元科目');
      await tester.ensureVisible(financeTextField('来源及变更依据'));
      await tester.enterText(financeTextField('来源及变更依据'), '明确原科目及真实原币，禁止按名称匹配');
      await tester.tap(find.text('保存待审核版本'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(1));
      expect(
        tester.widget<TextField>(financeTextField('来源及变更依据')).enabled,
        isFalse,
      );
      await tester.tap(find.text('核对并重试原提交'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(2));
      expect(jsonEncode(api.saved.first), jsonEncode(api.saved.last));
      expect(api.saved.first['originalCurrencyId'], 'real-usd');
      expect(api.saved.first['accountingCurrencyId'], 'book-usd');
      expect(api.saved.first['styleId'], 'actual-style');
      expect(api.saved.first['accountCode'], '220202');
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow existing table retains the approved version and the same Uten toolbar',
    (tester) async {
      await _pump(tester, _Api()..actual = 1, width: 390, scale: 1.5);
      expect(find.text('220202'), findsOneWidget);
      await tapFinanceAction(tester, '新增对应版本');
      await tester.tap(find.text('保存待审核版本'));
      await tester.pumpAndSettle();
      expect(find.text('请选择用途及已核验币别的财务科目，并填写依据。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _waitForReadError(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 60; attempt++) {
    final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
      finder,
    );
    if (!table.isLoading && table.error != null) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    tester.widget<MasterDataTableView<Map<String, dynamic>>>(finder).error,
    isNotNull,
    reason:
        'The actual continuation rejection must finish and remain observable.',
  );
}

Future<void> _choose(WidgetTester tester, String label, String item) async {
  final dropdown = find.byWidgetPredicate(
    (w) => w is UtenDropdownField && w.label == label,
  );
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _Api api, {
  double width = 1200,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          'finance_report:view',
          'finance:view:all',
          'payment_style:edit',
          'finance_post:execute',
        }),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFinanceNativePostingAccountsDialog(context),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool loseFirst = false;
  int actual = 0;
  final saved = <Map<String, dynamic>>[];
  int? directoryTotal, failDirectoryPage;
  ApiException? directoryReadError;
  final directoryReads = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/native-posting-accounts' && directoryTotal != null) {
      final page = query!['page'] as int, size = query['size'] as int;
      directoryReads.add(Map<String, dynamic>.from(query));
      if (page == failDirectoryPage) {
        throw directoryReadError ??
            ApiException(
              'FORBIDDEN',
              '后批无权限',
              httpStatus: 403,
              hasResponseCode: true,
            );
      }
      return {
        'items': [
          for (
            var i = (page - 1) * size;
            i < page * size && i < directoryTotal!;
            i++
          )
            {
              'id': 'version-$i',
              'role_key': 'AP_CONTROL',
              'account_code': 'ACCOUNT-$i',
              'effective_from': '2026-11-03',
              'configuration_version': i,
              'status': 'DRAFT',
              'enabled': true,
              'source_reference': '原始依据$i',
            },
        ],
        'page': page,
        'size': size,
        'total': directoryTotal,
        'totalPages': (directoryTotal! / size).ceil(),
      };
    }
    if (path.endsWith('/choices')) {
      return {
        'roles': [
          {'id': 'AP_CONTROL', 'name': '应付账款'},
        ],
        'currencies': [
          {'id': 'real-usd', 'code': 'USD', 'name': '原币'},
        ],
      };
    }
    return {
      'items': actual == 0
          ? <Map<String, dynamic>>[]
          : [
              {
                'id': 'version-1',
                'role_key': 'AP_CONTROL',
                'account_code': '220202',
                'effective_from': '2026-11-03',
                'configuration_version': 1,
                'status': 'DRAFT',
                'enabled': true,
                'source_reference': '明确原科目依据',
              },
            ],
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [
    {
      'code': '220202',
      'name': '原应付美元科目',
      'style_id': 'actual-style',
      'accounting_currency_id': 'book-usd',
    },
  ];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    saved.add(Map<String, dynamic>.from(body! as Map));
    actual = 1;
    if (loseFirst) {
      loseFirst = false;
      throw ApiException('NETWORK_ERROR', '响应未收到');
    }
    return {'id': 'version-1'};
  }
}
