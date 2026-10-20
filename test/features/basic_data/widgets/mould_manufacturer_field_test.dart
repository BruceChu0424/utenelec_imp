import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_manufacturer_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/mould_manufacturer_field.dart';

class _Manufacturers extends MouldManufacturerRepository {
  _Manufacturers() : super(ApiClient(Dio()));
  final queries = <String>[];
  final gates = <String, Completer<List<String>>>{};
  @override
  Future<List<String>> suggestions(String keyword) async {
    queries.add(keyword);
    return gates[keyword]?.future ??
        (keyword.isEmpty ? ['历史制造商甲', '历史制造商乙'] : ['$keyword 精确候选']);
  }
}

void main() {
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
