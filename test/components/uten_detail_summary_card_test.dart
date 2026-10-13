import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_detail_summary_card.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import '../support/audit_screenshot_support.dart';

void main() {
  for (final pressure in [
    (const Size(320, 1100), 2.0, 2.0),
    (const Size(640, 320), 2.0, 2.0),
    (const Size(390, 900), 0.85, 1.0),
  ]) {
    testWidgets(
      'summary pressure $pressure keeps exact values, notice and real toggle',
      (tester) async {
        await loadAuditScreenshotFonts(tester);
        tester.view.physicalSize = pressure.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var noticeCalls = 0;
        final expandedEvents = <bool>[];
        const exactAmount = '123456789012.123456789 人民币';
        const exactQuantity = '9007199254740993.12345 个 · 1.2 千克';
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
                child: UtenDetailSummaryCard(
                  heading: const Text('完整长名称客户与原始销售单据 SO-20261013-001'),
                  status: const Text('等待财务复核与权限核实'),
                  primary: const [
                    UtenSummaryField(
                      label: '原始精确金额',
                      value: exactAmount,
                      emphasis: true,
                    ),
                  ],
                  facts: const [
                    UtenSummaryField(
                      label: '按原单位分组数量',
                      value: exactQuantity,
                      selectable: true,
                    ),
                    UtenSummaryField(label: '权限遮罩来源金额', value: '***'),
                    UtenSummaryField(label: '历史未核实金额'),
                  ],
                  details: const [
                    UtenSummaryField(
                      label: '原始来源版本与审批轨迹',
                      value: 'revision-20261013-001',
                    ),
                  ],
                  notices: [
                    TextButton(
                      key: const Key('summary-notice-action'),
                      onPressed: () => noticeCalls++,
                      child: const Text('重新核实来源与精确金额'),
                    ),
                  ],
                  onExpandedChanged: expandedEvents.add,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('detail-summary-toggle'));
        Future<void> reveal(Finder target) async {
          await Scrollable.ensureVisible(
            tester.element(target),
            alignment: 0.5,
          );
          await tester.pumpAndSettle();
        }

        await reveal(toggle);
        final rect = tester.getRect(toggle);
        expect(rect.width, greaterThanOrEqualTo(48 - 0.01));
        expect(rect.height, greaterThanOrEqualTo(48 - 0.01));
        expect(toggle.hitTestable(), findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(expandedEvents, [true]);
        expect(find.text('revision-20261013-001'), findsOneWidget);
        expect(find.text(exactAmount), findsOneWidget);
        expect(find.text(exactQuantity), findsOneWidget);
        expect(find.text('***'), findsOneWidget);
        expect(find.text('—'), findsOneWidget);
        await reveal(find.byKey(const Key('summary-notice-action')));
        await tester.tap(find.byKey(const Key('summary-notice-action')));
        expect(noticeCalls, 1);
        await reveal(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(expandedEvents, [true, false]);
        expect(find.text('revision-20261013-001'), findsNothing);
        expect(find.text(exactAmount), findsOneWidget);
        expect(find.byKey(const Key('summary-notice-action')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
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
