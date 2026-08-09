import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/pages/basic_data_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

Widget _app(Set<String> permissions) {
  return ProviderScope(
    overrides: [currentPermissionsProvider.overrideWithValue(permissions)],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('zh'),
      home: BasicDataHubPage(),
    ),
  );
}

void main() {
  testWidgets('basic-data hub only exposes authorized resources', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const {Perm.goodsView, Perm.currencyView}));

    expect(find.text('货品资料'), findsOneWidget);
    expect(find.text('币种资料'), findsOneWidget);
    expect(find.text('客户资料'), findsNothing);
    expect(find.text('账户资料'), findsNothing);
  });
}
