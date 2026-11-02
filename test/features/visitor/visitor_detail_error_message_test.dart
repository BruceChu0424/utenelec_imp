import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/visitor/pages/visitor_application_detail_page.dart';
import 'package:uten_imp/features/visitor/providers/visitor_providers.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final sample in [
    (
      error: ApiException('FORBIDDEN', 'Forbidden', httpStatus: 403),
      message: '此账号没有进行该操作的权限，请联系管理员',
    ),
    (error: StateError('这份预约已撤回，请返回列表核对'), message: '这份预约已撤回，请返回列表核对'),
    (error: StateError('No element'), message: '预约详情读取失败，请稍后重试'),
  ]) {
    testWidgets(
      'visitor detail explains ${sample.error.runtimeType} and keeps retry',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        var requests = 0;
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              visitorApplicationDetailProvider('application').overrideWith((
                ref,
              ) async {
                requests++;
                throw sample.error;
              }),
            ],
            child: const MaterialApp(
              locale: Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: VisitorApplicationDetailPage(applicationId: 'application'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(sample.message), findsOneWidget);
        expect(find.textContaining('ApiException('), findsNothing);
        expect(find.textContaining('Bad state:'), findsNothing);
        expect(find.textContaining('No element'), findsNothing);
        expect(requests, 1);
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(requests, 2);
        expect(find.text(sample.message), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
