import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_detail_summary_card.dart';

void main() {
  testWidgets(
    'folding secondary facts never hides the warning or primary amount',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtenDetailSummaryCard(
              heading: Text('SO-001'),
              primary: [UtenSummaryField(label: '本单金额', value: '12800.00 人民币')],
              details: [UtenSummaryField(label: '合同号', value: 'HT-001')],
              notices: [Text('已超信用额度，请谨慎确认')],
            ),
          ),
        ),
      );
      expect(find.text('HT-001'), findsNothing);
      expect(find.text('12800.00 人民币'), findsOneWidget);
      expect(find.text('已超信用额度，请谨慎确认'), findsOneWidget);
      await tester.tap(find.text('查看更多'));
      await tester.pumpAndSettle();
      expect(find.text('HT-001'), findsOneWidget);
      await tester.tap(find.text('收起信息'));
      await tester.pumpAndSettle();
      expect(find.text('HT-001'), findsNothing);
      expect(find.text('已超信用额度，请谨慎确认'), findsOneWidget);
    },
  );

  testWidgets(
    'different document identities start with secondary information folded',
    (tester) async {
      Widget page(String id) => MaterialApp(
        home: Scaffold(
          body: UtenDetailSummaryCard(
            key: ValueKey(id),
            heading: Text(id),
            details: const [Text('审计时间')],
          ),
        ),
      );
      await tester.pumpWidget(page('first'));
      await tester.tap(find.text('查看更多'));
      await tester.pumpAndSettle();
      expect(find.text('审计时间'), findsOneWidget);
      await tester.pumpWidget(page('second'));
      expect(find.text('审计时间'), findsNothing);
    },
  );

  for (final width in [320.0, 768.0, 1440.0]) {
    testWidgets(
      'long identity and exact amounts fit at $width with large text',
      (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 1200),
                textScaler: const TextScaler.linear(2),
              ),
              child: const Scaffold(
                body: SingleChildScrollView(
                  child: UtenDetailSummaryCard(
                    heading: Text('客户名称很长且必须完整显示的销售订货单 SO-20261013-018'),
                    status: Text('待财务确认'),
                    primary: [
                      UtenSummaryField(
                        label: '本单金额',
                        value: '123456789012.1234 美金',
                      ),
                      UtenSummaryField(label: '交货日', value: '2026-10-25'),
                    ],
                    facts: [
                      UtenSummaryField(label: '来源金额', value: '***'),
                      UtenSummaryField(label: '历史未知金额'),
                    ],
                    details: [Text('补充信息')],
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('123456789012.1234 美金'), findsOneWidget);
        expect(find.text('***'), findsOneWidget);
        expect(find.text('—'), findsOneWidget);
      },
    );
  }
}
