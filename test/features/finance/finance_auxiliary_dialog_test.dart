import 'finance_requirement_test_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/widgets/finance_auxiliary_dialog.dart';

void main() {
  testWidgets(
    'unknown save keeps exact source identity and retries one auxiliary',
    (tester) async {
      final api = _AuxiliaryApi()..loseFirst = true;
      await _pump(tester, api);
      await tapFinanceAction(tester, '添加');
      await tester.pumpAndSettle();
      await tester.enterText(financeTextField('来源账套'), '原账套');
      await tester.enterText(financeTextField('原项目编号'), '00017');
      await tester.enterText(financeTextField('原项目名称'), '原客户');
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(api.saves, hasLength(1));
      expect(
        tester.widget<TextField>(financeTextField('原项目编号')).enabled,
        isFalse,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('核对并重试原提交'));
      await tester.pumpAndSettle();
      expect(api.saves, hasLength(2));
      expect(api.saves.first, api.saves.last);
      expect(api.saves.first['sourceCode'], '00017');
      expect(api.actual, 1);
      expect(find.text('00017'), findsOneWidget);
      expect(find.text('原客户'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'definite rejection preserves input and permits correcting the original code',
    (tester) async {
      final api = _AuxiliaryApi()..reject = true;
      await _pump(tester, api);
      await tapFinanceAction(tester, '添加');
      await tester.pumpAndSettle();
      await tester.enterText(financeTextField('来源账套'), '原账套');
      await tester.enterText(financeTextField('原项目编号'), '00017');
      await tester.enterText(financeTextField('原项目名称'), '原客户');
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(financeTextField('原项目编号'));
      expect(field.enabled, isTrue);
      expect(field.controller?.text, '00017');
      expect(find.text('核对并重试原提交'), findsNothing);
      expect(api.actual, 0);
    },
  );
  testWidgets(
    'directory pages and exact identities remain available on narrow enlarged text',
    (tester) async {
      final api = _AuxiliaryApi()..actual = 1;
      await _pump(tester, api, width: 390, scale: 1.5);
      expect(find.text('00017'), findsOneWidget);
      expect(find.text('原客户'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _AuxiliaryApi api, {
  double width = 1400,
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
              onPressed: () =>
                  showFinanceAuxiliaryPicker(context, canEdit: true),
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

class _AuxiliaryApi extends ApiClient {
  _AuxiliaryApi() : super(Dio());
  bool loseFirst = false, reject = false;
  int actual = 0;
  final saves = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'items': [
      if (actual > 0)
        {
          'id': 'aux-1',
          'sourceSystem': '原账套',
          'sourceCode': '00017',
          'sourceName': '原客户',
          'role': 'CUSTOMER',
          'status': 'ACTIVE',
          'version': 0,
        },
    ],
    'page': 1,
    'totalPages': 1,
    'total': actual,
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    saves.add(Map<String, dynamic>.from(body as Map));
    if (reject) {
      throw ApiException(
        'VALIDATION_FAILED',
        '请核对原编号',
        httpStatus: 422,
        hasResponseCode: true,
      );
    }
    actual = 1;
    if (loseFirst && saves.length == 1) throw NetworkTimeoutException();
    return {'id': 'aux-1'};
  }
}
