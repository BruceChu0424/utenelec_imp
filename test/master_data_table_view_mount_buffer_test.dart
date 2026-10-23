import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart';

ScrollableState _body(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    )
    .singleWhere((state) => state.position.axis == Axis.vertical);

Finder _rowMarkers() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('content:'),
  skipOffstage: false,
);

void _expectCovered(
  WidgetTester tester, {
  required bool picker,
  bool allowPending = false,
}) {
  final viewport = tester.getRect(
    find.descendant(of: find.byType(ListView), matching: find.byType(Viewport)),
  );
  final rectangles = <Rect>[];
  for (final element in _rowMarkers().evaluate()) {
    final box = element.findRenderObject()! as RenderBox;
    // Data rows have 8px vertical cell padding outside the fixed marker;
    // picker tiles already include their entire height.
    final rect = (box.localToGlobal(Offset.zero) & box.size).inflate(
      picker ? 0 : 8,
    );
    if (rect.bottom > viewport.top && rect.top < viewport.bottom) {
      rectangles.add(rect);
    }
  }
  if (allowPending) {
    for (final element in find.byType(UtenRowMountPlaceholder).evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      if (rect.bottom > viewport.top && rect.top < viewport.bottom) {
        rectangles.add(rect);
      }
    }
  }
  rectangles.sort((a, b) => a.top.compareTo(b.top));
  expect(rectangles, isNotEmpty);
  var coveredTo = viewport.top;
  for (final rect in rectangles) {
    expect(rect.top, lessThanOrEqualTo(coveredTo + 1));
    if (rect.bottom > coveredTo) coveredTo = rect.bottom;
  }
  expect(coveredTo, greaterThanOrEqualTo(viewport.bottom - 1));
}

