import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/components/data_display/uten_selection_lifecycle.dart';

void main() {
  testWidgets(
    'lifecycle region retains the default touch copy toolbar',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtenSelectionArea(
              child: Center(child: Text('COPYABLE-TEXT')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('COPYABLE-TEXT'));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
  testWidgets(
    'retained scrollable unregisters before the next selection sort',
    (tester) async {
      final retained = GlobalKey();
      final area = GlobalKey<SelectionAreaState>();
      String? selected;
      final revision = ValueNotifier(0);
      addTearDown(revision.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SelectionArea(
              key: area,
              onSelectionChanged: (content) => selected = content?.plainText,
              child: Column(
                children: [
                  _RetainedRender(
                    key: retained,
                    child: UtenSelectionLifecycleScope(
                      child: SizedBox(
                        height: 150,
                        child: ListView(
                          children: [
                            for (var i = 0; i < 500; i++) Text('RETAINED-$i'),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 150,
                    child: ValueListenableBuilder(
                      valueListenable: revision,
                      builder: (_, value, _) => ListView(
                        key: ValueKey(value),
                        children: [Text('ACTIVE-$value')],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      area.currentState!.selectableRegion.selectAll(
        SelectionChangedCause.keyboard,
      );
      await tester.pumpAndSettle();
      expect(selected, contains('RETAINED-0'));
      final host = tester.renderObject<_RetainedRenderBox>(
        find.byKey(retained),
      );
      host.detachRetainedChild();
      revision.value++;
      await tester.pump();
      await tester.pump();
      await tester.pump();
      area.currentState!.selectableRegion.selectAll(
        SelectionChangedCause.keyboard,
      );
      await tester.pump();
      expect(selected, isNot(contains('RETAINED-0')));
      host.attachRetainedChild();
      await tester.pumpAndSettle();
      area.currentState!.selectableRegion.selectAll(
        SelectionChangedCause.keyboard,
      );
      await tester.pumpAndSettle();
      expect(selected, contains('RETAINED-0'));
      expect(selected, contains('ACTIVE-1'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    '500 editable rows scroll and replace without detached selections',
    (tester) async {
      final revision = ValueNotifier(0);
      final treeScroll = ScrollController();
      final pageArea = GlobalKey<SelectionAreaState>();
      addTearDown(treeScroll.dispose);
      addTearDown(revision.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 400,
              child: UtenSelectionArea(
                selectionKey: pageArea,
                child: Row(
                  children: [
                    SizedBox(
                      width: 210,
                      child: ListView.builder(
                        controller: treeScroll,
                        itemCount: 680,
                        itemBuilder: (_, index) => SizedBox(
                          height: 38,
                          child: Text('CATEGORY-$index'),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ValueListenableBuilder(
                        valueListenable: revision,
                        builder: (_, value, _) => MasterDataTableView<int>(
                          virtualized: true,
                          selectable: true,
                          idOf: (row) => '$value:$row',
                          rowKeyOf: (row) => '$value:$row',
                          requiredLeadingColumnKeys: const ['name'],
                          columns: [
                            MasterColumnDef(
                              key: 'name',
                              label: 'Name',
                              width: 220,
                              value: (row) => 'ROW-$value-$row',
                            ),
                            MasterColumnDef(
                              key: 'qty',
                              label: 'Quantity',
                              width: 220,
                              value: (row) => '$row',
                              cellBuilder: (_, row) => TextFormField(
                                initialValue: '$row',
                                decoration: const InputDecoration(
                                  suffixText: 'UAT-UNIT',
                                ),
                              ),
                            ),
                            MasterColumnDef(
                              key: 'notes',
                              label: 'Notes',
                              width: 600,
                              minimumWidthOf: (_) => 600,
                              value: (row) => 'NOTES-$value-$row',
                            ),
                          ],
                          items: List.generate(500, (index) => index),
                          facets: const {},
                          nullCounts: const {},
                          filters: const {},
                          onFilterChanged: (_, _) {},
                        ),
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
      final row = find.text('ROW-0-0');
      final p = tester.renderObject<RenderParagraph>(
        find.descendant(of: row, matching: find.byType(RichText)),
      );
      final boxes = p.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 7),
      );
      final start = p.localToGlobal(
        Offset(
          boxes.first.left + 1,
          (boxes.first.top + boxes.first.bottom) / 2,
        ),
      );
      final end = p.localToGlobal(
        Offset(boxes.last.right - 1, (boxes.last.top + boxes.last.bottom) / 2),
      );
      final mouse = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(end);
      await mouse.up();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      pageArea.currentState!.selectableRegion.selectAll(
        SelectionChangedCause.keyboard,
      );
      await tester.pump();
      final vertical = tester
          .stateList<ScrollableState>(
            find.descendant(
              of: find.byType(MasterDataTableView<int>),
              matching: find.byType(Scrollable),
            ),
          )
          .where((state) => state.position.axis == Axis.vertical)
          .first;
      final horizontal = tester
          .stateList<ScrollableState>(
            find.descendant(
              of: find.byType(MasterDataTableView<int>),
              matching: find.byType(Scrollable),
            ),
          )
          .where(
            (state) =>
                state.position.axis == Axis.horizontal &&
                state.position.maxScrollExtent > 300,
          )
          .last;
      for (var turn = 0; turn < 5; turn++) {
        for (var step = 0; step < 8; step++) {
          vertical.position.jumpTo(
            (step * 450.0).clamp(0, vertical.position.maxScrollExtent),
          );
          treeScroll.jumpTo(step * 500.0);
          horizontal.position.jumpTo(step.isEven ? 200 : 0);
          await tester.pump();
        }
        revision.value++;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        expect(tester.takeException(), isNull);
      }
      vertical.position.jumpTo(0);
      horizontal.position.jumpTo(0);
      await tester.pumpAndSettle();
      final bodyArea = tester.state<SelectionAreaState>(
        find.descendant(
          of: find.byType(MasterDataTableView<int>),
          matching: find.byType(SelectionArea),
        ),
      );
      bodyArea.selectableRegion.selectAll(SelectionChangedCause.keyboard);
      await tester.pumpAndSettle();
      expect(find.text('ROW-5-0'), findsWidgets);
      // A route replacement disposes pending clear work as well as registrars.
      revision.value++;
      await tester.pump();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('NEXT-ROUTE'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('NEXT-ROUTE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );
}

// Retain an element and its scroll offset while its render subtree is detached,
// then let a sibling add selectable content in the same frame. This isolates
// the lifetime exercised by retained/off-screen branches without disposing them.
class _RetainedRender extends SingleChildRenderObjectWidget {
  const _RetainedRender({super.key, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RetainedRenderBox();
}

class _RetainedRenderBox extends RenderProxyBox {
  RenderBox? _retained;
  void detachRetainedChild() {
    _retained = child;
    child = null;
  }

  void attachRetainedChild() {
    child = _retained;
    _retained = null;
  }

  @override
  void detach() {
    if (_retained != null) attachRetainedChild();
    super.detach();
  }
}
