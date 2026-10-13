import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/widgets/finance_party_snapshot_card.dart';
import 'package:uten_imp/shared/models/party_open_balance.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import '../../support/audit_screenshot_support.dart';

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
  for (final embedded in [false, true]) {
    for (final pressure in [
      (const Size(320, 1100), 2.0, 2.0),
      (const Size(640, 320), 2.0, 2.0),
      (const Size(390, 900), 0.85, 1.0),
    ]) {
      testWidgets(
        'party snapshot pressure embedded=$embedded $pressure preserves balances and footer',
        (tester) async {
          await loadAuditScreenshotFonts(tester);
          tester.view.physicalSize = pressure.$1;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var calls = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: auditScreenshotTheme(
                buildLightTheme(),
              ).copyWith(platform: TargetPlatform.android),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(pressure.$3)),
                child: UtenDisplayZoomBox(
                  fontFactor: pressure.$2,
                  child: UtenControlTheme(child: child!),
                ),
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: FinancePartySnapshotCard(
                    title: '完整长名称供应商与本单原币往来快照',
                    embedded: embedded,
                    expanded: false,
                    side: PartyBalanceSide.supplier,
                    balance: const PartyOpenBalance(
                      currencyName: '美金',
                      openOriginal: '123456789.1234',
                      creditOriginal: '123456999.1234',
                      netOriginal: '-210.0000',
                      baseCurrencyName: '人民币',
                      openBookLocal: '20000',
                      creditLimitLocal: '15000',
                      overLimitLocal: '5000',
                      overCredit: true,
                      unverifiedLocal: '2000',
                      unverifiedCount: 1,
                      otherCurrencies: [
                        PartyCurrencyBalance(
                          currencyName: '欧元',
                          netOriginal: '999.1234',
                        ),
                      ],
                    ),
                    leading: const [
                      FinanceSnapshotMetric(
                        '精确来源金额及原始币种',
                        '987654321.123456789 美金',
                      ),
                    ],
                    limitLabel: '铺底额',
                    overLimitWarning: '已超铺底额，需要重新核实原始来源',
                    footer: [
                      TextButton(
                        key: const Key('party-footer-action'),
                        onPressed: () => calls++,
                        child: const Text('查看本单原始来源与审批记录'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('987654321.123456789 美金'), findsOneWidget);
          expect(find.text('123456789.1234 美金'), findsOneWidget);
          expect(find.text('123456999.1234 美金'), findsOneWidget);
          expect(find.textContaining('可抵有余'), findsOneWidget);
          expect(find.textContaining('210.00'), findsOneWidget);
          expect(find.textContaining('原币未核实'), findsOneWidget);
          final footnote = find.byKey(
            const ValueKey('finance-party-snapshot-footnote'),
          );
          expect(footnote, findsOneWidget);
          expect(
            tester.widget<Text>(footnote).data,
            '另有 999.1234 欧元；另有历史应付 2000.00 元 原币未核实',
          );
          expect(
            find.byKey(const ValueKey('finance-party-snapshot-over-limit')),
            findsOneWidget,
          );
          final action = find.byKey(const Key('party-footer-action'));
          await Scrollable.ensureVisible(
            tester.element(action),
            alignment: 0.5,
          );
          await tester.pumpAndSettle();
          expect(action.hitTestable(), findsOneWidget);
          final actionRect = tester.getRect(action);
          expect(actionRect.width, greaterThanOrEqualTo(48 - 0.05));
          expect(actionRect.height, greaterThanOrEqualTo(48 - 0.05));
          await tester.tap(action);
          expect(calls, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'embedded customer balances remain distinct when credit details are folded',
    (tester) async {
      await _pump(
        tester,
        const FinancePartySnapshotCard(
          title: '客户往来',
          embedded: true,
          expanded: false,
          balance: PartyOpenBalance(
            currencyName: '人民币',
            openOriginal: '15000',
            creditOriginal: '4000',
            netOriginal: '11000',
            baseCurrencyName: '人民币',
            openBookLocal: '15000',
            creditLimitLocal: '10000',
            overLimitLocal: '5000',
            overCredit: true,
            unverifiedLocal: '2000',
            unverifiedCount: 1,
          ),
          limitLabel: '信用额度',
          overLimitWarning: '已超信用额度',
          footer: [Text('本次放行记账汇率必填')],
        ),
      );
      expect(find.byType(Card), findsNothing);
      expect(find.text('应收未收'), findsOneWidget);
      expect(find.text('15000.00 人民币'), findsOneWidget);
      expect(find.text('可用预收'), findsOneWidget);
      expect(find.text('4000.00 人民币'), findsOneWidget);
      expect(find.text('还差多少'), findsOneWidget);
      expect(find.text('11000.00 人民币'), findsOneWidget);
      expect(find.textContaining('已超信用额度'), findsOneWidget);
      expect(find.textContaining('原币未核实'), findsOneWidget);
      expect(find.text('本次放行记账汇率必填'), findsOneWidget);
    },
  );

  testWidgets(
    'embedded surplus and missing balances never become a fictitious debt',
    (tester) async {
      await _pump(
        tester,
        const FinancePartySnapshotCard(
          title: '供应商往来',
          embedded: true,
          expanded: false,
          side: PartyBalanceSide.supplier,
          balance: PartyOpenBalance(
            currencyName: '美金',
            netOriginal: '-123.4567',
          ),
        ),
      );
      expect(find.text('可抵有余'), findsOneWidget);
      expect(find.text('123.4567 美金'), findsOneWidget);
      await _pump(
        tester,
        const FinancePartySnapshotCard(
          title: '客户往来',
          embedded: true,
          expanded: false,
          balance: null,
        ),
      );
      expect(find.text('—'), findsNWidgets(3));
      expect(find.text('0.00'), findsNothing);
    },
  );

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
    expect(find.text('500.00 美金'), findsOneWidget);
    expect(find.text('可用预收'), findsOneWidget);
    expect(find.text('100.00 美金'), findsOneWidget);
    expect(find.text('还差多少'), findsOneWidget);
    expect(find.text('400.00 美金'), findsOneWidget);
    expect(find.text('全部币种应收(折本币)'), findsOneWidget);
    expect(find.text('3500.00 元'), findsOneWidget);
    expect(find.text('信用额度'), findsOneWidget);
    expect(find.text('3000.00 元'), findsOneWidget);
    expect(find.text('超出信用额度'), findsOneWidget);
    expect(find.text('500.00 元'), findsOneWidget);
    final error = Theme.of(
      tester.element(find.text('500.00 元')),
    ).colorScheme.error;
    expect(_color(tester, '3500.00 元'), error);
    expect(_color(tester, '500.00 元'), error);
    expect(
      find.byKey(const ValueKey('finance-party-snapshot-over-limit')),
      findsOneWidget,
    );
    expect(find.text('另有 30000.00 元'), findsOneWidget);
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
    expect(find.text('可抵有余 200.00 元'), findsOneWidget);
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
