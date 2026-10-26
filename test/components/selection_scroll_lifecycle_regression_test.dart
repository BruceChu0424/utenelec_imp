import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_selection_lifecycle.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';

void main() {
  testWidgets(
    'selected lists and async form labels survive route replacements',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final labels = ValueNotifier(0);
      final input = TextEditingController();
      final focus = FocusNode();
      addTearDown(labels.dispose);
      addTearDown(input.dispose);
      addTearDown(focus.dispose);
      Widget page(int index) =>
          _RoutePage(index: index, labels: labels, input: input, focus: focus);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          scrollBehavior: const UtenScrollBehavior(),
          home: page(0),
        ),
      );
      await tester.pumpAndSettle();
      for (var index = 0; index < 8; index++) {
        if (index.isOdd) {
          final field = find.byKey(const Key('route-draft-input'));
          final element = tester.element(field);
          focus.requestFocus();
          await tester.pump();
          input.value = TextEditingValue(
            text: 'draft-$index',
            selection: const TextSelection.collapsed(offset: 5),
            composing: const TextRange(start: 0, end: 5),
          );
          labels.value++;
          await tester.pumpAndSettle();
          expect(tester.element(field), same(element));
          expect(focus.hasPrimaryFocus, isTrue);
          expect(input.text, 'draft-$index');
          expect(input.value.composing, const TextRange(start: 0, end: 5));
        }
        final area = tester.state<SelectionAreaState>(
          find.byType(SelectionArea),
        );
        area.selectableRegion.selectAll(SelectionChangedCause.keyboard);
        await tester.pumpAndSettle();
        navigator.currentState!.pushReplacement<void, void>(
          MaterialPageRoute<void>(builder: (_) => page(index + 1)),
        );
        labels.value++;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pumpAndSettle();
        expect(find.text('page-${index + 1}'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('native scroll selection retires a detached retained text leaf', (
    tester,
  ) async {
    final retained = GlobalKey();
    final revision = ValueNotifier(0);
    final area = GlobalKey<SelectionAreaState>();
    String? selected;
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const UtenScrollBehavior(),
        home: Scaffold(
          body: UtenSelectionArea(
            selectionKey: area,
            onSelectionChanged: (content) => selected = content?.plainText,
            child: SizedBox(
              height: 200,
              child: ListView(
                children: [
                  _RetainedLeaf(
                    key: retained,
                    child: const Text('RETAINED-LEAF'),
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: revision,
                    builder: (_, value, _) =>
                        Text('ACTIVE-$value', key: ValueKey(value)),
                  ),
                ],
              ),
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
    expect(selected, contains('RETAINED-LEAF'));
    final host = tester.renderObject<_RetainedLeafBox>(find.byKey(retained));
    host.suspend();
    revision.value++;
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    area.currentState!.selectableRegion.selectAll(
      SelectionChangedCause.keyboard,
    );
    await tester.pumpAndSettle();
    expect(selected, isNot(contains('RETAINED-LEAF')));
    expect(selected, contains('ACTIVE-1'));
    host.resume();
    await tester.pumpAndSettle();
    area.currentState!.selectableRegion.selectAll(
      SelectionChangedCause.keyboard,
    );
    await tester.pumpAndSettle();
    expect(selected, contains('RETAINED-LEAF'));
    expect(selected, contains('ACTIVE-1'));
    expect(tester.takeException(), isNull);
  });
}

class _RoutePage extends StatefulWidget {
  const _RoutePage({
    required this.index,
    required this.labels,
    required this.input,
    required this.focus,
  });
  final int index;
  final ValueNotifier<int> labels;
  final TextEditingController input;
  final FocusNode focus;
  @override
  State<_RoutePage> createState() => _RoutePageState();
}

class _RoutePageState extends State<_RoutePage> {
  bool _ready = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: UtenSelectionArea(
      child: ValueListenableBuilder<int>(
        valueListenable: widget.labels,
        builder: (_, revision, _) => ListView(
          children: [
            Text('page-${widget.index}'),
            if (widget.index.isOdd)
              TextField(
                key: const Key('route-draft-input'),
                controller: widget.input,
                focusNode: widget.focus,
              ),
            if (_ready) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < 8; i++) Text('horizontal-$revision-$i'),
                  ],
                ),
              ),
              for (var i = 0; i < 80; i++)
                Text('label-$revision-$i', key: ValueKey((revision, i))),
            ],
          ],
        ),
      ),
    ),
  );
}

class _RetainedLeaf extends SingleChildRenderObjectWidget {
  const _RetainedLeaf({super.key, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RetainedLeafBox();
}

class _RetainedLeafBox extends RenderProxyBox {
  RenderBox? _saved;
  void suspend() {
    _saved = child;
    child = null;
  }

  void resume() {
    child = _saved;
    _saved = null;
  }

  @override
  void detach() {
    if (_saved != null) resume();
    super.detach();
  }
}
