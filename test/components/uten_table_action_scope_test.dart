import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_date_range_button.dart';
import 'package:uten_imp/components/layout/uten_action_overflow.dart';
import 'package:uten_imp/components/layout/uten_table_action_scope.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final (platform, scale) in [
    (TargetPlatform.windows, 1.0),
    (TargetPlatform.windows, 2.0),
    (TargetPlatform.android, 1.0),
    (TargetPlatform.android, 2.0),
  ]) {
    testWidgets(
      'toolbar segments align with buttons on ${platform.name} at $scale',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        Widget segments(String name) => UtenSegmentRow<bool>(
          key: ValueKey(name),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('按产品看')),
            ButtonSegment(value: true, label: Text('按物料汇总')),
          ],
          selected: const {false},
          compactLabel: '视图',
          onSelectionChanged: (_) {},
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  segments('outside-segments'),
                  UtenTableActionScope(
                    child: Row(
                      children: [
                        UtenButton(
                          key: const ValueKey('matching-fullscreen'),
                          onPressed: () {},
                          child: const Text('全屏'),
                        ),
                        segments('toolbar-segments'),
                      ],
                    ),
                  ),
                  UtenTableActionScope(
                    child: SizedBox(
                      width: 110,
                      child: segments('compact-toolbar-segments'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final action = tester.getRect(
          find.byKey(const ValueKey('matching-fullscreen')),
        );
        final group = tester.getRect(
          find.byKey(const ValueKey('toolbar-segments')),
        );
        expect(group.height, action.height);
        expect(group.top, action.top);
        if (scale == 1) {
          expect(
            tester
                .getSize(find.byKey(const ValueKey('outside-segments')))
                .height,
            platform == TargetPlatform.windows ? 36 : 48,
          );
        }
        final compact = find.descendant(
          of: find.byKey(const ValueKey('compact-toolbar-segments')),
          matching: find.byType(OutlinedButton),
        );
        expect(compact, findsOneWidget);
        expect(
          tester.getSize(compact).height,
          greaterThanOrEqualTo(action.height),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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
    // 已选固定范围（10-01..10-31）显示紧凑文案「共31天」，不出现空态「选择日期」，
    // 也不显示原始日期串（2026-11-03 默认近月 + 紧凑显示契约）。
    expect(find.text('共31天'), findsOneWidget);
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

  test(
    'a held table action is still the action it wraps for overflow menus',
    () {
      expect(
        UtenActionOverflow.isAction(
          UtenTableActionGate(
            enabled: false,
            child: UtenButton(onPressed: () {}, child: const Text('批量处理')),
          ),
        ),
        isTrue,
      );
      expect(
        UtenActionOverflow.isAction(
          const UtenTableActionGate(enabled: true, child: Text('说明')),
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'a held action stays held inside a compact menu; once ready it acts and '
    'closes the menu like any menu action',
    (tester) async {
      tester.view.physicalSize = const Size(390, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ready = ValueNotifier(false);
      addTearDown(ready.dispose);
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: ValueListenableBuilder<bool>(
                valueListenable: ready,
                builder: (_, enabled, _) => UtenActionOverflow(
                  forceCompact: true,
                  children: [
                    UtenTableActionGate(
                      enabled: enabled,
                      child: TextButton(
                        onPressed: () => calls++,
                        child: const Text('批量处理'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('批量处理').hitTestable(), findsNothing);
      await tester.tap(find.text('批量处理'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      ready.value = true;
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量处理'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byKey(const ValueKey('uten-anchored-popup')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
