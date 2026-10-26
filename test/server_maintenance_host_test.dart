import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/maintenance/server_maintenance.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/widgets/server_maintenance_host.dart';

const _notice = 'cf32fe33-3f9c-4839-93ba-465b1e242096';
final _now = DateTime.utc(2026, 10, 26, 12);

ServerMaintenanceSnapshot _status(ServerMaintenancePhase phase) =>
    ServerMaintenanceSnapshot(
      phase: phase,
      serverTime: _now,
      noticeId: _notice,
      startsAt: _now.add(const Duration(minutes: 10)),
      targetVersion: 'v2.5.32',
    );

Widget _app(
  ServerMaintenanceController controller,
  TextEditingController input, {
  double scale = 1,
}) => MaterialApp(
  theme: buildLightTheme(),
  locale: const Locale('zh'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: ServerMaintenanceView(
    controller: controller,
    child: Scaffold(
      body: TextField(controller: input, key: const ValueKey('editor')),
    ),
  ),
);

void main() {
  testWidgets(
    'one notice, keyboard acknowledge, cancellation and input survive',
    (tester) async {
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
      await controller.checkNow();
      await tester.pump();
      expect(reminder, findsNothing);
      status = _status(ServerMaintenancePhase.available);
      await controller.checkNow();
      await tester.pump();
      expect(find.text('查看更新提醒'), findsNothing);
      expect(input.text, '未保存的原始输入');
      status = _status(ServerMaintenancePhase.updating);
      await controller.checkNow();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('server-maintenance-page')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('editor')), findsOneWidget);
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

  testWidgets('narrow screen with large text scrolls reminder and recovery', (
    tester,
  ) async {
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
