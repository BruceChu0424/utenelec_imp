import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';

/// Keep render constraints and MediaQuery's real window in agreement. Updating
/// only binding.setSurfaceSize leaves responsive policies at the default view.
Future<void> setUtenTestSurfaceSize(WidgetTester tester, Size? size) async {
  if (size == null) {
    tester.view.resetPhysicalSize();
  } else {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
  }
  await tester.binding.setSurfaceSize(size);
}

/// Reveal a retained action through the same dropdown a user can open. Never
/// operate the unpainted branch of a responsive action control.
Future<void> showUtenTestAction(
  WidgetTester tester,
  Finder action, {
  String menuLabel = '表格操作',
  Finder? menuScope,
  bool settle = true,
}) async {
  expect(
    await showOptionalUtenTestAction(
      tester,
      action,
      menuLabel: menuLabel,
      menuScope: menuScope,
      settle: settle,
    ),
    isTrue,
    reason: 'The visible control or opened menu must expose the action',
  );
  await tester.ensureVisible(action);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  expect(action.hitTestable(), findsWidgets);
}

Future<void> tapUtenTestAction(
  WidgetTester tester,
  Finder action, {
  String menuLabel = '表格操作',
  Finder? menuScope,
}) async {
  await showUtenTestAction(
    tester,
    action,
    menuLabel: menuLabel,
    menuScope: menuScope,
  );
  await tester.tap(action);
}

/// A fixture without any hierarchy can legitimately omit expansion. Inspect
/// the real menu before deciding whether that optional action exists.
Future<bool> showOptionalUtenTestAction(
  WidgetTester tester,
  Finder action, {
  String menuLabel = '表格操作',
  Finder? menuScope,
  bool settle = true,
}) async {
  if (action.hitTestable().evaluate().isNotEmpty) return true;
  final menu = find.byTooltip(menuLabel);
  final trigger =
      (menuScope == null
              ? menu
              : find.descendant(of: menuScope, matching: menu))
          .hitTestable();
  if (trigger.evaluate().isEmpty) return false;
  expect(trigger, findsOneWidget);
  await tester.tap(trigger);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  if (action.evaluate().isNotEmpty) return true;
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
  return false;
}

/// Lazy append rows need a real scroll before ensureVisible can locate them.
Future<void> scrollUtenTestTableItemIntoView(
  WidgetTester tester,
  Finder item,
) async {
  final body = find.byWidgetPredicate(
    (widget) =>
        widget is UtenPageScrollbarSource &&
        widget.debugLabel == 'master-table-body',
  );
  expect(body, findsOneWidget);
  final viewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  for (var attempt = 0; item.evaluate().isEmpty && attempt < 20; attempt++) {
    final visible = tester.getRect(body).intersect(viewport);
    expect(visible.height, greaterThan(0));
    await tester.dragFrom(visible.center, const Offset(0, -140));
    await tester.pumpAndSettle();
  }
  expect(item, findsOneWidget);
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  expect(item.hitTestable(), findsOneWidget);
}

/// The one vertical body owned by a particular table, excluding toolbar or
/// surrounding-page scrollables. Used when preserving a real table offset.
ScrollController utenTestTableBodyController(
  WidgetTester tester,
  Finder table,
) {
  final body = find.descendant(
    of: table,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is UtenPageScrollbarSource &&
          widget.debugLabel == 'master-table-body',
    ),
  );
  expect(body, findsOneWidget);
  final controller = tester.widget<UtenPageScrollbarSource>(body).controller;
  expect(controller.hasClients, isTrue);
  expect(controller.positions, hasLength(1));
  expect(controller.position.axis, Axis.vertical);
  expect(controller.position.viewportDimension, greaterThan(0));
  expect(controller.position.maxScrollExtent, greaterThan(0));
  return controller;
}
