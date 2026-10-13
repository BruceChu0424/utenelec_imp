import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_info_row.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/layout/uten_form_grid.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/components/layout/uten_responsive_grid.dart';
import 'package:uten_imp/components/layout/uten_section_header.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/ui/capsule_nav_metrics.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/widgets/material_supply_submit_confirm.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(320, 800),
  double systemText = 1,
  double zoom = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, body) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(systemText)),
          child: UtenDisplayZoomBox(fontFactor: zoom, child: body!),
        ),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'history range retains complete dates on the narrow scaled canvas',
    (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: UtenHistoryTimeFilter(
              value: UtenHistoryTimeValue.range(
                DateTimeRange(
                  start: DateTime.utc(2024),
                  end: DateTime.utc(2024, 10, 13),
                ),
              ),
              onChanged: (_) {},
            ),
          ),
        ),
        zoom: 2,
      );
      expect(find.textContaining('2024-01-01'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('detail labels and section actions reflow on a 160dp canvas', (
    tester,
  ) async {
    await _pump(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              const UtenInfoRow(label: '本次待安排生产数量', value: '123456789.1234 个'),
              UtenSectionHeader(
                title: '物料分析与车间下达明细',
                trailing: TextButton(
                  onPressed: () {},
                  child: const Text('查看完整明细'),
                ),
              ),
            ],
          ),
        ),
      ),
      zoom: 2,
    );
    final label = tester.getTopLeft(find.text('本次待安排生产数量'));
    final value = tester.getTopLeft(find.text('123456789.1234 个'));
    expect(value.dy, greaterThan(label.dy));
    expect(
      tester.getTopLeft(find.text('查看完整明细')).dy,
      greaterThan(tester.getTopLeft(find.text('物料分析与车间下达明细')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit form columns yield to large system text', (
    tester,
  ) async {
    await _pump(
      tester,
      const Scaffold(
        body: UtenFormGrid(
          columns: 6,
          children: [
            SizedBox(key: Key('field-a'), height: 48),
            SizedBox(key: Key('field-b'), height: 48),
          ],
        ),
      ),
      size: const Size(600, 800),
      systemText: 2,
    );
    expect(tester.getSize(find.byKey(const Key('field-a'))).width, 600);
    expect(
      tester.getTopLeft(find.byKey(const Key('field-b'))).dy,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'card grid reduces columns for system text and reports inner width',
    (tester) async {
      final widths = <double>[];
      await _pump(
        tester,
        Scaffold(
          body: UtenResponsiveGrid(
            itemCount: 2,
            padding: const EdgeInsets.all(16),
            itemBuilder: (_, index, width) {
              widths.add(width);
              return SizedBox(key: Key('card-$index'), height: 80);
            },
          ),
        ),
        size: const Size(700, 800),
        systemText: 2,
      );
      expect(widths, everyElement(668));
      expect(tester.getSize(find.byKey(const Key('card-0'))).width, 668);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'picker summary remains complete and confirmation still commits once',
    (tester) async {
      var commits = 0;
      await _pump(
        tester,
        Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: UtenPickerConfirmBar(
              selectedCount: 12,
              selectedLabel: '采购与生产共同使用的全部长名称物料',
              onClear: () {},
              onConfirm: () => commits++,
              confirmLabel: '确定（12）',
            ),
          ),
        ),
        zoom: 2,
      );
      expect(find.text('已选择：采购与生产共同使用的全部长名称物料'), findsOneWidget);
      await tester.tap(find.text('确定（12）'));
      expect(commits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'floating action height includes navigation and every action remains reachable',
    (tester) async {
      var completed = 0;
      await _pump(
        tester,
        UtenCapsuleNavScope(
          occlusion: 70,
          child: Scaffold(
            floatingActionButton: UtenFloatingActionGroup(
              children: [
                for (var i = 0; i < 6; i++)
                  FilledButton(
                    key: Key('floating-$i'),
                    onPressed: () => completed = i + 1,
                    child: Text('处理第 $i 项物料'),
                  ),
              ],
            ),
          ),
        ),
        zoom: 2,
      );
      expect(
        tester.getSize(find.byType(UtenFloatingActionGroup)).height,
        lessThanOrEqualTo(200),
      );
      await tester.ensureVisible(find.byKey(const Key('floating-5')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('floating-5')));
      expect(completed, 6);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large app bar text opens the original actions without shrinking',
    (tester) async {
      var actions = 0;
      await _pump(
        tester,
        Scaffold(
          appBar: UtenAppBar(
            title: '物料分析下达车间与采购委外核对',
            subtitle: '完整的业务说明仍在标题提示中',
            showPagePermissionAction: false,
            actions: [
              for (var i = 0; i < 3; i++)
                TextButton(onPressed: () => actions++, child: Text('操作 $i')),
            ],
          ),
        ),
        systemText: 2,
      );
      expect(find.byType(FittedBox), findsNothing);
      await tester.tap(find.byKey(const Key('uten-app-bar-more-actions')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('操作 2'));
      await tester.tap(find.text('操作 2'));
      expect(actions, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'supply confirmation scrolls long summaries and preserves quantities',
    (tester) async {
      final entries = [
        for (var i = 0; i < 30; i++)
          MaterialSupplyQuantityEntry(
            actionGroupKey: 'group-$i',
            materialLineId: 'material-$i',
            label: '第 $i 项采购委外长名称物料',
            dimensionKey: 'dimension-$i',
            openQty: 10,
            maxQty: 10,
            safetyStockQty: 0,
            publicAvailableQty: 0,
            openSafetySupplyQty: 0,
            safetyReplenishmentGapQty: 0,
            unitName: '个',
          ),
      ];
      await _pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => MaterialSupplySubmitConfirmDialog(
                  route: MaterialSupplyRoute.buy,
                  entries: entries,
                  quantities: List.filled(30, 10),
                  qtyText: (qty) => qty!.toStringAsFixed(0),
                ),
              ),
              child: const Text('下达采购'),
            ),
          ),
        ),
        systemText: 2,
      );
      await tester.tap(find.text('下达采购'));
      await tester.pumpAndSettle();
      expect(find.text('共 30 个品种，合计 300。'), findsOneWidget);
      await tester.ensureVisible(find.text('第 29 项采购委外长名称物料'));
      await tester.pumpAndSettle();
      expect(find.text('10 个'), findsNWidgets(30));
      expect(
        find.byKey(const Key('supply-submit-confirm')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
