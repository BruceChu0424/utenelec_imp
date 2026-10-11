// 「统一设置条款」批量面板（commercial_terms_batch_sheet，2026-09 行级条款）：
// 一次写供应商+结账方式+币种+税率；留空的项保持原值（返回体对应字段为 null）；
// 全部留空时应用被拦截（面板不关闭）。汇率输入已撤（2026-10-10 口径：
// 采购/委外不填汇率，财务审批时填，前端提交恒 1）。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/widgets/commercial_terms_batch_sheet.dart';

/// 主档名称服务用空字典 ApiClient 覆盖（避免依赖 sharedPreferences）。
ApiClient _stubApi() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: const <dynamic>[],
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

void main() {
  testWidgets('填税率后应用，留空项返回 null（保持各行原值）', (tester) async {
    final portal = GlobalKey<_SheetHostState>();
    final api = _stubApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        ],
        child: MaterialApp(home: _SheetHost(key: portal)),
      ),
    );
    await portal.currentState!.openPanel(tester);

    expect(find.text('统一设置 2 行商业条款'), findsOneWidget);
    expect(find.textContaining('留空的项保持各行原值'), findsOneWidget);
    // 汇率输入已撤（2026-10-10 口径），面板不再出现汇率字段。
    expect(find.text('汇率'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, '税率(%)'), '13');
    await tester.tap(find.text('应用到选中行'));
    await tester.pumpAndSettle();

    final terms = await portal.currentState!.result;
    expect(terms, isNotNull);
    expect(terms!.supplierId, isNull);
    expect(terms.settlementMethodId, isNull);
    expect(terms.currencyId, isNull);
    expect(terms.exchangeRate, isNull);
    expect(terms.taxRate, 13);
  });

  testWidgets('全部留空时应用被拦截（面板不关闭）', (tester) async {
    final portal = GlobalKey<_SheetHostState>();
    final api = _stubApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        ],
        child: MaterialApp(home: _SheetHost(key: portal)),
      ),
    );
    await portal.currentState!.openPanel(tester);

    await tester.tap(find.text('应用到选中行'));
    await tester.pump();

    // 面板仍在（未 pop），结果未产生。
    expect(find.text('统一设置 2 行商业条款'), findsOneWidget);
    expect(portal.currentState!.hasResult, isFalse);
  });

  testWidgets('税率非法时应用被拦截', (tester) async {
    final portal = GlobalKey<_SheetHostState>();
    final api = _stubApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        ],
        child: MaterialApp(home: _SheetHost(key: portal)),
      ),
    );
    await portal.currentState!.openPanel(tester);

    await tester.enterText(find.widgetWithText(TextField, '税率(%)'), '101');
    await tester.tap(find.text('应用到选中行'));
    await tester.pump();

    expect(find.text('统一设置 2 行商业条款'), findsOneWidget);
    expect(portal.currentState!.hasResult, isFalse);
  });
}

class _SheetHost extends StatefulWidget {
  const _SheetHost({super.key});
  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  Completer<CommercialTermsBatchResult?>? _completer;

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();
  }

  Future<CommercialTermsBatchResult?> get result => _completer!.future;

  bool get hasResult => _completer?.isCompleted ?? false;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        return Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final completer = _completer =
                    Completer<CommercialTermsBatchResult?>();
                final result = await showCommercialTermsBatchSheet(
                  context,
                  ref,
                  selectedCount: 2,
                  currencyEntries: const {'cny': '人民币(CNY)'},
                  settlementEntries: const {'s1': '月结(NET30)'},
                );
                completer.complete(result);
              },
              child: const Text('打开面板'),
            ),
          ),
        );
      },
    );
  }
}
