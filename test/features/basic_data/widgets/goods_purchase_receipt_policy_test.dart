// ADR-144 货品主档「采购」区的采购允许超收%：
//  - 输入解析：空 = 清除记忆；0..100 最多两位小数；
//  - 查看格：未设说明不允许超收；没有编辑能力不出修改按钮；
//  - 弹窗只经专用接口保存这一个值 (带乐观锁版本)，不合法不发请求。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_purchase_receipt_policy_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_purchase_receipt_policy_field.dart';

class _PolicyRepository implements GoodsPurchaseReceiptPolicyRepository {
  final calls = <({String goodsId, double? pct, int version})>[];

  @override
  Future<void> update(
    String goodsId, {
    required double? pct,
    required int version,
  }) async {
    calls.add((goodsId: goodsId, pct: pct, version: version));
  }
}

const _detail = GoodsDetail(
  id: 'goods-1',
  code: 'G-001',
  name: '铜线',
  version: 4,
  purchaseAllowedOverReceiptPct: 5,
);

Future<({_PolicyRepository repo, List<bool> results})> _pumpHost(
  WidgetTester tester, {
  GoodsDetail detail = _detail,
}) async {
  final repo = _PolicyRepository();
  final results = <bool>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsPurchaseReceiptPolicyRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(
                await showGoodsPurchaseReceiptPolicyDialog(
                  context,
                  detail: detail,
                ),
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
  return (repo: repo, results: results);
}

Finder _input() => find.descendant(
  of: find.byKey(const ValueKey('goods-purchase-over-receipt-input')),
  matching: find.byType(TextFormField),
);

void main() {
  test('输入解析', () {
    expect(parseGoodsPurchaseOverReceiptPct(' '), (value: null, valid: true));
    expect(parseGoodsPurchaseOverReceiptPct('5'), (value: 5.0, valid: true));
    expect(parseGoodsPurchaseOverReceiptPct('12.5'), (
      value: 12.5,
      valid: true,
    ));
    expect(parseGoodsPurchaseOverReceiptPct('100.01').valid, isFalse);
    expect(parseGoodsPurchaseOverReceiptPct('1.234').valid, isFalse);
    expect(parseGoodsPurchaseOverReceiptPct('-1').valid, isFalse);
  });

  test('显示文字', () {
    expect(goodsPurchaseOverReceiptText(null), '未设(不允许超收)');
    expect(goodsPurchaseOverReceiptText(5), '5%');
    expect(goodsPurchaseOverReceiptText(2.5), '2.5%');
  });

  testWidgets('查看格：没有编辑能力不出修改按钮', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: GoodsPurchaseOverReceiptViewCell(pct: null)),
      ),
    );
    expect(find.text('采购允许超收%'), findsOneWidget);
    expect(find.text('未设(不允许超收)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('goods-purchase-over-receipt-edit')),
      findsNothing,
    );
  });

  testWidgets('弹窗保存比例带版本，成功后要求宿主重载', (tester) async {
    final host = await _pumpHost(tester);
    expect(tester.widget<TextFormField>(_input()).controller!.text, '5');
    await tester.enterText(_input(), '7.5');
    await tester.tap(
      find.byKey(const ValueKey('goods-purchase-over-receipt-save')),
    );
    await tester.pumpAndSettle();
    expect(host.repo.calls, [(goodsId: 'goods-1', pct: 7.5, version: 4)]);
    expect(host.results, [true]);
  });

  testWidgets('留空清除记忆', (tester) async {
    final host = await _pumpHost(tester);
    await tester.enterText(_input(), '');
    await tester.tap(
      find.byKey(const ValueKey('goods-purchase-over-receipt-save')),
    );
    await tester.pumpAndSettle();
    expect(host.repo.calls.single.pct, isNull);
  });

  testWidgets('超过 100 不发请求并提示', (tester) async {
    final host = await _pumpHost(tester);
    await tester.enterText(_input(), '120');
    await tester.tap(
      find.byKey(const ValueKey('goods-purchase-over-receipt-save')),
    );
    await tester.pumpAndSettle();
    expect(host.repo.calls, isEmpty);
    // 字段错误收进输入框内的提示图标(UtenInputDecoration)，按提示文案找。
    expect(find.byTooltip('请填写 0 到 100 之间的数，最多两位小数；留空表示不预填'), findsOneWidget);
    expect(host.results, isEmpty, reason: '弹窗仍开着');
  });
}
