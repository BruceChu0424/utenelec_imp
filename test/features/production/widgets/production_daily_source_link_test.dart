import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';

void main() {
  testWidgets(
    'source displays one task code and opens its UUID while source changes stay explicit',
    (tester) async {
      final row = DailyGridRow()
        ..planId = 'plan-uuid'
        ..planItemId = 'plan-item-uuid'
        ..executionSegmentId = 'segment-uuid'
        ..executionSegmentCode = 'ZX00000148'
        ..planNo.text = 'SJ20260913000002';
      addTearDown(row.dispose);
      final opened = <String>[];
      var picked = 0;
      await tester.pumpWidget(
        MaterialApp(
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
                  onClearSource: (_) {},
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
                return SizedBox(
                  width: 300,
                  child: columns
                      .firstWhere((column) => column.key == 'planNo')
                      .cellBuilder(context, row),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('ZX00000148'));
      await tester.pump();
      expect(opened, ['plan-uuid/segment-uuid']);
      expect(picked, 0);
      expect(tester.widget<Text>(find.text('ZX00000148')).maxLines, 1);
      await tester.tap(find.byTooltip('重新选择来源子任务'));
      expect(picked, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
