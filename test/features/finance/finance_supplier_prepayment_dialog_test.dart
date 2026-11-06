import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/widgets/finance_supplier_prepayment_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'finance_requirement_test_ui.dart';

void main() {
  testWidgets(
    'accepted settlement rows and readonly balances retire after access rejection',
    (tester) async {
      final api = _AdvanceApi()..settlementsTotal = 101;
      await _pump(tester, api);
      await _openRow(tester, 'ADV-001');
      final finder = find
          .byType(MasterDataTableView<Map<String, dynamic>>)
          .last;
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
      final facts = find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data ?? '').contains('未应用原币：80'),
      );
      expect(facts, findsOneWidget);
      api.failSettlementPage = 2;
      await tapFinanceAction(tester, '刷新');
      await _waitForReadError(tester, finder);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      expect(table.items, isEmpty);
      expect(table.error, '后批无权限');
      expect(facts, findsNothing);
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byWidgetPredicate(
                (w) => w is UtenDropdownField && w.label == '处理记录',
              ),
            )
            .value,
        'APPLICATION',
      );
      expect(api.saves, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'accepted supplier directory rows retire after access rejection',
    (tester) async {
      final api = _AdvanceApi()..directoryTotal = 101;
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
      api.failDirectoryPage = 2;
      await tapFinanceAction(tester, '刷新');
      await _waitForReadError(tester, finder);
      expect(
        tester.widget<MasterDataTableView<Map<String, dynamic>>>(finder).items,
        isEmpty,
      );
      expect(api.saves, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'supplier directory collects the filtered tail and scroll makes no reads',
    (tester) async {
      final api = _AdvanceApi()..directoryTotal = 101;
      await _pump(
        tester,
        api,
        supplierId: 'supplier-filter',
        currencyId: 'currency-filter',
      );
      final finder = find.byType(MasterDataTableView<Map<String, dynamic>>);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      expect(table.items, hasLength(101));
      expect(table.items.last['paymentId'], 'advance-100');
      expect(table.totalPages, 1);
      expect(table.onPageChange, isNull);
      expect(api.reads.map((r) => r['size']), everyElement(100));
      expect(
        api.reads.map((r) => r['supplierId']),
        everyElement('supplier-filter'),
      );
      expect(
        api.reads.map((r) => r['currencyId']),
        everyElement('currency-filter'),
      );
      expect(
        api.reads.map((r) => r['page']).toList().sublist(api.reads.length - 2),
        [1, 2],
      );
      final reads = api.reads.length;
      await tester.drag(finder, const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(find.text('ADV-100'), findsOneWidget);
      expect(api.reads, hasLength(reads));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'both application and refund histories collect every original record',
    (tester) async {
      final api = _AdvanceApi()..settlementsTotal = 101;
      await _pump(tester, api);
      await _openRow(tester, 'ADV-001');
      final finder = find
          .byType(MasterDataTableView<Map<String, dynamic>>)
          .last;
      var table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      expect(table.items, hasLength(101));
      expect(table.items.last['id'], 'APPLICATION-100');
      final kind = tester.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '处理记录',
        ),
      );
      kind.onChanged('REFUND');
      await tester.pumpAndSettle();
      table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(finder);
      expect(table.items, hasLength(101));
      expect(table.items.last['id'], 'REFUND-100');
      expect(table.onPageChange, isNull);
      for (final kind in ['APPLICATION', 'REFUND']) {
        final reads = api.reads.where((r) => r['kind'] == kind).toList();
        expect(reads.map((r) => r['size']), everyElement(100));
        expect(reads.map((r) => r['page']).toList().sublist(reads.length - 2), [
          1,
          2,
        ]);
      }
      final reads = api.reads.length;
      await tester.drag(finder, const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(find.text('REFUND-100'), findsOneWidget);
      expect(api.reads, hasLength(reads));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed settlement continuation publishes no partial rows or writes',
    (tester) async {
      final api = _AdvanceApi()
        ..settlementsTotal = 101
        ..failSettlementPage = 2;
      await _pump(tester, api);
      await _openRow(tester, 'ADV-001');
      await _waitForReadError(
        tester,
        find.byType(MasterDataTableView<Map<String, dynamic>>).last,
      );
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>).last,
      );
      expect(table.items, isEmpty);
      expect(api.reads.any((query) => query['page'] == 2), isTrue);
      expect(table.error, '后批无权限');
      await tester.tap(
        find
            .descendant(
              of: find.byType(MasterDataTableView<Map<String, dynamic>>).last,
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
      expect(api.saves, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'advance reversal unknown response preserves the exact source command and prevents repeats while waiting',
    (tester) async {
      final api = _AdvanceApi()..loseFirst = true;
      await _pump(tester, api);
      await _openRow(tester, 'ADV-001');
      await _openRow(tester, '原应用依据');
      await tester.enterText(financeTextField('反审依据'), '按原应用逐笔撤回');
      await tester.tap(find.text('反审预付应用').last);
      await tester.pumpAndSettle();
      expect(api.saves, hasLength(1));
      expect(
        tester.widget<TextField>(financeTextField('反审依据')).enabled,
        isFalse,
      );
      await tester.tap(find.text('核对并重试原请求'));
      await tester.pumpAndSettle();
      expect(api.saves, hasLength(2));
      expect(api.saves.first, api.saves.last);
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow enlarged source table retains the existing action panel and unsaved refund inputs',
    (tester) async {
      final api = _AdvanceApi();
      await _pump(tester, api, width: 390, scale: 1.5);
      await _openRow(tester, 'ADV-001');
      await tapFinanceAction(tester, '登记实际退款');
      await tester.ensureVisible(financeTextField('实际退回原币总额'));
      await tester.enterText(
        financeTextField('实际退回原币总额'),
        '90071992547409.123456',
      );
      await tester.ensureVisible(financeTextField('来源依据'));
      await tester.enterText(financeTextField('来源依据'), '实际回单尚待核对');
      await tester.tap(find.text('登记实际退款').last);
      await tester.pumpAndSettle();
      expect(api.saves, isEmpty);
      expect(
        tester.widget<TextField>(financeTextField('实际退回原币总额')).controller!.text,
        '90071992547409.123456',
      );
      expect(
        tester.widget<TextField>(financeTextField('来源依据')).controller!.text,
        '实际回单尚待核对',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'capture real supplier advance table with anonymous guide sources',
    (tester) async {
      if (Platform.environment['FINANCE_CAPTURE_SCREENSHOTS'] != 'true') return;
      final noto = FontLoader('NotoSansSC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'));
      await noto.load();
      final iconsPath = Platform.environment['UTEN_MATERIAL_ICONS_FONT'];
      if (iconsPath != null) {
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            Future.value(
              ByteData.sublistView(File(iconsPath).readAsBytesSync()),
            ),
          );
        await icons.load();
      }
      final boundary = GlobalKey();
      await _pump(tester, _AdvanceApi(), boundary: boundary);
      await _openRow(tester, 'ADV-001');
      await tester.runAsync(() async {
        final rendered =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final picture = await rendered.toImage();
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        final file = File('output/finance-party/screenshots/供应商预付款-实际组件.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
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

Future<void> _openRow(WidgetTester tester, String label) async {
  final row = find.text(label).first;
  await tester.tap(row);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tap(row);
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _AdvanceApi api, {
  double width = 1400,
  double scale = 1,
  GlobalKey? boundary,
  String? supplierId,
  String? currencyId,
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
          Perm.supplierSettlementConfirm,
          Perm.financePaymentApprove,
          Perm.financeReceiptCreate,
          Perm.financeReceiptApprove,
          Perm.financeReceiptReverse,
        }),
      ],
      child: RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: buildLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showFinanceSupplierPrepaymentDialog(
                  context,
                  supplierId: supplierId,
                  currencyId: currencyId,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

class _AdvanceApi extends ApiClient {
  _AdvanceApi() : super(Dio());
  bool loseFirst = false;
  int actual = 0;
  final saves = <Map<String, dynamic>>[];
  int? directoryTotal, settlementsTotal, failSettlementPage, failDirectoryPage;
  final reads = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/supplier-prepayments') {
      if (directoryTotal case final total?) {
        if (query!['page'] == failDirectoryPage) {
          reads.add(Map<String, dynamic>.from(query));
          throw ApiException(
            'FORBIDDEN',
            '后批无权限',
            httpStatus: 403,
            hasResponseCode: true,
          );
        }
        return _paged(
          query,
          total,
          (i) => {
            'paymentId': 'advance-$i',
            'billNo': 'ADV-$i',
            'billDate': '2026-11-03',
            'supplierName': '实际供应商$i',
            'currencyCode': 'USD',
            'amountOriginal': '100.123456',
            'amountLocal': '700.654321',
            'status': 'OPEN',
          },
        );
      }
      return {
        'items': [
          {
            'paymentId': 'advance-1',
            'billNo': 'ADV-001',
            'billDate': '2026-11-03',
            'supplierCode': 'S-001',
            'supplierName': '匿名供应商（操作示例）',
            'currencyCode': 'USD',
            'amountOriginal': '100',
            'amountLocal': '700',
            'status': 'OPEN',
          },
        ],
        'totalPages': 1,
      };
    }
    if (path.endsWith('/settlements')) {
      if (settlementsTotal case final total?) {
        if (query!['page'] == failSettlementPage) {
          reads.add(Map<String, dynamic>.from(query));
          throw ApiException(
            'FORBIDDEN',
            '后批无权限',
            httpStatus: 403,
            hasResponseCode: true,
          );
        }
        return _paged(
          query,
          total,
          (i) => {
            'id': '${query['kind']}-$i',
            'created_at': '2026-11-03',
            'status': query['kind'] == 'REFUND' ? 'APPROVED' : 'APPLIED',
            'source_category': 'MOULD',
            'amount_original': '20.123456',
            'source_local': '140.654321',
            'target_local': '140.654321',
            'source_reference': '${query['kind']}-$i',
          },
        );
      }
      return {
        'items': [
          {
            'id': 'application-1',
            'created_at': '2026-11-03',
            'status': 'APPLIED',
            'source_category': 'MOULD',
            'amount_original': '20',
            'source_local': '140',
            'target_local': '140',
            'source_reference': '原应用依据',
          },
        ],
        'totalPages': 1,
      };
    }
    if (path == '/finance/supplier-prepayments/advance-1') {
      return {
        'payment_id': 'advance-1',
        'billNo': 'ADV-001',
        'supplierId': 'supplier-1',
        'currencyId': 'currency-usd',
        'currencyName': '美元',
        'amountOriginal': '100',
        'amountLocal': '700',
        'remainingOriginal': '80',
        'remainingLocal': '560',
        'parts': <Map<String, dynamic>>[],
        'status': 'OPEN',
      };
    }
    throw StateError('unexpected GET $path');
  }

  Map<String, dynamic> _paged(
    Map<String, dynamic> query,
    int total,
    Map<String, dynamic> Function(int) row,
  ) {
    reads.add(Map<String, dynamic>.from(query));
    final page = query['page'] as int, size = query['size'] as int;
    return {
      'items': [
        for (var i = (page - 1) * size; i < page * size && i < total; i++)
          row(i),
      ],
      'page': page,
      'size': size,
      'total': total,
      'totalPages': (total / size).ceil(),
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    saves.add({
      'path': path,
      'body': Map<String, dynamic>.from(body as Map<String, dynamic>),
    });
    if (actual == 0) actual++;
    if (loseFirst && saves.length == 1) throw NetworkTimeoutException();
    return {'status': 'REVERSED'};
  }
}
