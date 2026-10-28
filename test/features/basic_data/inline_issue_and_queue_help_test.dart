import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_issue_method_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/import_file_queue.dart';

void main() {
  for (final size in const [Size(390, 844), Size(1200, 900)]) {
    testWidgets(
      'issue method help stays inline without toggling recycled material at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: GoodsIssueMethodDialog(
                    detail: GoodsDetail(
                      id: 'material-1',
                      name: '颗粒',
                      issueMethod: GoodsIssueMethod.periodic,
                      periodicCostBasis: GoodsPeriodicCostBasis.own,
                      bulkPackageQty: 25,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        const recycling = '水口料、破碎料：交回仓库走其它入库，按 0 成本进仓';
        const allocation = '颗粒这类主料在 BOM 里填单个重量 (克)，按报工量分到各工单。';
        for (final help in [recycling, allocation]) {
          expect(find.text(help), findsNothing);
          final hint = find.byWidgetPredicate(
            (widget) => widget is UtenFieldHintIcon && widget.info == help,
          );
          await tester.ensureVisible(hint);
          await tester.tap(hint);
          await tester.pumpAndSettle();
          expect(find.text(help), findsOneWidget);
          expect(
            tester
                .widget<CheckboxListTile>(
                  find.byKey(const Key('goods-recycled-material')),
                )
                .value,
            isFalse,
          );
          Tooltip.dismissAllToolTips();
          await tester.pumpAndSettle();
        }
        final heading = tester.getRect(find.text('回收料'));
        final hint = tester.getRect(
          find.byWidgetPredicate(
            (widget) => widget is UtenFieldHintIcon && widget.info == recycling,
          ),
        );
        expect(hint.left, greaterThanOrEqualTo(heading.right));
        expect((hint.center.dy - heading.center.dy).abs(), lessThan(16));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'queue keeps actual progress pause and close consequences visible',
    (tester) async {
      final l = AppLocalizationsZh();
      final queue = ImportFileQueue()
        ..replacePending([
          PlatformFile(name: 'first.xlsx', size: 1),
          PlatformFile(name: 'second.xlsx', size: 1),
        ]);
      queue.succeed('2 行');
      queue.pause();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ImportFileQueueSummary(queue: queue)),
        ),
      );
      expect(find.text(l.importFilesTransactionNote), findsNothing);
      expect(find.text(l.importFilesCompleted(1, 2)), findsOneWidget);
      expect(
        find.text(l.importFilesCurrent(2, 2, 'second.xlsx')),
        findsOneWidget,
      );
      expect(find.text(l.importFilesPaused), findsOneWidget);
      expect(find.text(l.importFilesCloseNote), findsOneWidget);
      expect(
        find.text(l.importFilesOutcome('first.xlsx', '2 行')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
