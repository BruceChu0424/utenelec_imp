import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/responsive/display_zoom_pointer_binding.dart';

class _ZoomTestBinding extends AutomatedTestWidgetsFlutterBinding
    with UtenDisplayZoomPointerEvents {}

const _headerKey = ValueKey('isolated-header');
const _headerListKey = ValueKey('isolated-header-list');
const _bodyKey = ValueKey('retained-body');
const _bodyListKey = ValueKey('retained-body-list');
const _fieldKey = ValueKey('retained-input');

class _Header extends StatefulWidget {
  const _Header({super.key, required this.primary});
  final bool? primary;
  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 96,
    child: ListView.builder(
      key: _headerListKey,
      primary: widget.primary,
      itemExtent: 32,
      itemCount: 20,
      itemBuilder: (_, index) => Text('Header $index'),
    ),
  );
}

class _Body extends StatefulWidget {
  const _Body({super.key});
  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  final input = TextEditingController();
  final focus = FocusNode();
  late ScrollController primary;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    primary = PrimaryScrollController.of(context);
  }

  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: 64,
        child: TextField(key: _fieldKey, controller: input, focusNode: focus),
      ),
      Expanded(
        child: ListView.builder(
          key: _bodyListKey,
          primary: true,
          itemExtent: 48,
          itemCount: 80,
          itemBuilder: (_, index) => Text('Body $index'),
        ),
      ),
    ],
  );
}

ScrollableState _listState(WidgetTester tester, Key key) =>
    tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(key),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );

void main() {
  _ZoomTestBinding();
  for (final primary in [true, null]) {
    testWidgets(
      'header primary=$primary stays independent with ordinary keys across modes',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final outer = ScrollController();
        final ambient = ScrollController();
        addTearDown(outer.dispose);
        addTearDown(ambient.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            builder: (_, child) =>
                UtenDisplayZoomBox(fontFactor: 2, child: child!),
            home: Scaffold(
              body: PrimaryScrollController(
                controller: ambient,
                child: UtenCollapsingHeaderScrollView(
                  controller: outer,
                  compactBodyMinHeight: 480,
                  wheelGateDistance: 0,
                  wheelHoldWindow: Duration.zero,
                  collapsingHeader: _Header(key: _headerKey, primary: primary),
                  body: const _Body(key: _bodyKey),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final header = tester.state(find.byKey(_headerKey));
        final body = tester.state<_BodyState>(find.byKey(_bodyKey));
        final headerScroll = _listState(tester, _headerListKey);
        await tester.drag(find.byKey(_headerListKey), const Offset(0, -96));
        await tester.pumpAndSettle();
        expect(headerScroll.position.pixels, greaterThan(0));
        expect(outer.position.pixels, 0);
        expect(body.primary.position.pixels, 0);
        expect(ambient.hasClients, isFalse);
        await tester.tap(find.byKey(_fieldKey));
        await tester.pumpAndSettle();
        const editing = TextEditingValue(
          text: '12.34567',
          selection: TextSelection(baseOffset: 2, extentOffset: 5),
          composing: TextRange(start: 1, end: 7),
        );
        tester.testTextInput.updateEditingValue(editing);
        await tester.pumpAndSettle();
        final editable = find.descendant(
          of: find.byKey(_fieldKey),
          matching: find.byType(EditableText),
        );
        final editableState = tester.state<EditableTextState>(editable);
        final headerOffset = headerScroll.position.pixels;
        for (final size in [
          const Size(320, 900),
          const Size(1600, 1600),
          const Size(320, 900),
          const Size(1600, 1600),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(tester.state(find.byKey(_headerKey)), same(header));
          expect(tester.state(find.byKey(_bodyKey)), same(body));
          expect(_listState(tester, _headerListKey), same(headerScroll));
          expect(
            tester.state<EditableTextState>(editable),
            same(editableState),
          );
          expect(headerScroll.position.pixels, closeTo(headerOffset, 0.01));
          expect(headerScroll.widget.controller, isNull);
          expect(outer.positions, hasLength(1));
          expect(body.primary.positions, hasLength(1));
          expect(ambient.hasClients, isFalse);
          expect(headerScroll.position, isNot(same(outer.position)));
          expect(headerScroll.position, isNot(same(body.primary.position)));
          expect(body.input.value, editing);
          expect(body.focus.hasFocus, isTrue);
          expect(tester.testTextInput.isRegistered, isTrue);
          expect(tester.getSemantics(editable).value, editing.text);
        }
        Future<void> wheel(double delta) async {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: tester.getRect(find.byKey(_bodyListKey)).center,
              scrollDelta: Offset(0, delta),
            ),
          );
          await tester.pumpAndSettle();
        }

        await wheel(1000);
        expect(outer.position.pixels, outer.position.maxScrollExtent);
        await wheel(48);
        expect(
          body.primary.position.pixels,
          closeTo(24, 0.01),
          reason: 'binding normalizes once at 200%',
        );
        expect(headerScroll.position.pixels, closeTo(headerOffset, 0.01));
        expect(body.input.value, editing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
