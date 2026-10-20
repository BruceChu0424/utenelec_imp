part of 'ai_chat_test.dart';

void launcherSemanticsCases() {
  testWidgets(
    'launcher has one accessible button through selected page replacements',
    (tester) async {
      SemanticsWireGraph.reset();
      final handle = tester.ensureSemantics();
      final revision = ValueNotifier(0);
      addTearDown(revision.dispose);
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
      try {
        await _pump(
          tester,
          size: const Size(1280, 720),
          page: SelectionArea(
            child: ValueListenableBuilder(
              valueListenable: revision,
              builder: (_, value, _) => ListView(
                children: [
                  for (var row = 0; row < 40; row++)
                    Text('SELECTABLE-$value-$row'),
                ],
              ),
            ),
          ),
        );
        final launcher = find.byKey(const ValueKey('ai-chat-launcher'));
        void check() {
          final node = tester.getSemantics(launcher);
          final data = node.getSemanticsData();
          final name = [
            data.label,
            data.tooltip,
          ].where((s) => s.isNotEmpty).join(' ');
          expect(_en.aiChatOpen.allMatches(name).length, 1);
          expect(data.flagsCollection.isButton, isTrue);
          expect(data.flagsCollection.isFocused, isNot(ui.Tristate.none));
          expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
          expect(data.customSemanticsActionIds, hasLength(2));
          expect(
            SemanticsWireGraph.nodes[node.id],
            isEmpty,
            reason: 'one launcher must not publish transient descendant ids',
          );
          expect(SemanticsWireGraph.missing, isEmpty);
        }

        check();
        for (var turn = 0; turn < 5; turn++) {
          final text = 'SELECTABLE-$turn-0';
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.text(text),
              matching: find.byType(RichText),
            ),
          );
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: text.length),
          );
          final start = paragraph.localToGlobal(
            Offset(
              boxes.first.left + 0.1,
              (boxes.first.top + boxes.first.bottom) / 2,
            ),
          );
          final end = paragraph.localToGlobal(
            Offset(
              boxes.last.right + 1,
              (boxes.last.top + boxes.last.bottom) / 2,
            ),
          );
          final selection = await tester.startGesture(
            start,
            kind: ui.PointerDeviceKind.mouse,
          );
          await selection.moveTo(end);
          await selection.up();
          await tester.pumpAndSettle();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          expect(clipboard, contains(text));
          if (turn > 0) {
            expect(clipboard, isNot(contains('SELECTABLE-${turn - 1}-0')));
          }
          await selection.removePointer();
          final mouse = await tester.createGesture(
            kind: ui.PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: tester.getCenter(launcher));
          await tester.pump(const Duration(milliseconds: 700));
          revision.value++;
          tester.view.physicalSize = turn.isEven
              ? const Size(1920, 945)
              : const Size(1280, 720);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          await mouse.removePointer();
          await tester.pumpAndSettle();
          check();
        }
        expect(SemanticsWireGraph.frames, greaterThan(5));
        expect(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'launcher semantic move actions follow screen directions and tap opens chat',
    (tester) async {
      SemanticsWireGraph.reset();
      final handle = tester.ensureSemantics();
      try {
        await _pump(tester);
        final launcher = find.byKey(const ValueKey('ai-chat-launcher'));
        SemanticsNode actionNode() {
          final candidates = <SemanticsNode>[];
          void visit(SemanticsNode node) {
            if (node.getSemanticsData().customSemanticsActionIds?.length == 2) {
              candidates.add(node);
            }
            node.visitChildren((child) {
              visit(child);
              return true;
            });
          }

          visit(tester.getSemantics(find.byType(AiChatOverlay)));
          return candidates.single;
        }

        void perform(String label) {
          final node = actionNode();
          final id = node
              .getSemanticsData()
              .customSemanticsActionIds!
              .singleWhere(
                (id) => CustomSemanticsAction.getAction(id)?.label == label,
              );
          node.owner!.performAction(
            node.id,
            ui.SemanticsAction.customAction,
            id,
          );
        }

        final initial = tester.getCenter(launcher);
        perform(_en.aiChatMoveUp);
        await tester.pumpAndSettle();
        expect(tester.getCenter(launcher).dy, lessThan(initial.dy - 50));
        perform(_en.aiChatMoveDown);
        await tester.pumpAndSettle();
        expect(tester.getCenter(launcher).dy, closeTo(initial.dy, 0.1));
        final node = tester.getSemantics(launcher);
        node.owner!.performAction(node.id, ui.SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-chat-panel')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets('launcher remains keyboard focusable and Enter opens the panel', (
    tester,
  ) async {
    await _pump(tester);
    final launcher = tester.element(
      find.byKey(const ValueKey('ai-chat-launcher')),
    );
    var focused = false;
    for (var index = 0; index < 5 && !focused; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
        element,
      ) {
        if (identical(element, launcher)) {
          focused = true;
          return false;
        }
        return true;
      });
    }
    expect(focused, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-chat-panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
