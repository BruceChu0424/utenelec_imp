import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/pages/account_page.dart';

void main() {
  test('账户会计科目候选只保留使用中的 ACCOUNT 末级 UUID', () {
    final activeLeaf = PaymentStyleNode(
      id: 'style-active-leaf',
      code: '10201',
      name: '基本户',
      category: 'ACCOUNT',
      status: '使用',
      children: const [],
    );
    final disabledLeaf = PaymentStyleNode(
      id: 'style-disabled-leaf',
      code: '10202',
      name: '停用账户',
      category: 'ACCOUNT',
      status: '禁用',
      children: const [],
    );
    final wrongCategory = PaymentStyleNode(
      id: 'style-expense',
      code: '043',
      name: '费用',
      category: 'EXPENSE',
      status: '使用',
      children: const [],
    );
    final directory = PaymentStyleNode(
      id: 'style-directory',
      code: '102',
      name: '银行存款',
      category: 'ACCOUNT',
      status: '使用',
      children: [activeLeaf, disabledLeaf],
    );

    final result = activeAccountStyleLeaves([directory, wrongCategory]);

    expect(result.map((style) => style.id), ['style-active-leaf']);
  });

  testWidgets('会计科目加载失败显示原位错误并允许重试', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountStyleLoadNotice(
            loading: false,
            error: '会计科目加载失败，请重试',
            onRetry: () => retries++,
          ),
        ),
      ),
    );

    expect(find.text('会计科目加载失败，请重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retries, 1);
  });
}
