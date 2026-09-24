import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/production/widgets/material_preparation_route_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final chinese = ByteData.sublistView(
      await File('assets/fonts/NotoSansSC.ttf').readAsBytes(),
    );
    for (final family in ['NotoSansSC', 'Ahem']) {
      await (FontLoader(family)..addFont(Future.value(chinese))).load();
    }
    await (FontLoader('Roboto')..addFont(
          Future.value(
            ByteData.sublistView(
              await File('assets/fonts/Roboto-Regular.ttf').readAsBytes(),
            ),
          ),
        ))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('compact route actions use workbench badges in both themes', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await _pumpCards(tester, dark: dark);
      expect(tester.takeException(), isNull);
      expect(find.byType(UtenInProgressBadge), findsNWidgets(3));
      expect(find.byType(UtenNotificationBadge), findsNWidgets(3));
      for (final badge in tester.widgetList<UtenInProgressBadge>(
        find.byType(UtenInProgressBadge),
      )) {
        expect(badge.size, 20);
        expect(badge.showLabel, isTrue);
        _expectBadge(tester, find.byWidget(badge), UtenColors.warningStrong);
      }
      for (final badge in tester.widgetList<UtenNotificationBadge>(
        find.byType(UtenNotificationBadge),
      )) {
        expect(badge.size, 20);
        expect(badge.showLabel, isTrue);
        _expectBadge(tester, find.byWidget(badge), UtenColors.dangerStrong);
      }
      _expectOneRow(tester);
      for (final card in find.byType(MaterialPreparationRouteCard).evaluate()) {
        expect(tester.getSize(find.byWidget(card.widget)).width, 244);
        expect(
          tester.getSize(find.byWidget(card.widget)).height,
          lessThanOrEqualTo(56),
        );
      }
      await _capture(tester, dark ? 'dark.png' : 'light.png');
    }
  });

  testWidgets('256 wide actions keep 99+ badges in one row at text scale 1.5', (
    tester,
  ) async {
    await _pumpCards(tester, compact: true, textScale: 1.5, count: 99999);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'compact-large-text.png');
    for (final card in tester.widgetList<MaterialPreparationRouteCard>(
      find.byType(MaterialPreparationRouteCard),
    )) {
      expect(tester.getSize(find.byWidget(card)).width, 256);
    }
    expect(find.text('99999'), findsNothing);
    expect(find.text('99+'), findsNWidgets(6));
    for (final title in ['采购', '委外', '自制']) {
      expect(find.text(title), findsOneWidget);
    }
    _expectOneRow(tester);
    for (final number in find.text('99+').evaluate()) {
      final paragraph = number.findRenderObject()! as RenderParagraph;
      final boxes = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 3),
      );
      expect(
        boxes.map((box) => box.top).toSet(),
        hasLength(1),
        reason: 'A workbench badge must remain on a single line.',
      );
    }
  });

  testWidgets('status actions support keyboard and zero badges take no space', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final calls = <String>[];
      await _pumpCards(tester, calls: calls, zeroPending: true);
      final progress = tester.getSemantics(
        find.byKey(const Key('material-analysis-entry-buy-in-progress')),
      );
      expect(
        find.byKey(const Key('material-analysis-entry-buy-pending')),
        findsNothing,
      );
      expect(find.byType(UtenNotificationBadge), findsNothing);
      expect(progress.flagsCollection.isButton, isTrue);
      expect(progress.flagsCollection.isEnabled, ui.Tristate.isTrue);
      expect(progress.label, '下达采购，进行中 12');

      for (var step = 0; step < 6; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
      }
      expect(
        calls,
        unorderedEquals([
          'buy-open',
          'buy-in-progress',
          'subcontract-open',
          'subcontract-in-progress',
          'make-open',
          'make-in-progress',
        ]),
      );
      expect(
        progress.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      final titleWithBadge = tester.getSize(find.text('下达采购')).width;
      await _pumpCards(tester, count: 0, zeroPending: true);
      expect(find.byType(UtenInProgressBadge), findsNothing);
      expect(find.byType(UtenNotificationBadge), findsNothing);
      expect(find.text('0'), findsNothing);
      expect(
        tester.getSize(find.text('下达采购')).width,
        greaterThan(titleWithBadge),
      );
    } finally {
      semantics.dispose();
    }
  });
}

void _expectBadge(WidgetTester tester, Finder badge, Color color) {
  expect(UtenBadgeScale.of(tester.element(badge)), 1.25);
  final container = tester.widget<Container>(
    find.descendant(of: badge, matching: find.byType(Container)),
  );
  expect((container.decoration! as BoxDecoration).color, color);
}

void _expectOneRow(WidgetTester tester) {
  for (final card in find.byType(MaterialPreparationRouteCard).evaluate()) {
    final root = find.byWidget(card.widget);
    final route = card.widget as MaterialPreparationRouteCard;
    final title = find.descendant(
      of: root,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            (widget.data == route.title || widget.data == route.compactTitle),
      ),
    );
    for (final badgeType in [UtenInProgressBadge, UtenNotificationBadge]) {
      final badge = find.descendant(of: root, matching: find.byType(badgeType));
      expect(
        tester.getCenter(badge).dy,
        closeTo(tester.getCenter(title).dy, 1),
        reason: 'The route title and both status badges must share one row.',
      );
    }
  }
}

Future<void> _pumpCards(
  WidgetTester tester, {
  bool dark = false,
  bool compact = false,
  double textScale = 1,
  int count = 12,
  bool zeroPending = false,
  List<String>? calls,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = compact
      ? const Size(304, 320)
      : const Size(804, 144);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final cards = [
    for (final route in [
      (id: 'buy', title: '下达采购', icon: Icons.shopping_cart_outlined),
      (
        id: 'subcontract',
        title: '下达委外',
        icon: Icons.precision_manufacturing_outlined,
      ),
      (id: 'make', title: '下达自制', icon: Icons.factory_outlined),
    ])
      SizedBox(
        width: compact ? 256 : 244,
        child: MaterialPreparationRouteCard(
          routeId: route.id,
          title: route.title,
          compactTitle: route.title.replaceFirst('下达', ''),
          hint: '查看${route.title}任务及进度',
          icon: route.icon,
          inProgressLabel: '进行中',
          pendingLabel: '未下达',
          inProgressCount: count,
          pendingCount: zeroPending
              ? 0
              : count == 99999
              ? count
              : 3,
          onOpen: () => calls?.add('${route.id}-open'),
          onInProgress: count == 0
              ? null
              : () => calls?.add('${route.id}-in-progress'),
          onPending: zeroPending
              ? null
              : () => calls?.add('${route.id}-pending'),
        ),
      ),
  ];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: RepaintBoundary(
        key: const Key('material-preparation-capture'),
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Builder(
                  builder: (context) => Text(
                    '生产准备任务',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(spacing: 12, runSpacing: 12, children: cards),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['UTEN_UI_FIXTURES'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('material-preparation-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('.codex-tmp/material-preparation-ui')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
