import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_selection_lifecycle.dart';

void main() {
  testWidgets(
    'a retained editor survives copied scroll behaviors across selection hosts',
    (tester) async {
      final selectedHost = ValueNotifier(false);
      final controller = TextEditingController(text: 'draft');
      final field = GlobalKey();
      addTearDown(selectedHost.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: selectedHost,
              builder: (_, selected, _) {
                final editor = TextField(key: field, controller: controller);
                return selected ? UtenSelectionArea(child: editor) : editor;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(EditableText));
      controller.value = const TextEditingValue(
        text: 'draft input',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      );
      for (var index = 0; index < 4; index++) {
        selectedHost.value = !selectedHost.value;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.state(find.byType(EditableText)), same(state));
        expect(controller.text, 'draft input');
        expect(controller.value.composing, const TextRange(start: 0, end: 5));
      }
    },
  );

  testWidgets(
    'selection clear may retire a member without mutating SDK iteration',
    (tester) async {
      final area = GlobalKey<SelectionAreaState>();
      late SelectionRegistrar registrar;
      final first = _RetiringSelectable();
      final second = _RetiringSelectable();
      await tester.pumpWidget(
        MaterialApp(
          home: UtenSelectionArea(
            selectionKey: area,
            child: Builder(
              builder: (context) {
                registrar = SelectionContainer.maybeOf(context)!;
                return const SizedBox(width: 100, height: 100);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      registrar
        ..add(first)
        ..add(second);
      await tester.pumpAndSettle();
      first.onClear = () => registrar.remove(first);
      area.currentState!.selectableRegion.clearSelection();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(first.clears, 1);
      expect(second.clears, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      first.dispose();
      second.dispose();
    },
  );
}

class _RetiringSelectable extends ChangeNotifier with Selectable {
  VoidCallback? onClear;
  int clears = 0;
  @override
  SelectionGeometry get value =>
      const SelectionGeometry(status: SelectionStatus.none, hasContent: true);
  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    if (event is ClearSelectionEvent) {
      clears++;
      onClear?.call();
    }
    return SelectionResult.none;
  }

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) => Matrix4.identity();
  @override
  Size get size => const Size(20, 20);
  @override
  List<Rect> get boundingBoxes => const [Rect.fromLTWH(0, 0, 20, 20)];
  @override
  int get contentLength => 4;
  @override
  SelectedContent? getSelectedContent() => null;
  @override
  SelectedContentRange? getSelection() => null;
  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {}
}
