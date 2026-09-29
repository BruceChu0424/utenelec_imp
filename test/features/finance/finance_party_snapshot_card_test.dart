import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/widgets/finance_party_snapshot_card.dart';
import 'package:uten_imp/shared/models/party_open_balance.dart';

/// ADR-128：三处审核页共用的往来单位财务快照卡。
Future<void> _pump(WidgetTester tester, Widget card) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: card)),
    ),
  );
}

Color? _color(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

void main() {
  const overCredit = PartyOpenBalance(
    currencyName: '美金',
    openOriginal: '500',
    creditOriginal: '100',
    netOriginal: '400',
    baseCurrencyName: '人民币',
    openBookLocal: '3500',
    creditLimitLocal: '3000',
    overLimitLocal: '500',
    overCredit: true,
    otherCurrencies: [
      PartyCurrencyBalance(currencyName: '人民币', netOriginal: '30000'),
    ],
  );

  testWidgets('客户卡：本单币种三格 + 额度三格，超额标红并出横幅，其它币种另列', (tester) async {
    await _pump(
      tester,
      const FinancePartySnapshotCard(
        title: '客户财务快照 · 远硕智能',
        balance: overCredit,
        leading: [FinanceSnapshotMetric('本单金额', '美金 144000.00', danger: true)],
        limitLabel: '信用额度',
        overLimitWarning: '已超信用额度',
      ),
    );

    expect(find.text('客户财务快照 · 远硕智能'), findsOneWidget);
    expect(find.text('美金 144000.00'), findsOneWidget);
    expect(find.text('应收未收'), findsOneWidget);
    expect(find.text('美金 500.00'), findsOneWidget);
    expect(find.text('可用预收'), findsOneWidget);
    expect(find.text('美金 100.00'), findsOneWidget);
    expect(find.text('还差多少'), findsOneWidget);
    expect(find.text('美金 400.00'), findsOneWidget);
    expect(find.text('全部币种应收(折本币)'), findsOneWidget);
    expect(find.text('人民币 3500.00'), findsOneWidget);
    expect(find.text('信用额度'), findsOneWidget);
    expect(find.text('人民币 3000.00'), findsOneWidget);
    expect(find.text('超出信用额度'), findsOneWidget);
    expect(find.text('人民币 500.00'), findsOneWidget);
    final error = Theme.of(
      tester.element(find.text('人民币 500.00')),
    ).colorScheme.error;
    expect(_color(tester, '人民币 3500.00'), error);
    expect(_color(tester, '人民币 500.00'), error);
    expect(
      find.byKey(const ValueKey('finance-party-snapshot-over-limit')),
      findsOneWidget,
    );
    expect(find.text('另有 人民币 30000.00'), findsOneWidget);
  });

  testWidgets('供应商卡：应付文案、可抵有余，不比额度也不出横幅', (tester) async {
    await _pump(
      tester,
      const FinancePartySnapshotCard(
        title: '供应商财务快照 · 丰翔',
        side: PartyBalanceSide.supplier,
        balance: PartyOpenBalance(
          currencyName: '人民币',
          openOriginal: '1100',
          creditOriginal: '1300',
          netOriginal: '-200',
          overCredit: true,
        ),
        overLimitWarning: '不应出现',
      ),
    );

    expect(find.text('应付未付'), findsOneWidget);
    expect(find.text('可抵预付/贷项'), findsOneWidget);
    expect(find.text('可抵有余 人民币 200.00'), findsOneWidget);
    expect(find.text('全部币种应付(折本币)'), findsNothing);
    expect(find.textContaining('额度'), findsNothing);
    expect(
      find.byKey(const ValueKey('finance-party-snapshot-over-limit')),
      findsNothing,
      reason: '横幅只在页面给了额度并且超额时出现',
    );
  });

  testWidgets('额度未设置显示「未设置」且不出超出额度格；缺视图时余额显示横线', (tester) async {
    await _pump(
      tester,
      const FinancePartySnapshotCard(
        title: '客户财务快照',
        balance: PartyOpenBalance(currencyName: '美金'),
        limitLabel: '信用额度',
      ),
    );
    expect(find.text('未设置'), findsOneWidget);
    expect(find.text('超出信用额度'), findsNothing);

    await _pump(
      tester,
      const FinancePartySnapshotCard(
        title: '客户财务快照',
        balance: null,
        limitLabel: '铺底额',
      ),
    );
    expect(find.text('—'), findsNWidgets(5));
  });
}
