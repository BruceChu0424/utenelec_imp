import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/widgets/finance_native_debt_correspondence_dialog.dart';
import 'finance_requirement_test_ui.dart';

void main() {
  testWidgets(
    'original entry identity limits account choices and unknown save retains exact evidence',
    (tester) async {
      final api = _Api()..loseFirst = true;
      await _pump(tester, api);
      await _choose(tester, '原已记账分录', 'ORIG-001 原已记账科目');
      await _choose(tester, '对应财务科目', '2202 原应付科目');
      expect(find.text('2203 当前用途另一科目'), findsNothing);
      await tester.tap(find.text('选择原单的实际辅助对象'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OTHER-SUP'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('OTHER-SUP'));
      await tester.pumpAndSettle();
      expect(find.text('该辅助项目未对应原单的真实往来对象，请先维护正确关系。'), findsOneWidget);
      await tester.tap(find.text('选择原单的实际辅助对象'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ACTUAL-SUP'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('ACTUAL-SUP'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(financeTextField('原分录及辅助核对依据'));
      await tester.enterText(
        financeTextField('原分录及辅助核对依据'),
        '核对原真实凭证、原金额及实际供应商UUID',
      );
      await tester.tap(find.text('保存待审核核对'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(1));
      expect(
        tester.widget<TextField>(financeTextField('原分录及辅助核对依据')).enabled,
        isFalse,
      );
      await tester.tap(find.text('核对并重试原提交'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(2));
      expect(jsonEncode(api.saved.first), jsonEncode(api.saved.last));
      expect(api.saved.first['ledgerId'], 'actual-ledger');
      expect(api.saved.first['entryId'], 'original-entry');
      expect(api.saved.first['auxiliaryId'], 'actual-auxiliary');
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow enlarged evidence editor preserves source text and blocks incomplete save',
    (tester) async {
      final api = _Api();
      await _pump(tester, api, width: 390, scale: 1.5);
      await tester.tap(find.text('保存待审核核对'));
      await tester.pumpAndSettle();
      expect(find.text('请选择原分录、财务科目和实际辅助对象，填写核对依据。'), findsOneWidget);
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
    },
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
  double width = 1100,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
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
              onPressed: () => showFinanceNativeDebtCorrespondenceDialog(
                context,
                ledgerId: 'actual-ledger',
              ),
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
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/auxiliary-items') {
      return {
        'items': [
          {
            'id': 'wrong-auxiliary',
            'sourceCode': 'OTHER-SUP',
            'sourceName': '同名对象',
            'role': 'SUPPLIER',
            'partyId': 'other-supplier',
            'status': 'ACTIVE',
          },
          {
            'id': 'actual-auxiliary',
            'sourceCode': 'ACTUAL-SUP',
            'sourceName': '同名对象',
            'role': 'SUPPLIER',
            'partyId': 'actual-supplier',
            'status': 'ACTIVE',
          },
        ],
        'totalPages': 1,
      };
    }
    return {
      'sourceDocNo': 'RC-ORIGINAL',
      'partyRole': 'SUPPLIER',
      'partyId': 'actual-supplier',
      'originalCurrency': {'code': 'USD', 'name': '真实原币'},
      'amountOriginalText': '80.00000000000000000001',
      'amountLocalText': '560.00000000000000000007',
      'entries': [
        {
          'entryId': 'original-entry',
          'styleId': 'original-style',
          'voucherNo': 'ORIG-001',
          'styleName': '原已记账科目',
        },
      ],
      'reviews': actual == 0
          ? <Map<String, dynamic>>[]
          : [
              {
                'id': 'review-1',
                'status': 'DRAFT',
                'source_reference': '明确原分录核对依据',
              },
            ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [
    {
      'code': '2202',
      'name': '原应付科目',
      'style_id': 'original-style',
      'accounting_currency_id': 'book-base',
    },
    {
      'code': '2203',
      'name': '当前用途另一科目',
      'style_id': 'changed-role-style',
      'accounting_currency_id': 'book-base',
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
    return {'id': 'review-1'};
  }
}
