import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  var pasted = 0;
  var rowMenuBuilds = 0;
  var backgroundMenuBuilds = 0;
  var selected = <String>{};

  setUp(() {
    pasted = 0;
    rowMenuBuilds = 0;
    backgroundMenuBuilds = 0;
    selected = {};
  });

  Widget host({
    List<String> items = const [],
    bool isLoading = false,
    String? error,
  }) => MaterialApp(
    home: Scaffold(
      body: SelectionArea(
        child: SizedBox(
          key: const Key('table-bounds'),
          width: 700,
          height: 450,
          child: MasterDataTableView<String>(
            columns: [
              MasterColumnDef<String>(
                key: 'name',
                label: '名称',
                width: 200,
                value: (row) => row,
              ),
            ],
            items: items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            isLoading: isLoading,
            error: error,
            selectable: true,
            idOf: (row) => row,
            selectedIds: selected,
            onSelectedIdsChanged: (ids) => selected = ids,
            rowMenuBuilder: (row) {
              rowMenuBuilds++;
              return [UtenMenuItem(label: '复制 $row', onTap: () {})];
            },
            backgroundMenuBuilder: () {
              backgroundMenuBuilds++;
              return [UtenMenuItem(label: '粘贴记录', onTap: () => pasted++)];
            },
          ),
        ),
      ),
    ),
  );

  Future<void> rightClick(WidgetTester tester, Offset position) async {
    final gesture = await tester.startGesture(
      position,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Offset blankArea(WidgetTester tester) =>
      tester.getBottomLeft(find.byKey(const Key('table-bounds'))) +
      const Offset(120, -70);

  testWidgets('empty list blank space can paste', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await rightClick(tester, blankArea(tester));
    expect(find.text('粘贴记录'), findsOneWidget);
    expect(backgroundMenuBuilds, 1);
    expect(rowMenuBuilds, 0);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    await tester.tap(find.text('粘贴记录'));
    await tester.pumpAndSettle();
    expect(pasted, 1);
    expect(selected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('row menu wins over background menu', (tester) async {
    await tester.pumpWidget(host(items: ['记录甲']));
    await tester.pumpAndSettle();
    await rightClick(tester, tester.getCenter(find.text('记录甲')));
    expect(find.text('复制 记录甲'), findsOneWidget);
    expect(find.text('粘贴记录'), findsNothing);
    expect(backgroundMenuBuilds, 0);
    expect(rowMenuBuilds, 1);
    expect(selected, {'记录甲'});
    await tester.tapAt(const Offset(780, 580));
    await tester.pumpAndSettle();
    await rightClick(tester, blankArea(tester));
    expect(find.text('粘贴记录'), findsOneWidget);
    expect(find.text('复制 记录甲'), findsNothing);
    expect(selected, {'记录甲'});
  });

  testWidgets('header menu wins and fullscreen keeps background paste', (
    tester,
  ) async {
    await tester.pumpWidget(host(items: ['记录甲']));
    await tester.pumpAndSettle();
    await rightClick(tester, tester.getCenter(find.text('名称')));
    expect(find.text('固定到左侧'), findsOneWidget);
    expect(find.text('粘贴记录'), findsNothing);
    expect(backgroundMenuBuilds, 0);
    await tester.tapAt(const Offset(780, 580));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全屏'));
    await tester.pumpAndSettle();
    await rightClick(tester, const Offset(120, 480));
    expect(find.text('粘贴记录'), findsOneWidget);
    await tester.tap(find.text('粘贴记录'));
    await tester.pumpAndSettle();
    expect(pasted, 1);
    await tester.tap(find.text('退出全屏'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading and failed queries do not expose background actions', (
    tester,
  ) async {
    for (final loading in [true, false]) {
      await tester.pumpWidget(
        host(isLoading: loading, error: loading ? null : '加载失败'),
      );
      await tester.pump();
      final gesture = await tester.startGesture(
        blankArea(tester),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.up();
      await tester.pump();
      expect(find.text('粘贴记录'), findsNothing);
      expect(backgroundMenuBuilds, 0);
    }
  });
}
