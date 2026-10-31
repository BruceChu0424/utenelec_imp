import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/models/goods_detail_sequence.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_navigation.dart';

void main() {
  testWidgets('BOM navigation uses frozen UUID order and respects boundaries', (
    tester,
  ) async {
    final selected = <String>[];
    Future<void> pump(String id, {bool enabled = true}) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: GoodsBomNavigation(
              goodsId: id,
              categoryId: null,
              sequence: GoodsDetailSequence(['a', 'b', 'b', '', 'c']),
              enabled: enabled,
              onSelected: selected.add,
            ),
          ),
        ),
      ),
    );
    await pump('b');
    expect(find.text('当前页结果 2 / 3'), findsOneWidget);
    await tester.tap(find.byKey(const Key('goods-previous-bom')));
    await tester.tap(find.byKey(const Key('goods-next-bom')));
    expect(selected, ['a', 'c']);
    await pump('a');
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('goods-previous-bom')))
          .onPressed,
      isNull,
    );
    await pump('c');
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('goods-next-bom')))
          .onPressed,
      isNull,
    );
    await pump('b', enabled: false);
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('goods-next-bom')))
          .onPressed,
      isNull,
    );
    await pump('removed');
    expect(find.text('当前货品已不在来源结果中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
