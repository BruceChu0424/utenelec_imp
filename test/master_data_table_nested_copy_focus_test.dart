import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_selection_lifecycle.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  String? clipboard;
  setUp(() {
    clipboard = 'PREVIOUS-CLIPBOARD';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  for (final hold in [Duration.zero, const Duration(milliseconds: 150)]) {
    testWidgets(
      'nested page/table text drag hold=${hold.inMilliseconds}ms keeps keyboard copy in the table',
      (tester) async {
        await _mount(tester);
        await _select(tester, 'INNER-ENGLISH-000006', hold);
        final inner = tester.element(
          find.descendant(
            of: find.byType(MasterDataTableView<String>),
            matching: find.byType(SelectionArea),
          ),
        );
        var innerFocused = false;
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
          element,
        ) {
          if (identical(element, inner)) {
            innerFocused = true;
            return false;
          }
          return true;
        });
        await _copy(tester);
        expect(
          clipboard,
          'INNER-ENGLISH-000006',
          reason:
              'innerRegionFocused=$innerFocused primary=${FocusManager.instance.primaryFocus?.debugLabel}',
        );
        expect(innerFocused, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  testWidgets(
    'nested native input retains its own select-all and copy',
    (tester) async {
      final input = TextEditingController(text: 'NATIVE-INPUT');
      addTearDown(input.dispose);
      await _mount(tester, input: input);
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _copy(tester);
      expect(clipboard, 'NATIVE-INPUT');
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  for (final hold in [Duration.zero, _slowPress]) {
    testWidgets(
      'a table drag hold=${hold.inMilliseconds}ms may leave a previously focused search input',
      (tester) async {
        final input = TextEditingController(text: 'NATIVE-INPUT');
        final inputFocus = FocusNode();
        addTearDown(input.dispose);
        addTearDown(inputFocus.dispose);
        await _mount(tester, input: input, inputFocus: inputFocus);
        inputFocus.requestFocus();
        await tester.pump();
        expect(inputFocus.hasFocus, isTrue);
        await _select(tester, 'INNER-ENGLISH-000006', hold);
        await _copy(tester);
        expect(clipboard, 'INNER-ENGLISH-000006');
        expect(inputFocus.hasFocus, isFalse);
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
  }

  testWidgets(
    'a native input mouse selection remains native after table selection',
    (tester) async {
      final input = TextEditingController(text: 'NATIVE-INPUT');
      final inputFocus = FocusNode();
      addTearDown(input.dispose);
      addTearDown(inputFocus.dispose);
      await _mount(tester, input: input, inputFocus: inputFocus);
      await _select(tester, 'INNER-ENGLISH-000006', _slowPress);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _copy(tester);
      expect(clipboard, 'NATIVE-INPUT');
      expect(inputFocus.hasFocus, isTrue);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'copy follows the slow-drag winner across two tables and outer page text',
    (tester) async {
      await _mount(tester, secondTable: true);
      for (final text in [
        'INNER-ENGLISH-000006',
        'OTHER-TABLE-000007',
        'OUTER-PAGE-TEXT',
        'INNER-ENGLISH-000006',
      ]) {
        await _select(tester, text, _slowPress);
        await _copy(tester);
        expect(clipboard, text);
      }
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'an explicit native input focus request on mouse-up wins over restoration',
    (tester) async {
      final input = TextEditingController(text: 'NATIVE-INPUT');
      final inputFocus = FocusNode();
      addTearDown(input.dispose);
      addTearDown(inputFocus.dispose);
      await _mount(
        tester,
        input: input,
        inputFocus: inputFocus,
        onPointerUp: (_) => inputFocus.requestFocus(),
      );
      inputFocus.requestFocus();
      await tester.pump();
      await _select(tester, 'INNER-ENGLISH-000006', _slowPress);
      expect(inputFocus.hasFocus, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _copy(tester);
      expect(clipboard, 'NATIVE-INPUT');
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'replacing table rows before release clears old selection and keeps new input focus',
    (tester) async {
      final input = TextEditingController(text: 'NATIVE-INPUT');
      final inputFocus = FocusNode();
      addTearDown(input.dispose);
      addTearDown(inputFocus.dispose);
      await _mount(tester, input: input, inputFocus: inputFocus);
      await _select(
        tester,
        'INNER-ENGLISH-000006',
        _slowPress,
        beforeRelease: () async {
          await _mount(
            tester,
            input: input,
            inputFocus: inputFocus,
            items: const ['REPLACEMENT-ROW'],
          );
          inputFocus.requestFocus();
          await tester.pump();
        },
      );
      expect(inputFocus.hasFocus, isTrue);
      await _copy(tester);
      expect(clipboard, isNot('INNER-ENGLISH-000006'));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'the selected table text remains available to its native context-menu action',
    (tester) async {
      await _mount(tester);
      await _select(tester, 'INNER-ENGLISH-000006', _slowPress);
      final pointer = await tester.startGesture(
        tester.getCenter(find.text('INNER-ENGLISH-000006')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await pointer.up();
      await pointer.removePointer();
      await tester.pumpAndSettle();
      expect(find.text('复制所选文字'), findsOneWidget);
      await tester.tap(find.text('复制所选文字'));
      await tester.pumpAndSettle();
      expect(clipboard, 'INNER-ENGLISH-000006');
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'replacement before the deferred native clear cannot restore stale table focus',
    (tester) async {
      await _mount(tester);
      await _select(
        tester,
        'INNER-ENGLISH-000006',
        _slowPress,
        beforeRelease: () =>
            _mount(tester, items: const ['REPLACEMENT-ROW'], settle: false),
        afterRelease: () async {
          var tableFocused = false;
          final table = tester.element(
            find.byType(MasterDataTableView<String>),
          );
          FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
            element,
          ) {
            tableFocused |= identical(element, table);
            return true;
          });
          expect(tableFocused, isFalse);
        },
      );
      await _copy(tester);
      expect(clipboard, isNot('INNER-ENGLISH-000006'));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'a cancelled mouse selection does not restore a previous region focus',
    (tester) async {
      final input = TextEditingController(text: 'NATIVE-INPUT');
      final inputFocus = FocusNode();
      addTearDown(input.dispose);
      addTearDown(inputFocus.dispose);
      await _mount(tester, input: input, inputFocus: inputFocus);
      await _select(
        tester,
        'INNER-ENGLISH-000006',
        _slowPress,
        cancel: true,
        beforeRelease: () async {
          inputFocus.requestFocus();
          await tester.pump();
        },
      );
      expect(inputFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'selection-key replacement and disposal cancel pending mouse restoration',
    (tester) async {
      final first = GlobalKey<SelectionAreaState>();
      final second = GlobalKey<SelectionAreaState>();
      final outside = FocusNode();
      addTearDown(outside.dispose);
      Widget page(GlobalKey<SelectionAreaState>? key) => MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: outside),
              if (key != null)
                UtenSelectionArea(
                  selectionKey: key,
                  child: const Text('REPLACEABLE-REGION'),
                ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(page(first));
      await tester.pumpAndSettle();
      await _select(
        tester,
        'REPLACEABLE-REGION',
        _slowPress,
        beforeRelease: () async {
          await tester.pumpWidget(page(second));
          outside.requestFocus();
          await tester.pump();
        },
      );
      expect(outside.hasFocus, isTrue);
      await _select(
        tester,
        'REPLACEABLE-REGION',
        _slowPress,
        beforeRelease: () async {
          await tester.pumpWidget(page(null));
          outside.requestFocus();
          await tester.pump();
        },
      );
      expect(outside.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'external selection focus nodes remain caller-owned when changed',
    (tester) async {
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      Widget page(FocusNode? focus) => MaterialApp(
        home: UtenSelectionArea(
          focusNode: focus,
          child: const Text('SELECTION'),
        ),
      );
      await tester.pumpWidget(page(first));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page(null));
      final owned = tester
          .widget<SelectionArea>(find.byType(SelectionArea))
          .focusNode;
      expect(owned, isNotNull);
      await tester.pumpWidget(page(second));
      await tester.pumpWidget(page(null));
      expect(
        tester.widget<SelectionArea>(find.byType(SelectionArea)).focusNode,
        same(owned),
      );
      await tester.pumpWidget(const SizedBox());
      expect(() => first.addListener(() {}), returnsNormally);
      expect(() => second.addListener(() {}), returnsNormally);
      expect(() => owned!.addListener(() {}), throwsFlutterError);
      expect(tester.takeException(), isNull);
    },
  );
}

const _slowPress = Duration(milliseconds: 150);

Future<void> _mount(
  WidgetTester tester, {
  TextEditingController? input,
  FocusNode? inputFocus,
  bool secondTable = false,
  List<String> items = const ['INNER-ENGLISH-000006', 'SECOND-ROW'],
  PointerUpEventListener? onPointerUp,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => UtenContextMenuPolicy(child: child!),
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 600,
          child: Listener(
            onPointerUp: onPointerUp,
            child: UtenContentContainer(
              child: Column(
                children: [
                  const Text('OUTER-PAGE-TEXT'),
                  if (input != null)
                    TextField(controller: input, focusNode: inputFocus),
                  Expanded(child: _table(items)),
                  if (secondTable)
                    Expanded(child: _table(const ['OTHER-TABLE-000007'])),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Widget _table(List<String> items) => MasterDataTableView<String>(
  columns: [
    MasterColumnDef(
      key: 'name',
      label: 'Name',
      width: 320,
      value: (row) => row,
    ),
  ],
  items: items,
  selectable: true,
  idOf: (row) => row,
  facets: const {},
  nullCounts: const {},
  filters: const {},
  onFilterChanged: (_, _) {},
  rowMenuBuilder: (_) => [UtenMenuItem(label: 'Business action', onTap: () {})],
);

Future<void> _select(
  WidgetTester tester,
  String text,
  Duration hold, {
  Future<void> Function()? beforeRelease,
  Future<void> Function()? afterRelease,
  bool cancel = false,
}) async {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: find.text(text), matching: find.byType(RichText)),
  );
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  final start = paragraph.localToGlobal(
    Offset(boxes.first.left + 0.1, (boxes.first.top + boxes.first.bottom) / 2),
  );
  final end = paragraph.localToGlobal(
    Offset(boxes.last.right + 1, (boxes.last.top + boxes.last.bottom) / 2),
  );
  final pointer = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(hold);
  for (var step = 1; step <= 8; step++) {
    await pointer.moveTo(Offset.lerp(start, end, step / 8)!);
    await tester.pump(const Duration(milliseconds: 20));
  }
  await beforeRelease?.call();
  if (cancel) {
    await pointer.cancel();
  } else {
    await pointer.up();
  }
  await pointer.removePointer();
  await afterRelease?.call();
  await tester.pumpAndSettle();
}

Future<void> _copy(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}
