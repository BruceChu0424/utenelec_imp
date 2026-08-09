import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('login exposes a labeled secondary server recovery action', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LoginPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final recovery = find.text('恢复自动选择服务器');
    expect(recovery, findsOneWidget);
    expect(find.textContaining('只会在此安装包内置的公司与云端地址之间自动选择'), findsOneWidget);
    expect(tester.getSemantics(recovery).flagsCollection.isButton, isTrue);
  });
}
