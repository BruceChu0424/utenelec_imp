import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/maintenance/server_maintenance.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/widgets/server_maintenance_host.dart';

import 'support/audit_screenshot_support.dart';

const _captureScreenshots = bool.fromEnvironment('UTEN_CAPTURE_MAINTENANCE');
const _notice = 'cf32fe33-3f9c-4839-93ba-465b1e242096';
final _now = DateTime.utc(2026, 10, 26, 12);
final _captureBoundary = GlobalKey();

ServerMaintenanceSnapshot _status(
  ServerMaintenancePhase phase, {
  Duration remaining = const Duration(minutes: 10),
}) => ServerMaintenanceSnapshot(
  phase: phase,
  serverTime: _now,
  noticeId: _notice,
  startsAt: _now.add(remaining),
  targetVersion: 'v2.5.32',
);

Widget _app(
  ServerMaintenanceController controller,
  TextEditingController input, {
  double scale = 1,
  bool visible = true,
  bool animateCountdown = true,
  bool disableAnimations = false,
  EdgeInsets padding = EdgeInsets.zero,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) => MaterialApp(
  theme: _captureScreenshots
      ? auditScreenshotTheme(buildLightTheme())
      : buildLightTheme(),
  locale: const Locale('zh'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: disableAnimations,
      padding: padding,
      viewInsets: viewInsets,
    ),
    child: child!,
  ),
  home: RepaintBoundary(
    key: _captureBoundary,
    child: ServerMaintenanceView(
      controller: controller,
      visible: visible,
      animateCountdown: animateCountdown,
      child: Scaffold(
        body: TextField(controller: input, key: const ValueKey('editor')),
      ),
    ),
  ),
);

Future<void> _prepareCapture(WidgetTester tester) async {
  if (_captureScreenshots) await loadAuditScreenshotFonts(tester);
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (_captureScreenshots) {
    await tester.pump();
    await saveAuditScreenshot(tester, _captureBoundary, name);
  }
}

final _countdown = find.byKey(const ValueKey('server-maintenance-countdown'));
final _reminder = find.byKey(const ValueKey('server-maintenance-reminder'));

BoxDecoration _countdownDecoration(WidgetTester tester) =>
    tester
            .widget<DecoratedBox>(
              find.byKey(
                const ValueKey('server-maintenance-countdown-surface'),
              ),
            )
            .decoration
        as BoxDecoration;

Color? _countdownTextColor(WidgetTester tester) {
  final timer = find.descendant(
    of: _countdown,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Text && RegExp(r'^\d+:\d{2}$').hasMatch(widget.data ?? ''),
    ),
  );
  final text = tester.widget<Text>(timer);
  return text.style?.color ??
      DefaultTextStyle.of(tester.element(timer)).style.color;
}

Future<void> _acknowledge(WidgetTester tester) async {
  expect(_reminder, findsOneWidget);
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump();
  expect(_reminder, findsNothing);
}

