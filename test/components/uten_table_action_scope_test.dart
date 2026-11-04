import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_date_range_button.dart';
import 'package:uten_imp/components/layout/uten_table_action_scope.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  testWidgets('表格动作统一40高，日期只显示入口，格内小按钮保留36高', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: MasterDataTableView<String>(
            columns: [
              MasterColumnDef<String>(
                key: 'value',
                label: '明细',
                width: 200,
                value: (row) => row,
                cellBuilder: (_, _) => UtenButton(
                  key: const Key('cell-button'),
                  size: UtenButtonSize.small,
                  onPressed: () {},
                  child: const Text('格内操作'),
                ),
              ),
            ],
            items: const ['测试行'],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            toolbarActions: [
              UtenDateRangeButton(
                buttonKey: const Key('date-button'),
                range: DateTimeRange(
                  start: DateTime(2026, 10),
                  end: DateTime(2026, 10, 31),
                ),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                onChanged: (_) {},
              ),
              UtenButton(
                key: const Key('print-button'),
                size: UtenButtonSize.large,
                type: UtenButtonType.secondary,
                onPressed: () {},
                child: const Text('预览打印'),
              ),
              UtenButton(
                key: const Key('download-button'),
                size: UtenButtonSize.small,
                onPressed: () {},
                child: const Text('下载表格'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rects = [
      for (final key in ['date-button', 'print-button', 'download-button'])
        tester.getRect(find.byKey(Key(key))),
    ];
    for (final rect in rects) {
      expect(rect.height, 40);
      expect(rect.center.dy, rects.first.center.dy);
    }
    expect(tester.getSize(find.byKey(const Key('cell-button'))).height, 36);
    expect(find.text('选择日期'), findsOneWidget);
    expect(find.textContaining('2026-10'), findsNothing);
    expect(
      find.ancestor(
        of: find.byKey(const Key('date-button')),
        matching: find.byType(UtenTableActionScope),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
