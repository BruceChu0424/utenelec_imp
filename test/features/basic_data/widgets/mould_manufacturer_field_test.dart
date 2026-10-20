import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_manufacturer_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/mould_manufacturer_field.dart';
import 'package:uten_imp/components/inputs/uten_month_field.dart';

class _Manufacturers extends MouldManufacturerRepository {
  _Manufacturers() : super(ApiClient(Dio()));
  final queries = <String>[];
  final gates = <String, Completer<List<String>>>{};
  List<String> history = ['历史制造商甲', '历史制造商乙'];
  @override
  Future<List<String>> suggestions(String keyword) async {
    queries.add(keyword);
    return gates[keyword]?.future ??
        (keyword.isEmpty ? history : ['$keyword 精确候选']);
  }
}

void main() {
  testWidgets('打开年月选择后不残留制造商候选，仍能自由输入与选择历史项', (tester) async {
    final repository = _Manufacturers()..history = const [];
    var manufacturer = '';
    var month = '2008-07';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mouldManufacturerRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 480,
              child: Column(
                children: [
                  MouldManufacturerField(
                    onChanged: (value) => manufacturer = value,
                  ),
                  UtenMonthField(
                    label: '制造年月',
                    value: month,
                    onChanged: (value) => month = value ?? '',
                  ),
                  const TextField(
                    key: Key('mould-test-place'),
                    decoration: InputDecoration(labelText: '存放位置'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final manufacturerInput = find.descendant(
      of: find.byType(MouldManufacturerField),
      matching: find.byType(TextField),
    );
    await tester.tap(manufacturerInput);
    await tester.pumpAndSettle();
    expect(find.text('暂无历史候选，可直接输入'), findsOneWidget);
    tester.widget<TextField>(manufacturerInput).focusNode!.unfocus();
    await tester.pumpAndSettle();
    expect(
      find.text('暂无历史候选，可直接输入'),
      findsNothing,
      reason: '程序化转移焦点也应关闭候选，不依赖外部指针点击',
    );
    await tester.tap(manufacturerInput);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择制造年月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('9月'));
    await tester.pumpAndSettle();
    expect(month, '2008-09');
    expect(find.text('暂无历史候选，可直接输入'), findsNothing, reason: '日期操作结束后旧候选不能遮住表单');
    await tester.enterText(find.byKey(const Key('mould-test-place')), 'A-03');
    repository.history = ['历史制造商甲', '历史制造商乙'];
    await tester.tap(manufacturerInput);
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史制造商乙'));
    await tester.pumpAndSettle();
    expect(manufacturer, '历史制造商乙');
    await tester.enterText(manufacturerInput, '自由录入制造商');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(manufacturer, '自由录入制造商');
    expect(
      tester.widget<TextField>(manufacturerInput).focusNode!.hasFocus,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('mould-test-place')));
    await tester.pumpAndSettle();
    expect(find.text('自由录入制造商 精确候选'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('空输入列历史候选，输入后查近似项，选择与自由输入均保留', (tester) async {
    final repository = _Manufacturers();
    var selected = '';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mouldManufacturerRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: MouldManufacturerField(
                onChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(repository.queries, contains(''));
    expect(find.text('历史制造商甲'), findsOneWidget);
    await tester.tap(find.text('历史制造商甲'));
    await tester.pumpAndSettle();
    expect(selected, '历史制造商甲');
    await tester.enterText(find.byType(TextField), '新厂');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(repository.queries.last, '新厂');
    expect(find.text('新厂 精确候选'), findsOneWidget);
    expect(selected, '新厂', reason: '自由输入也能保存，不强制选历史项');
    await tester.tap(find.text('新厂 精确候选'));
    await tester.pumpAndSettle();
    expect(selected, '新厂 精确候选');
    expect(tester.takeException(), isNull);
  });

  testWidgets('迟到的旧搜索不覆盖新候选，退出后不继续改状态', (tester) async {
    final repository = _Manufacturers()..gates['甲'] = Completer<List<String>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mouldManufacturerRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: MouldManufacturerField(onChanged: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '甲');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), '乙');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    repository.gates['甲']!.complete(['迟到的甲']);
    await tester.pumpAndSettle();
    expect(find.text('乙 精确候选'), findsOneWidget);
    expect(find.text('迟到的甲'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
