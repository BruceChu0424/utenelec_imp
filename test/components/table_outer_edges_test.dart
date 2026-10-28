import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_table_surface.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row extends EditableGridRow {}

Border _cellBorder(WidgetTester tester, String text) {
  final ancestors = find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate((widget) {
      if (widget is UtenTableCellFrame) return true;
      final decoration = switch (widget) {
        Container() => widget.decoration,
        DecoratedBox() => widget.decoration,
        _ => null,
      };
      return decoration is BoxDecoration && decoration.border is Border;
    }),
  );
  final cells = ancestors.evaluate().toList()
    ..sort(
      (left, right) => tester
          .getSize(find.byWidget(left.widget))
          .width
          .compareTo(tester.getSize(find.byWidget(right.widget)).width),
    );
  final decoration = switch (cells.first.widget) {
    UtenTableCellFrame(:final border) => BoxDecoration(border: border),
    Container(:final decoration) => decoration,
    DecoratedBox(:final decoration) => decoration,
    _ => null,
  };
  return (decoration as BoxDecoration).border! as Border;
}

void main() {
  testWidgets(
    'the logical cell edge paints above full-bleed contents at actual pixels',
    (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: const SizedBox(
                  width: 80,
                  height: 40,
                  child: UtenTableCellFrame(
                    border: Border(
                      right: BorderSide(color: Color(0xFFFF0000), width: 0.5),
                    ),
                    backgroundColor: Colors.blue,
                    child: ColoredBox(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pixels = await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final bytes = (await image.toByteData())!.buffer.asUint8List();
        final width = image.width;
        final y = image.height ~/ 2;
        final right = bytes.sublist(
          (y * width + width - 1) * 4,
          (y * width + width - 1) * 4 + 4,
        );
        final middle = bytes.sublist(
          (y * width + width ~/ 2) * 4,
          (y * width + width ~/ 2) * 4 + 4,
        );
        image.dispose();
        return (right, middle);
      });
      expect(pixels!.$1, [255, 0, 0, 255]);
      expect(pixels.$2, [255, 255, 255, 255]);
    },
  );
  testWidgets(
    'the row closing stroke paints above opaque children and includes fitted empty space',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 80,
              child: UtenTableRowRightEdge(
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: ColoredBox(color: Colors.yellow),
                    ),
                    Expanded(child: ColoredBox(color: Colors.black)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final decoration = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(UtenTableRowRightEdge),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(decoration.position, DecorationPosition.foreground);
      final border = (decoration.decoration as BoxDecoration).border! as Border;
      expect(border.right.style, BorderStyle.solid);
      expect(border.right.width, 0.5);
      expect(tester.getSize(find.byType(UtenTableRowRightEdge)).width, 420);
    },
  );
  for (final editor in [false, true]) {
    for (final actions in [false, true]) {
      for (final pinned in [false, true]) {
        testWidgets(
          '${editor ? 'editor' : 'master'} logical last column retains its right border, actions=$actions, pinned=$pinned',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(500, 500);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final controller = UtenEditableGridController<_Row>(
              initial: [_Row()],
            );
            addTearDown(controller.dispose);
            final table = editor
                ? UtenEditableGrid<_Row>(
                    controller: controller,
                    createBlankRow: _Row.new,
                    showAddRow: false,
                    showRowDelete: actions,
                    showColumnSettings: actions,
                    initialPinnedColumnKeys: pinned ? {'left', 'right'} : {},
                    columns: [
                      EditableGridColumn<_Row>(
                        key: 'left',
                        label: '左列',
                        width: 300,
                        textOf: (_) => '左值',
                        cellBuilder: (_, _) => const Text('左值'),
                      ),
                      EditableGridColumn<_Row>(
                        key: 'right',
                        label: '右列',
                        width: 300,
                        textOf: (_) => '右值',
                        cellColor: (_, _) => Colors.yellow,
                        cellBuilder: (_, _) => const Text('右值'),
                      ),
                      EditableGridColumn<_Row>(
                        key: 'hidden',
                        label: '隐藏列',
                        width: 100,
                        defaultVisible: false,
                        textOf: (_) => '隐藏值',
                        cellBuilder: (_, _) => const Text('隐藏值'),
                      ),
                    ],
                  )
                : MasterDataTableView<String>(
                    showColumnChooser: actions,
                    requiredLeadingColumnKeys: pinned ? ['left', 'right'] : [],
                    embedded: true,
                    columns: [
                      MasterColumnDef<String>(
                        key: 'left',
                        label: '左列',
                        width: 300,
                        value: (_) => '左值',
                      ),
                      MasterColumnDef<String>(
                        key: 'right',
                        label: '右列',
                        width: 300,
                        value: (_) => '右值',
                        cellColor: (_, _) => Colors.yellow,
                      ),
                      MasterColumnDef<String>(
                        key: 'hidden',
                        label: '隐藏列',
                        width: 100,
                        defaultVisible: false,
                        value: (_) => '隐藏值',
                      ),
                    ],
                    items: const ['row'],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                  );
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(body: ListView(children: [table])),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('隐藏值'), findsNothing);
            expect(
              find.ancestor(
                of: find.text('右列').first,
                matching: find.byType(UtenTableHeaderSurface),
              ),
              findsOneWidget,
            );
            expect(_cellBorder(tester, '左列').right.style, BorderStyle.solid);
            expect(_cellBorder(tester, '右列').right.style, BorderStyle.solid);
            expect(_cellBorder(tester, '左值').right.style, BorderStyle.solid);
            expect(_cellBorder(tester, '右值').right.style, BorderStyle.solid);
            expect(_cellBorder(tester, '右值').top.style, BorderStyle.solid);
            expect(_cellBorder(tester, '右值').bottom.style, BorderStyle.solid);
            for (final element in find.byType(Scrollable).evaluate()) {
              final state =
                  (element as StatefulElement).state as ScrollableState;
              if (state.position.axis == Axis.horizontal) {
                state.position.jumpTo(state.position.maxScrollExtent);
              }
            }
            await tester.pumpAndSettle();
            expect(_cellBorder(tester, '左列').right.style, BorderStyle.solid);
            expect(_cellBorder(tester, '右列').right.style, BorderStyle.solid);
            expect(_cellBorder(tester, '左值').right.style, BorderStyle.solid);
            expect(_cellBorder(tester, '右值').right.style, BorderStyle.solid);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  testWidgets(
    'table cards preserve the inherited radius while ordinary cards retain their frame',
    (tester) async {
      const original = RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(23)),
        side: BorderSide(color: Colors.red, width: 3),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(cardTheme: const CardThemeData(shape: original)),
          home: Builder(
            builder: (context) => Column(
              children: [
                const Card(key: Key('ordinary'), child: Text('ordinary')),
                Card(
                  key: const Key('table'),
                  shape: utenTableCardShape(context),
                  child: const Text('table'),
                ),
              ],
            ),
          ),
        ),
      );
      RoundedRectangleBorder materialShape(String key) =>
          tester
                  .widget<Material>(
                    find
                        .descendant(
                          of: find.byKey(Key(key)),
                          matching: find.byType(Material),
                        )
                        .first,
                  )
                  .shape!
              as RoundedRectangleBorder;
      expect(materialShape('ordinary').side, original.side);
      expect(materialShape('table').side, BorderSide.none);
      expect(materialShape('table').borderRadius, original.borderRadius);
    },
  );
}