Future<void> _dispose(
  WidgetTester tester,
  ServerMaintenanceController controller,
  TextEditingController input,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  input.dispose();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'one notice, keyboard acknowledge, cancellation and input survive',
    (tester) async {
      await _prepareCapture(tester);
      var status = _status(ServerMaintenancePhase.available);
      final controller = ServerMaintenanceController(
        read: () async => status,
        ready: () async => true,
      );
      final input = TextEditingController();
      await tester.pumpWidget(_app(controller, input));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('editor')), '未保存的原始输入');
      status = _status(ServerMaintenancePhase.scheduled);
      await controller.checkNow();
      await tester.pump();
      final reminder = find.byKey(
        const ValueKey('server-maintenance-reminder'),
      );
      expect(reminder, findsOneWidget);
      final dialogSurface = find
          .descendant(of: reminder, matching: find.byType(Material))
          .first;
      expect(tester.getSize(dialogSurface).width, lessThanOrEqualTo(520));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(reminder, findsNothing);
      expect(_countdown, findsOneWidget);
      await controller.checkNow();
      await tester.pump();
      expect(reminder, findsNothing);
      status = _status(ServerMaintenancePhase.available);
      await controller.checkNow();
      await tester.pump();
      expect(find.text('查看更新提醒'), findsNothing);
      expect(_countdown, findsNothing);
      expect(input.text, '未保存的原始输入');
      status = _status(ServerMaintenancePhase.updating);
      await controller.checkNow();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('server-maintenance-page')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('editor')), findsOneWidget);
      expect(_countdown, findsNothing);
      status = _status(ServerMaintenancePhase.available);
      await controller.checkNow();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('server-maintenance-page')),
        findsNothing,
      );
      expect(input.text, '未保存的原始输入');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      input.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('countdown drags without reopening or losing page input', (
    tester,
  ) async {
    await _prepareCapture(tester);
    final status = _status(ServerMaintenancePhase.scheduled);
    final controller = ServerMaintenanceController(
      read: () async => status,
      ready: () async => true,
    );
    final input = TextEditingController(text: '未保存的原始输入');
    await tester.pumpWidget(_app(controller, input));
    await tester.pump();
    await _acknowledge(tester);
    final initial = tester.getRect(_countdown);
    expect(initial.width, lessThan(260));
    expect(initial.top, lessThan(100));
    expect(initial.center.dx, greaterThan(400));
    await _capture(tester, 'server-maintenance-countdown-normal');

    await tester.drag(_countdown, const Offset(-180, 140));
    await tester.pump();
    final moved = tester.getRect(_countdown);
    expect(moved.left, lessThan(initial.left - 100));
    expect(moved.top, greaterThan(initial.top + 80));
    expect(_reminder, findsNothing);
    expect(input.text, '未保存的原始输入');
    await _capture(tester, 'server-maintenance-countdown-dragged');

    await controller.checkNow();
    await tester.pump();
    expect(tester.getRect(_countdown), moved);
    await tester.tap(find.byKey(const ValueKey('editor')));
    await tester.enterText(find.byKey(const ValueKey('editor')), '继续编辑');
    expect(input.text, '继续编辑');

    await tester.tap(_countdown);
    await tester.pump();
    expect(_reminder, findsOneWidget);
    await _acknowledge(tester);
    expect(_countdown, findsOneWidget);
    expect(input.text, '继续编辑');
    await _dispose(tester, controller, input);
  });

  testWidgets(
    'drag and resize keep large countdown inside safe visible bounds',
    (tester) async {
      await _prepareCapture(tester);
      tester.view.physicalSize = const Size(1000, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final status = _status(ServerMaintenancePhase.scheduled);
      final controller = ServerMaintenanceController(
        read: () async => status,
        ready: () async => true,
      );
      final input = TextEditingController(text: '保留');
      const padding = EdgeInsets.fromLTRB(12, 30, 20, 18);
      const keyboard = EdgeInsets.only(bottom: 160);
      await tester.pumpWidget(
        _app(controller, input, padding: padding, viewInsets: keyboard),
      );
      await tester.pump();
      await _acknowledge(tester);
      await tester.drag(_countdown, const Offset(-2000, -2000));
      await tester.pump();
      var rect = tester.getRect(_countdown);
      expect(rect.left, greaterThanOrEqualTo(28));
      expect(rect.top, greaterThanOrEqualTo(46));
      await tester.drag(_countdown, const Offset(3000, 3000));
      await tester.pump();
      rect = tester.getRect(_countdown);
      expect(rect.right, lessThanOrEqualTo(964));
      expect(rect.bottom, lessThanOrEqualTo(544));

      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpWidget(
        _app(
          controller,
          input,
          scale: 2,
          padding: padding,
          viewInsets: keyboard,
        ),
      );
      await tester.pump();
      rect = tester.getRect(_countdown);
      expect(rect.left, greaterThanOrEqualTo(28));
      expect(rect.top, greaterThanOrEqualTo(46));
      expect(rect.right, lessThanOrEqualTo(284));
      expect(rect.bottom, lessThanOrEqualTo(392));
      expect(tester.takeException(), isNull);
      expect(input.text, '保留');
      await _capture(tester, 'server-maintenance-countdown-narrow-large-text');
      await _dispose(tester, controller, input);
    },
  );

  testWidgets('last minute glows red and respects animation and visibility', (
    tester,
  ) async {
    await _prepareCapture(tester);
    var status = _status(
      ServerMaintenancePhase.scheduled,
      remaining: const Duration(seconds: 61),
    );
    final controller = ServerMaintenanceController(
      read: () async => status,
      ready: () async => true,
    );
    final input = TextEditingController();
    await tester.pumpWidget(_app(controller, input));
    await tester.pump();
    await _acknowledge(tester);
    final scheme = Theme.of(tester.element(_countdown)).colorScheme;
    expect(_countdownTextColor(tester), scheme.primary);
    final ordinary = _countdownDecoration(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_countdownDecoration(tester), ordinary);

    status = _status(
      ServerMaintenancePhase.scheduled,
      remaining: const Duration(seconds: 59),
    );
    await controller.checkNow();
    await tester.pump();
    await _acknowledge(tester);
    expect(_countdownTextColor(tester), scheme.error);
    final urgent = _countdownDecoration(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_countdownDecoration(tester), isNot(urgent));
    expect(_countdownTextColor(tester), scheme.error);
    await _capture(tester, 'server-maintenance-countdown-urgent');

    await tester.pumpWidget(_app(controller, input, disableAnimations: true));
    await tester.pump();
    final reducedMotion = _countdownDecoration(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_countdownDecoration(tester), reducedMotion);
    expect(_countdownTextColor(tester), scheme.error);

    await tester.pumpWidget(_app(controller, input, animateCountdown: false));
    await tester.pump();
    final lowPower = _countdownDecoration(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_countdownDecoration(tester), lowPower);

    await tester.pumpWidget(_app(controller, input, visible: false));
    await tester.pump();
    final hidden = _countdownDecoration(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(_countdownDecoration(tester), hidden);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(_app(controller, input));
    await tester.pump();
    final resumed = _countdownDecoration(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_countdownDecoration(tester), isNot(resumed));

    status = _status(
      ServerMaintenancePhase.scheduled,
      remaining: Duration.zero,
    );
    await controller.checkNow();
    await tester.pump();
    await _acknowledge(tester);
    expect(
      find.descendant(of: _countdown, matching: find.text('00:00')),
      findsOneWidget,
    );
    expect(_countdownTextColor(tester), scheme.error);
    expect(find.byKey(const ValueKey('server-maintenance-page')), findsNothing);

    status = _status(ServerMaintenancePhase.available);
    await controller.checkNow();
    await tester.pump();
    expect(_countdown, findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await _dispose(tester, controller, input);
  });

  testWidgets('narrow screen with large text scrolls reminder and recovery', (
    tester,
  ) async {
    await _prepareCapture(tester);
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var status = _status(ServerMaintenancePhase.scheduled);
    final controller = ServerMaintenanceController(
      read: () async => status,
      ready: () async => true,
    );
    final input = TextEditingController(text: '保留');
    await tester.pumpWidget(_app(controller, input, scale: 2));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('server-maintenance-reminder')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    status = _status(ServerMaintenancePhase.recoveryRequired);
    await controller.checkNow();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('server-maintenance-page')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    expect(input.text, '保留');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    input.dispose();
  });
}