Future<void> _mount(
  WidgetTester tester, {
  required bool picker,
  required ValueChanged<Set<String>> select,
  bool editor = true,
  ValueChanged<int>? onBuild,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: MasterDataTableView<int>(
          items: List.generate(1000, (index) => index),
          virtualized: true,
          selectable: true,
          showColumnChooser: false,
          showFullscreenToggle: false,
          rowKeyOf: (row) => 'r$row',
          idOf: (row) => 'r$row',
          onSelectedIdsChanged: select,
          listItemBuilder: picker
              ? (_, row) => SizedBox(
                  key: ValueKey('content:$row'),
                  height: 56,
                  child: Text('row-$row'),
                )
              : null,
          columns: [
            MasterColumnDef<int>(
              key: 'name',
              label: '名称',
              width: 300,
              value: (row) => 'row-$row',
              cellBuilder: (_, row) {
                onBuild?.call(row);
                return SizedBox(
                  key: ValueKey('content:$row'),
                  height: editor ? 40 : 40 + (row % 3) * 9,
                  child: editor
                      ? TextFormField(
                          key: ValueKey('edit:$row'),
                          initialValue: 'draft-$row',
                        )
                      : Text('row-$row'),
                );
              },
            ),
          ],
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('local reveal mounts a distant variable-height row directly', (
    tester,
  ) async {
    final request = ValueNotifier(0);
    addTearDown(request.dispose);
    var builds = 0;
    final items = List.generate(1000, (index) => index);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: request,
            builder: (_, revision, _) => MasterDataTableView<int>(
              items: items,
              virtualized: true,
              rowKeyOf: (row) => 'r$row',
              revealItemId: 'r998',
              revealRequest: revision,
              columns: [
                MasterColumnDef<int>(
                  key: 'name',
                  label: '名称',
                  width: 300,
                  value: (row) => '$row',
                  cellBuilder: (_, row) {
                    builds++;
                    return SizedBox(
                      height: 40 + (row % 3) * 9,
                      child: Text('target-$row'),
                    );
                  },
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    builds = 0;
    request.value++;
    await tester.pumpAndSettle();
    expect(builds, lessThanOrEqualTo(80));
    final viewport = tester.getRect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Viewport),
      ),
    );
    final target = tester.getRect(find.text('target-998'));
    expect(target.top, greaterThanOrEqualTo(viewport.top));
    expect(target.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local window retains cross-row native selection through a distant scroll',
    (tester) async {
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            if (call.method == 'Clipboard.getData') return {'text': clipboard};
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _mount(tester, picker: false, editor: false, select: (_) {});
      Offset edge(String value, bool end) {
        final text = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.text(value),
            matching: find.byType(RichText),
          ),
        );
        final boxes = text.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: value.length),
        );
        final box = end ? boxes.last : boxes.first;
        return text.localToGlobal(
          Offset(
            end ? box.right + 1 : box.left + .1,
            (box.top + box.bottom) / 2,
          ),
        );
      }

      final mouse = await tester.startGesture(
        edge('row-0', false),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(edge('row-1', true));
      await mouse.up();
      await tester.pumpAndSettle();
      final position = _body(tester).position;
      position.jumpTo(position.viewportDimension * 40);
      await tester.pumpAndSettle();
      expect(find.text('row-1', skipOffstage: false), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(clipboard, contains('row-0'));
      expect(clipboard, contains('row-1'));
      final area = tester.state<SelectionAreaState>(
        find.descendant(
          of: find.byType(MasterDataTableView<int>),
          matching: find.byType(SelectionArea),
        ),
      );
      area.selectableRegion.clearSelection();
      await tester.pumpAndSettle();
      expect(find.text('row-1', skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final textScale in [1.0, 2.0]) {
    testWidgets(
      'large local table jump constructs destination rows without walking the gap at $textScale',
      (tester) async {
        var builds = 0;
        await _mount(
          tester,
          picker: false,
          editor: false,
          select: (_) {},
          onBuild: (_) => builds++,
          textScale: textScale,
        );
        final position = _body(tester).position;
        builds = 0;
        position.jumpTo(position.maxScrollExtent - position.viewportDimension);
        await tester.pumpAndSettle();
        final toEnd = builds;
        builds = 0;
        position.jumpTo(0);
        await tester.pumpAndSettle();
        debugPrint(
          'master-jump-work scale=$textScale toEnd=$toEnd toStart=$builds',
        );
        expect(toEnd, lessThanOrEqualTo(80));
        expect(builds, lessThanOrEqualTo(80));
        expect(find.text('row-0'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final picker in [false, true]) {
    testWidgets(
      '${picker ? 'picker' : 'data table'} mounts one-row buffer and fills fast scrolls',
      (tester) async {
        Set<String>? selected;
        await _mount(tester, picker: picker, select: (next) => selected = next);
        final position = _body(tester).position;
        final visibleRows = (position.viewportDimension / 56).ceil();
        debugPrint(
          'master-mount-buffer picker=$picker viewport=${position.viewportDimension} firstMounted=${_rowMarkers().evaluate().length}',
        );
        expect(
          _rowMarkers().evaluate().length,
          lessThanOrEqualTo(visibleRows + 2),
        );
        expect(_rowMarkers().evaluate().length, lessThan(25));
        _expectCovered(tester, picker: picker);
        if (!picker) {
          await tester.tap(
            find.byKey(const Key('master-data-table-select-all')),
          );
          await tester.pump();
          expect(
            selected,
            hasLength(1000),
            reason: 'mounting does not truncate selection data',
          );
        }
        for (final screens in [3.3, 60.0, 0.5, 150.0, 0.0]) {
          position.jumpTo(
            (screens * position.viewportDimension).clamp(
              0,
              position.maxScrollExtent - position.viewportDimension,
            ),
          );
          await tester.pump();
          _expectCovered(tester, picker: picker, allowPending: true);
          await tester.pumpAndSettle();
          _expectCovered(tester, picker: picker);
          expect(find.byType(UtenRowMountPlaceholder), findsNothing);
          expect(
            _rowMarkers().evaluate().length,
            // Before the destination rows are measured, the local window uses
            // the shorter plain-text row estimate to avoid any unpainted gap.
            lessThanOrEqualTo(picker ? visibleRows + 4 : 25),
          );
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets(
    'focused native editor remains alive outside the small mount buffer',
    (tester) async {
      await _mount(tester, picker: false, select: (_) {});
      final field = find.byKey(const ValueKey('edit:0'));
      await tester.tap(field);
      await tester.enterText(field, 'unsaved exact value');
      await tester.pump();
      final input = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      final originalState = tester.state<EditableTextState>(input);
      final controller = originalState.widget.controller;
      final focus = originalState.widget.focusNode;
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 7,
      );
      controller.value = controller.value.copyWith(
        composing: const TextRange(start: 2, end: 7),
      );
      final position = _body(tester).position;
      position.jumpTo(position.viewportDimension * 50);
      await tester.pump();
      expect(originalState.mounted, isTrue);
      expect(focus.hasFocus, isTrue);
      expect(controller.text, 'unsaved exact value');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 7),
      );
      expect(controller.value.composing, const TextRange(start: 2, end: 7));
      _expectCovered(tester, picker: false, allowPending: true);
      await tester.pumpAndSettle();
      _expectCovered(tester, picker: false);
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(tester.state<EditableTextState>(input), same(originalState));
      expect(focus.hasFocus, isTrue);
      expect(controller.text, 'unsaved exact value');
      expect(tester.takeException(), isNull);
    },
  );
}
