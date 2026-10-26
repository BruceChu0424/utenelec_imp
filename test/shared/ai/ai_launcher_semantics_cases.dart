part of 'ai_chat_test.dart';

void launcherSemanticsCases() {
  testWidgets(
    'local AI messages and settings never acquire a second global page rail',
    (tester) async {
      final pageScroll = ScrollController();
      final pageInput = TextEditingController();
      addTearDown(pageScroll.dispose);
      addTearDown(pageInput.dispose);
      final repository = _FakeChatRepository()
        ..restored = AiChatConversationView(
          conversationId: _c1,
          turns: [
            for (var row = 0; row < 30; row++)
              AiChatTurn(
                jobId: 'local-rail-turn-$row',
                reply: AiChatReply.fromJson({
                  'question': 'Remembered question $row',
                  'reply': 'A long remembered answer $row. ' * 16,
                  'conversationId': _c1,
                }),
              ),
          ],
        );
      await _pumpRealShell(
        tester,
        repository,
        initialLocation: '/sales/orders/new',
        size: const Size(1366, 650),
        scrollBehavior: const UtenScrollBehavior(),
        outerPageHost: true,
        editorPageBuilder: (_) => Scaffold(
          body: UtenPageScrollbarSource(
            key: const Key('ai-local-role-business-viewport'),
            controller: pageScroll,
            priority: UtenPageScrollbarPriority.page,
            builder: (context, _) => ListView(
              controller: pageScroll,
              children: [
                TextField(
                  key: const Key('ai-local-role-business-input'),
                  controller: pageInput,
                ),
                const SizedBox(height: 2400),
              ],
            ),
          ),
        ),
      );
      final business = find.byKey(const Key('ai-local-role-business-viewport'));
      final businessInput = find.byKey(
        const Key('ai-local-role-business-input'),
      );
      await tester.enterText(businessInput, 'Keep business input');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final businessRect = tester.getRect(business);
      final businessElement = tester.element(businessInput);
      final originalPosition = pageScroll.position;
      expect(find.byKey(UtenPageScrollbarHost.railKey), findsOneWidget);
      expect(
        UtenPageScrollRoleScope.isPageOf(tester.element(businessInput)),
        isTrue,
      );

      void checkPageUnchanged() {
        expect(find.byKey(UtenPageScrollbarHost.railKey), findsOneWidget);
        expect(tester.getRect(business), businessRect);
        expect(tester.element(businessInput), same(businessElement));
        expect(pageScroll.position, same(originalPosition));
        expect(pageInput.text, 'Keep business input');
      }

      void checkLocalLane(Finder scrollView) {
        expect(
          UtenPageScrollRoleScope.isPageOf(tester.element(scrollView)),
          isFalse,
        );
        final gutter = find
            .descendant(of: scrollView, matching: find.byType(UtenScrollGutter))
            .first;
        final gutterWidget = tester.widget<UtenScrollGutter>(gutter);
        final lane =
            tester.getRect(gutter).right -
            tester.getRect(find.byWidget(gutterWidget.child)).right;
        expect(lane, closeTo(16, .02));
        final localBars = find.descendant(
          of: scrollView,
          matching: find.byType(UtenVerticalScrollbar),
        );
        expect(localBars, findsWidgets);
        expect(
          tester
              .widgetList<UtenVerticalScrollbar>(localBars)
              .any(
                (bar) =>
                    bar.visible &&
                    bar.controller.positions.length == 1 &&
                    bar.controller.position.maxScrollExtent > 0,
              ),
          isTrue,
        );
      }

      await _open(tester);
      checkPageUnchanged();
      final messages = find.byKey(const ValueKey('ai-chat-messages'));
      final messagesController = tester.widget<ListView>(messages).controller!;
      expect(messagesController.position.maxScrollExtent, greaterThan(0));
      checkLocalLane(messages);
      await tester.tap(find.byKey(const ValueKey('ai-chat-settings')));
      await tester.pumpAndSettle();
      checkPageUnchanged();
      checkLocalLane(find.byKey(const ValueKey('ai-chat-settings-panel')));
      expect(
        repository.messages,
        isEmpty,
        reason:
            'Only restored mock conversation data is used; no AI message is sent',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final transientWidth in [0.0, 20.0]) {
    testWidgets(
      'launcher safely hides at transient width $transientWidth and restores one semantic control',
      (tester) async {
        SemanticsWireGraph.reset();
        final handle = tester.ensureSemantics();
        final available = ValueNotifier(const Size(1000, 850));
        addTearDown(available.dispose);
        try {
          await _pump(tester, overlaySize: available);
          final business = tester.element(
            find.byKey(const ValueKey('business-surface')),
          );
          final launcher = find.byKey(const ValueKey('ai-chat-launcher'));
          expect(launcher, findsOneWidget);
          available.value = Size(transientWidth, 850);
          await tester.pumpAndSettle();
          expect(launcher, findsNothing);
          expect(
            tester.element(find.byKey(const ValueKey('business-surface'))),
            same(business),
          );
          expect(business.mounted, isTrue);
          expect(tester.takeException(), isNull);

          available.value = const Size(1000, 850);
          await tester.pumpAndSettle();
          expect(launcher, findsOneWidget);
          final node = tester.getSemantics(launcher);
          final data = node.getSemanticsData();
          final name = [
            data.label,
            data.tooltip,
          ].where((part) => part.isNotEmpty).join(' ');
          expect(_en.aiChatOpen.allMatches(name).length, 1);
          expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
          expect(data.customSemanticsActionIds, hasLength(2));
          expect(SemanticsWireGraph.nodes[node.id], isEmpty);
          expect(SemanticsWireGraph.missing, isEmpty);

          // Exactly one hit target still fits: the guard must not hide it.
          available.value = const Size(48, 850);
          await tester.pumpAndSettle();
          expect(launcher, findsOneWidget);
          final bounds = tester.getRect(launcher);
          expect(bounds.width, 48);
          expect(bounds.left, 0);
          expect(bounds.right, 48);
          expect(tester.takeException(), isNull);
        } finally {
          handle.dispose();
        }
      },
    );
  }

  testWidgets(
    'temporary zero and small overlay constraints preserve the open chat draft and business element',
    (tester) async {
      final available = ValueNotifier(const Size(1000, 850));
      addTearDown(available.dispose);
      await _pump(tester, overlaySize: available);
      final business = tester.element(
        find.byKey(const ValueKey('business-surface')),
      );
      await _open(tester);
      final input = find.byKey(const ValueKey('ai-chat-input'));
      await tester.enterText(
        input,
        'Retain this unsent draft through temporary zero layout',
      );
      final controller = tester.widget<TextField>(input).controller!;
      for (final transient in [
        const Size(0, 850),
        const Size(20, 850),
        const Size(1000, 0),
        const Size(1000, 20),
      ]) {
        available.value = transient;
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-chat-panel')), findsNothing);
        expect(find.byKey(const ValueKey('ai-chat-launcher')), findsNothing);
        expect(
          controller.text,
          'Retain this unsent draft through temporary zero layout',
        );
        expect(
          tester.element(find.byKey(const ValueKey('business-surface'))),
          same(business),
        );
        expect(tester.takeException(), isNull);
        available.value = const Size(1000, 850);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-chat-panel')), findsOneWidget);
        expect(tester.widget<TextField>(input).controller, same(controller));
        expect(
          controller.text,
          'Retain this unsent draft through temporary zero layout',
        );
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('ai-chat-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-chat-launcher')), findsOneWidget);
    },
  );

  for (final width in [1366.0, 1920.0, 2560.0]) {
    for (final zoom in [.85, 1.0, 1.5, 2.0]) {
      testWidgets(
        'desktop default launcher stays inside real navigation and clears page actions at $width zoom $zoom',
        (tester) async {
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          await _pumpRealShell(
            tester,
            _FakeChatRepository(),
            initialLocation: '/sales/orders/new',
            size: Size(width, 950),
            interfaceZoom: zoom,
            scrollBehavior: const UtenScrollBehavior(),
            editorPageBuilder: (_) => Scaffold(
              body: Stack(
                children: [
                  UtenPageScrollbarSource(
                    controller: scroll,
                    priority: UtenPageScrollbarPriority.page,
                    builder: (context, _) => ListView(
                      controller: scroll,
                      children: const [SizedBox(height: 2400)],
                    ),
                  ),
                  Positioned(
                    right: 24,
                    bottom: 16,
                    child: UtenButton(
                      key: const Key('page-add-column'),
                      onPressed: () {},
                      child: const Text('添加列 / 删除行'),
                    ),
                  ),
                ],
              ),
            ),
          );
          expect(
            tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
            isFalse,
          );
          final defaultNav = tester.getRect(find.byType(NavigationRail));
          final defaultLauncher = tester.getRect(
            find.byKey(const ValueKey('ai-chat-launcher')),
          );
          expect(defaultNav.width, closeTo(80 * zoom, .02));
          expect(defaultLauncher.center.dx, closeTo(defaultNav.center.dx, .02));
          expect(defaultLauncher.left, greaterThanOrEqualTo(defaultNav.left));
          expect(defaultLauncher.right, lessThanOrEqualTo(defaultNav.right));
          expect(
            defaultLauncher.overlaps(
              tester.getRect(find.byKey(const Key('page-add-column'))),
            ),
            isFalse,
          );
          expect(
            defaultLauncher.overlaps(
              tester.getRect(find.byKey(UtenPageScrollbarHost.railKey)),
            ),
            isFalse,
          );
          // Explicitly exercise the optional expansion as well as the new
          // default; retain the full expanded/footer geometry checks below.
          if (find.byTooltip(_en.navExpand).evaluate().isNotEmpty) {
            await tester.tap(find.byTooltip(_en.navExpand));
            await tester.pumpAndSettle();
          }
          final nav = tester.getRect(find.byType(NavigationRail));
          final launcher = tester.getRect(
            find.byKey(const ValueKey('ai-chat-launcher')),
          );
          final overlay = tester.widget<AiChatOverlay>(
            find.byType(AiChatOverlay),
          );
          final navWidget = tester.widget<NavigationRail>(
            find.byType(NavigationRail),
          );
          final navWidth = UtenSideNavRail.widthFor(
            tester.element(find.byType(UtenSideNavRail)),
            extended: navWidget.extended,
          );
          expect(overlay.launcherRailWidth, navWidth);
          expect(nav.width, closeTo(navWidth * zoom, .02));
          expect(launcher.width, closeTo(48 * zoom, .02));
          expect(launcher.height, closeTo(48 * zoom, .02));
          expect(launcher.left, greaterThanOrEqualTo(nav.left));
          expect(launcher.right, lessThanOrEqualTo(nav.right));
          expect(launcher.center.dx, closeTo(nav.center.dx, .02));
          expect(launcher.top, greaterThanOrEqualTo(nav.top));
          expect(launcher.bottom, lessThanOrEqualTo(nav.bottom));
          expect(
            launcher.overlaps(
              tester.getRect(find.byKey(const Key('page-add-column'))),
            ),
            isFalse,
          );
          expect(
            launcher.overlaps(
              tester.getRect(find.byKey(UtenPageScrollbarHost.railKey)),
            ),
            isFalse,
          );
          if (navWidget.extended) {
            final toggle = tester.getRect(find.byTooltip(_en.navCollapse));
            // Touch targets retain 48 window pixels when the UI is reduced.
            // Check the unchanged 88-canvas-pixel bottom offset separately
            // from the measured footer control's role-dependent hit height.
            expect(nav.bottom - launcher.bottom, closeTo(88 * zoom, .02));
            expect(toggle.bottom, closeTo(nav.bottom, .02));
            final footerGap = toggle.top - launcher.bottom;
            expect(footerGap, closeTo(88 * zoom - toggle.height, .02));
            expect(footerGap, greaterThanOrEqualTo(24));
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'navigation slot follows collapse and routes without resetting draft, semantics or user placement',
    (tester) async {
      SemanticsWireGraph.reset();
      final handle = tester.ensureSemantics();
      try {
        final router = await _pumpRealShell(
          tester,
          _FakeChatRepository(),
          initialLocation: '/sales/orders/new',
          size: const Size(1920, 950),
        );
        final launcher = find.byKey(const ValueKey('ai-chat-launcher'));
        final originalElement = tester.element(launcher);
        void checkSlot({bool centered = true}) {
          final nav = tester.getRect(find.byType(NavigationRail));
          final box = tester.getRect(launcher);
          expect(box.left, greaterThanOrEqualTo(nav.left));
          expect(box.right, lessThanOrEqualTo(nav.right));
          if (centered) expect(box.center.dx, closeTo(nav.center.dx, .02));
          expect(launcher, findsOneWidget);
          final node = tester.getSemantics(launcher);
          final data = node.getSemanticsData();
          final name = [
            data.label,
            data.tooltip,
          ].where((s) => s.isNotEmpty).join(' ');
          expect(_en.aiChatOpen.allMatches(name).length, 1);
          expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
          expect(data.customSemanticsActionIds, hasLength(2));
          expect(SemanticsWireGraph.nodes[node.id], isEmpty);
          expect(SemanticsWireGraph.missing, isEmpty);
        }

        checkSlot();
        await tester.tap(find.byTooltip(_en.navExpand));
        await tester.pumpAndSettle();
        checkSlot();
        await tester.tap(find.byTooltip(_en.navCollapse));
        await tester.pump();
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          checkSlot(centered: false);
        }
        await tester.pumpAndSettle();
        checkSlot();
        expect(tester.element(launcher), same(originalElement));
        await tester.tap(find.byTooltip(_en.navExpand));
        await tester.pump();
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          checkSlot(centered: false);
        }
        await tester.pumpAndSettle();
        await _open(tester);
        final input = find.byKey(const ValueKey('ai-chat-input'));
        await tester.enterText(input, 'Keep this draft through navigation');
        final inputController = tester.widget<TextField>(input).controller;
        await tester.tap(find.byTooltip(_en.navCollapse));
        await tester.pumpAndSettle();
        router.push('/sales/quotes/new');
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(input).controller,
          same(inputController),
        );
        expect(inputController!.text, 'Keep this draft through navigation');
        router.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ai-chat-close')));
        await tester.pumpAndSettle();
        checkSlot();

        await tester.drag(launcher, const Offset(240, -60));
        await tester.pumpAndSettle();
        final userCenter = tester.getCenter(launcher);
        await tester.tap(find.byTooltip(_en.navExpand));
        await tester.pumpAndSettle();
        expect(tester.getCenter(launcher), userCenter);
        router.push('/sales/quotes/new');
        await tester.pumpAndSettle();
        expect(tester.getCenter(launcher), userCenter);

        await tester.drag(launcher, const Offset(-2000, 0));
        await tester.pumpAndSettle();
        expect(tester.getCenter(launcher).dx, 0);
        await tester.tap(find.byTooltip(_en.navExpand));
        await tester.pumpAndSettle();
        expect(tester.getCenter(launcher).dx, 0);
        final docked = tester.getCenter(launcher);
        await tester.tapAt(Offset(10, docked.dy));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-chat-panel')), findsOneWidget);
        expect(inputController.text, 'Keep this draft through navigation');
        expect(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets('themed navigation width is shared with the default launcher', (
    tester,
  ) async {
    await _pumpRealShell(
      tester,
      _FakeChatRepository(),
      initialLocation: '/sales/orders/new',
      theme: ThemeData(
        navigationRailTheme: const NavigationRailThemeData(minWidth: 96),
      ),
    );
    final nav = tester.getRect(find.byType(NavigationRail));
    expect(nav.width, 96);
    expect(
      tester.getCenter(find.byKey(const ValueKey('ai-chat-launcher'))).dx,
      nav.center.dx,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact real shell retains the trailing launcher fallback', (
    tester,
  ) async {
    await _pumpRealShell(
      tester,
      _FakeChatRepository(),
      initialLocation: '/sales/orders/new',
      size: const Size(390, 844),
    );
    expect(find.byType(NavigationRail), findsNothing);
    expect(
      tester
          .widget<AiChatOverlay>(find.byType(AiChatOverlay))
          .launcherRailWidth,
      isNull,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('ai-chat-launcher'))).right,
      390 - 24,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [1366.0, 1920.0, 2560.0]) {
    for (final zoom in [.85, 1.0, 1.5, 2.0]) {
      for (final withPageGutter in [false, true]) {
        testWidgets(
          'default launcher clears the real page rail at width $width and zoom $zoom with page gutter $withPageGutter',
          (tester) async {
            final scroll = ScrollController();
            addTearDown(scroll.dispose);
            final source = UtenPageScrollbarSource(
              controller: scroll,
              priority: UtenPageScrollbarPriority.page,
              builder: (context, _) => ScrollConfiguration(
                behavior: const MaterialScrollBehavior().copyWith(
                  scrollbars: false,
                ),
                child: ListView(
                  controller: scroll,
                  primary: false,
                  children: const [SizedBox(height: 2400)],
                ),
              ),
            );
            await _pump(
              tester,
              size: Size(width, 950),
              interfaceZoom: zoom,
              pageScrollbarHost: true,
              page: withPageGutter
                  ? UtenContentContainer(selectable: false, child: source)
                  : source,
            );
            final launcher = tester.getRect(
              find.byKey(const ValueKey('ai-chat-launcher')),
            );
            final rail = tester.getRect(
              find.byKey(UtenPageScrollbarHost.railKey),
            );
            expect(scroll.position.maxScrollExtent, greaterThan(0));
            expect(
              launcher.overlaps(rail),
              isFalse,
              reason:
                  'The default AI hit box and active page rail must not compete for the same pixels',
            );
            // Root chrome stays 14/right2 in window pixels for both layouts.
            // This independent fixture retains the existing AI right24 in
            // canvas units; its exact window gap is therefore 24*zoom - 16.
            expect(rail.width, closeTo(14, .02));
            expect(rail.right, closeTo(width - 2, .02));
            expect(rail.left - launcher.right, closeTo(24 * zoom - 16, .02));
            expect(launcher.right, closeTo(width - 24 * zoom, .02));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

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
