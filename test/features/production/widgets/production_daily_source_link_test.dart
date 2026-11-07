import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';

void main() {
  for (final (platform, viewport, actionExtent) in [
    (TargetPlatform.windows, const Size(900, 600), 32.0),
    (TargetPlatform.android, const Size(390, 600), 48.0),
  ]) {
    testWidgets('source code and all actions fit on ${platform.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final row = DailyGridRow()
        ..planId = 'plan-uuid'
        ..planItemId = 'plan-item-uuid'
        ..executionSegmentId = 'segment-uuid'
        ..executionSegmentCode = 'ZX00000148'
        ..planNo.text = 'SJ20260913000002';
      final grid = UtenEditableGridController<DailyGridRow>(initial: [row]);
      addTearDown(grid.dispose);
      final opened = <String>[];
      var picked = 0;
      var cleared = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final columns = dailyGridColumns(
                  context: context,
                  onPickGoods: (_) async {},
                  onPickSource: (_) async {
                    picked++;
                  },
                  onClearSource: (_) => cleared++,
                  colorEntries: const {},
                  unitEntries: const {},
                  onOpenSource: (source) async {
                    opened.add('${source.planId}/${source.executionSegmentId}');
                  },
                );
                expect(
                  columns.any((column) => column.key == 'isFinal'),
                  isFalse,
                );
                return UtenEditableGrid<DailyGridRow>(
                  controller: grid,
                  columns: [
                    columns.firstWhere((column) => column.key == 'planNo'),
                  ],
                  showAddRow: false,
                  showRowDelete: false,
                  showColumnSettings: false,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      void expectFullCode(String code) {
        final label = find.text(code);
        final paragraph = find.descendant(
          of: label,
          matching: find.byType(RichText),
        );
        expect(
          tester.renderObject<RenderParagraph>(paragraph).didExceedMaxLines,
          isFalse,
        );
        expect(
          tester.getRect(label).right,
          lessThanOrEqualTo(tester.getRect(find.byTooltip('重新选择来源子任务')).left),
        );
      }

      expectFullCode('ZX00000148');
      final picker = find.byTooltip('重新选择来源子任务');
      final clear = find.byTooltip('清除来源');
      for (final action in [picker, clear]) {
        expect(tester.getSize(action), Size.square(actionExtent));
        expect(action.hitTestable(), findsOneWidget);
      }
      await tester.tap(find.text('ZX00000148'));
      await tester.pump();
      expect(opened, ['plan-uuid/segment-uuid']);
      expect(picked, 0);
      await tester.tap(picker);
      expect(picked, 1);
      await tester.tap(clear);
      expect(cleared, 1);

      row.executionSegmentCode = 'ZX2026110700012345';
      row.planNo.text = 'SJ20261107000003';
      await tester.pumpAndSettle();
      expectFullCode('ZX2026110700012345');
      expect(tester.takeException(), isNull);
    });
  }
}
