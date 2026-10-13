import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/responsive/display_zoom_pointer_binding.dart';

class _ZoomBinding extends AutomatedTestWidgetsFlutterBinding
    with UtenDisplayZoomPointerEvents {}

class _HeaderProbe extends StatefulWidget {
  const _HeaderProbe({super.key, required this.extent});
  final double extent;
  @override
  State<_HeaderProbe> createState() => _HeaderProbeState();
}

class _HeaderProbeState extends State<_HeaderProbe> {
  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.extent,
    child: const Align(
      alignment: Alignment.topLeft,
      child: Text('Long inspection header'),
    ),
  );
}

class _BodyProbe extends StatefulWidget {
  const _BodyProbe({super.key});
  @override
  State<_BodyProbe> createState() => _BodyProbeState();
}

class _BodyProbeState extends State<_BodyProbe> {
  final input = TextEditingController();
  final focus = FocusNode();
  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextField(controller: input, focusNode: focus),
      Expanded(
        child: ListView.builder(
          primary: true,
          itemExtent: 48,
          itemCount: 80,
          itemBuilder: (_, index) => Text('Record $index'),
        ),
      ),
    ],
  );
}

void main() {
  _ZoomBinding();
  testWidgets(
    'plain keyed content retains IME and semantics through squeezed mode changes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        final outer = ScrollController();
        addTearDown(outer.dispose);
        final extent = ValueNotifier<double>(1200);
        addTearDown(extent.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: UtenDisplayZoomBox(fontFactor: 2, child: child!),
            ),
            home: Scaffold(
              body: ValueListenableBuilder<double>(
                valueListenable: extent,
                builder: (_, height, _) => UtenCollapsingHeaderScrollView(
                  controller: outer,
                  collapsingHeader: _HeaderProbe(
                    key: const ValueKey('header'),
                    extent: height,
                  ),
                  body: const _BodyProbe(key: ValueKey('body')),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        outer.jumpTo(outer.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final headerFinder = find.byType(_HeaderProbe, skipOffstage: false);
        final bodyFinder = find.byType(_BodyProbe, skipOffstage: false);
        final header = tester.state(headerFinder);
        final body = tester.state<_BodyProbeState>(bodyFinder);
        final input = find.byType(TextField, skipOffstage: false);
        await tester.ensureVisible(input);
        await tester.pumpAndSettle();
        await tester.tap(input.hitTestable());
        await tester.pumpAndSettle();
        const editing = TextEditingValue(
          text: '12.3456789',
          selection: TextSelection(baseOffset: 3, extentOffset: 6),
          composing: TextRange(start: 1, end: 8),
        );
        tester.testTextInput.updateEditingValue(editing);
        await tester.pumpAndSettle();

        for (final step in [
          (const Size(1600, 1600), 1200.0, false),
          (const Size(1800, 1800), 96.0, true),
          (const Size(320, 900), 1200.0, false),
          (const Size(1800, 1800), 96.0, true),
        ]) {
          extent.value = step.$2;
          tester.view.physicalSize = step.$1;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(tester.state(headerFinder), same(header));
          expect(tester.state(bodyFinder), same(body));
          expect(body.input.value, editing);
          expect(body.focus.hasFocus, isTrue);
          expect(tester.testTextInput.isRegistered, isTrue);
          expect(outer.positions, hasLength(1));
          expect(
            find.byType(NestedScrollView),
            step.$3 ? findsOneWidget : findsNothing,
          );
          await tester.ensureVisible(input);
          await tester.pumpAndSettle();
          expect(input.hitTestable(), findsOneWidget);
          final editable = find.byType(EditableText, skipOffstage: false);
          expect(tester.getSemantics(editable).value, editing.text);
          expect(tester.takeException(), isNull);
        }
      } finally {
        semantics.dispose();
      }
    },
  );
}
