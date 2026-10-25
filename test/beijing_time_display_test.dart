import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_progress_timeline.dart';
import 'package:uten_imp/components/settings/uten_time_display_switcher.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/core/utils/display_datetime.dart';
import 'package:uten_imp/features/visitor/models/visitor_application.dart';
import 'package:uten_imp/features/visitor/widgets/visitor_status_ui.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/time_display_provider.dart';

void main() {
  test('不同偏移与无偏移输入均显示北京时间且仅有一个后缀', () {
    for (final raw in [
      '2026-12-31T16:00:05Z',
      '2026-12-31T09:00:05-07:00',
      '2027-01-01T00:00:05+08:00',
      '2027-01-01T00:00:05',
    ]) {
      expect(DisplayDateTime.beijing(raw), '2027-01-01 00:00(北京)');
      expect(DisplayDateTime.format(raw, local: true), '2027-01-01 00:00(北京)');
      expect(
        ChinaDateTime.formatIsoInstant(raw, seconds: true),
        '2027-01-01 00:00:05(北京)',
      );
      expect(UtenProgressTimeline.formatTime(raw), '2027-01-01 00:00(北京)');
    }
    expect(DisplayDateTime.beijing('bad', fallback: '—'), '—');
    expect(UtenProgressTimeline.formatTime('bad'), 'bad');
  });

  test('北京墙上时间不受设备夏令时缺口影响，机器时间仍是同一instant', () {
    final wall = ChinaDateTime.tryParse('2026-03-08T02:30:00')!;
    expect(ChinaDateTime.formatDateTime(wall), '2026-03-08 02:30(北京)');
    expect(
      DisplayDateTime.instantOf('2026-03-08T02:30:00'),
      DateTime.utc(2026, 3, 7, 18, 30),
    );
    expect(
      DisplayDateTime.instantOf('2026-03-08T02:30:00+08:00'),
      DateTime.utc(2026, 3, 7, 18, 30),
    );
    expect(
      ChinaDateTime.wallTimeToUtc(wall).toIso8601String(),
      '2026-03-07T18:30:00.000Z',
    );
    expect(ChinaDateTime.formatDate(wall), '2026-03-08');
  });

  test('访客模型已经转换的墙上时间不重复加八小时', () {
    final app = VisitorApplication.fromJson({
      'id': 'visitor-time',
      'visitorName': '访客',
      'visitPurpose': '商务',
      'status': 'pending',
      'plannedVisitAt': '2026-07-30T18:30:00Z',
      'appliedAt': '2026-07-30T09:15:00+08:00',
    });
    expect(fmtDateTime(app.plannedVisitAt), contains('02:30(北京)'));
    expect(fmtDateTime(app.plannedVisitAt), isNot(contains('10:30')));
    expect(fmtDateTime(app.appliedAt), contains('09:15(北京)'));
  });

  test('旧local偏好和旧写入接口都不能切回设备时区', () async {
    SharedPreferences.setMockInitialValues({'timeDisplayMode': 'local'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    expect(container.read(timeDisplayModeProvider), TimeDisplayMode.beijing);
    await container
        .read(timeDisplayModeProvider.notifier)
        .set(TimeDisplayMode.local);
    expect(container.read(timeDisplayModeProvider), TimeDisplayMode.beijing);
    expect(prefs.getString('timeDisplayMode'), 'beijing');
    await container.read(timeDisplayModeProvider.notifier).toggle();
    expect(container.read(timeDisplayModeProvider), TimeDisplayMode.beijing);
  });

  testWidgets('设置只说明统一北京时间，不再提供当地时间切换', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UtenTimeDisplaySwitcher())),
    );
    expect(find.text('北京时间(UTC+8)'), findsOneWidget);
    expect(find.textContaining('当地时间'), findsNothing);
    expect(find.byType(RadioListTile<String>), findsNothing);
  });
}
