import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/features/production/widgets/production_report_surplus_return_dialog.dart';

const _steel = SurplusReturnCandidate(
  demandId: 'steel',
  goodsName: '钢管',
  colorName: '银色',
  availableToSettleQty: 10,
  estimatedLeftoverQty: 4,
  unitName: '千克',
);
const _screw = SurplusReturnCandidate(
  demandId: 'screw',
  goodsName: '螺丝',
  availableToSettleQty: 30,
  estimatedLeftoverQty: 0,
  unitName: '个',
  segmentLabel: 'ZX-001',
  undrawnDirectLotQty: 12.5,
);

void main() {
  group('countedLeftoverIssue', () {
    test('accepts 0, the full available quantity and up to 4 decimals', () {
      expect(countedLeftoverIssue('0', 10), isNull);
      expect(countedLeftoverIssue('10', 10), isNull);
      expect(countedLeftoverIssue(' 2.5 ', 10), isNull);
      expect(countedLeftoverIssue('.1234', 10), isNull);
      expect(countedLeftoverIssue('9.9999', 10), isNull);
    });

    test('rejects empty, negative, over-precise and more than available', () {
      expect(countedLeftoverIssue('', 10), contains('用完了填 0'));
      expect(countedLeftoverIssue('-1', 10), contains('不小于 0'));
      expect(countedLeftoverIssue('1.23456', 10), contains('最多 4 位小数'));
      expect(countedLeftoverIssue('abc', 10), contains('最多 4 位小数'));
      final over = countedLeftoverIssue('10.0001', 10);
      expect(over, contains('不能超过账面可用 10'));
      expect(over, contains('核对用料'));
    });
  });

  test('closeOutDifference rounds to 4 decimals and never goes negative', () {
    expect(closeOutDifference(0.3, 0.1), 0.2);
    expect(closeOutDifference(10, 3.3333), 6.6667);
    expect(closeOutDifference(5, 7), 0);
    expect(closeOutDifference(5, 5), 0);
  });

  test('applySurplusCounts rewrites counted lines and keeps the rest', () {
    const extra = SurplusReturnCandidate(
      demandId: 'extra',
      goodsName: '胶水',
      availableToSettleQty: 4,
      estimatedLeftoverQty: 4,
      unitName: '瓶',
    );
    final lines = applySurplusCounts(
      [
        {'demandId': 'steel', 'qtyBase': 6.0},
        {'demandId': 'hidden', 'qtyBase': 2.0},
        {'demandId': 'other', 'qtyBase': 1.0},
      ],
      candidates: const [_steel, extra],
      counted: const {'steel': 3, 'extra': 1.25},
      savedCounted: const {'hidden': 1.5, 'missing': 9},
    );
    expect(lines, [
      {'demandId': 'steel', 'qtyBase': 7.0, 'countedLeftoverQty': 3.0},
      {'demandId': 'hidden', 'qtyBase': 2.0, 'countedLeftoverQty': 1.5},
      {'demandId': 'other', 'qtyBase': 1.0},
      // 清点过却没有用料行的需求补一行，页面与服务端审核同一口径。
      {'demandId': 'extra', 'qtyBase': 2.75, 'countedLeftoverQty': 1.25},
    ]);
  });

  group('dialog', () {
    Future<List<SurplusReturnResult?>> open(WidgetTester tester) async {
      final results = <SurplusReturnResult?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => results.add(
                  await showProductionReportSurplusReturnDialog(
                    context,
                    candidates: const [_steel, _screw],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    Finder field(String demandId) =>
        find.byKey(ValueKey('report-surplus-counted-$demandId'));

    String text(WidgetTester tester, String demandId) => tester
        .widget<TextField>(
          find.descendant(
            of: field(demandId),
            matching: find.byType(TextField),
          ),
        )
        .controller!
        .text;

    UtenButton confirm(WidgetTester tester) => tester.widget<UtenButton>(
      find.byKey(const Key('report-surplus-return-confirm')),
    );

    Iterable<String?> errors(WidgetTester tester) => tester
        .widgetList<UtenFieldHintIcon>(find.byType(UtenFieldHintIcon))
        .map((icon) => icon.errorMessage)
        .whereType<String>();

    testWidgets('prefills the paper estimate and shows the book quantity', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('清点剩余物料'), findsOneWidget);
      expect(text(tester, 'steel'), '4');
      // 纸面上用完了也要清点：预填 0，不跳过。
      expect(text(tester, 'screw'), '0');
      expect(find.text('账面可用 10 千克'), findsOneWidget);
      expect(find.text('账面可用 30 个'), findsOneWidget);
      expect(find.text('钢管 · 银色'), findsOneWidget);
      expect(find.text('螺丝(ZX-001)'), findsOneWidget);
      expect(find.textContaining('按实物清点填写还剩多少'), findsOneWidget);
      // 未领直送料不算账面可用、不计入实际剩余，退回仓库时一并退回(ADR-129 §2.7)。
      expect(find.textContaining('退仓数量 = 实际剩余 + 未领直送料'), findsOneWidget);
      // 有未领直送料的物料逐条说明数量；没有的不显示。
      expect(find.text('另有未领直送料 12.5 个，退回仓库时一并退回，不要计入实际剩余'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('report-surplus-direct-lot-steel')),
        findsNothing,
      );
      expect(find.text('留在车间'), findsOneWidget);
      expect(confirm(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('blocks more than available, too many decimals and empty', (
      tester,
    ) async {
      final results = await open(tester);
      await tester.enterText(field('steel'), '12');
      await tester.pump();
      expect(confirm(tester).onPressed, isNull);
      expect(errors(tester).single, contains('不能超过账面可用 10'));

      // 第 5 位小数的按键被拒，保留原值而不是截成别的数。
      await tester.enterText(field('steel'), '2.5');
      await tester.pump();
      await tester.enterText(field('steel'), '2.12345');
      await tester.pump();
      expect(text(tester, 'steel'), '2.5');
      expect(confirm(tester).onPressed, isNotNull);

      await tester.enterText(field('steel'), '');
      await tester.pump();
      expect(confirm(tester).onPressed, isNull);
      // 空格先只描红框，点了灰按钮才说原因。
      expect(errors(tester), isEmpty);
      await tester.tap(find.byKey(const Key('report-surplus-return-confirm')));
      await tester.pump();
      expect(errors(tester).single, contains('用完了填 0'));
      expect(results, isEmpty);
      expect(find.text('清点剩余物料'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('returning to the warehouse carries every counted quantity', (
      tester,
    ) async {
      final results = await open(tester);
      await tester.enterText(field('steel'), '3.25');
      await tester.enterText(field('screw'), '30');
      await tester.pump();
      await tester.tap(find.byKey(const Key('report-surplus-return-confirm')));
      await tester.pumpAndSettle();
      final result = results.single!;
      expect(result.returnToWarehouse, isTrue);
      expect(result.countedByDemandId, {'steel': 3.25, 'screw': 30.0});
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeping in the workshop carries no counted quantity', (
      tester,
    ) async {
      final results = await open(tester);
      await tester.enterText(field('steel'), '1');
      await tester.tap(find.text('留在车间'));
      await tester.pumpAndSettle();
      final result = results.single!;
      expect(result.returnToWarehouse, isFalse);
      expect(result.countedByDemandId, isEmpty);
    });

    testWidgets('closing the dialog chooses nothing', (tester) async {
      final results = await open(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(results, [null]);
    });
  });
}
