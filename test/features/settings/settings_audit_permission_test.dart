import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/settings/pages/settings_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('settings hides local audit receipts without audit view access', (
    tester,
  ) async {
    await _pumpSettings(tester, const <String>{});

    expect(find.text('本机信息与操作回执'), findsNothing);
    expect(find.text('修改密码'), findsOneWidget);
  });

  testWidgets('settings shows local audit receipts with audit view access', (
    tester,
  ) async {
    await _pumpSettings(tester, const {Perm.auditLogView});

    expect(find.text('本机信息与操作回执'), findsOneWidget);
    expect(find.text('按本地操作 ID 核查这台设备保存的回执'), findsOneWidget);
  });
}

Future<void> _pumpSettings(WidgetTester tester, Set<String> permissions) async {
  tester.view.physicalSize = const Size(1200, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
