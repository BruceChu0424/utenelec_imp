import 'dart:async';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/pages/finance_applications_page.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'source-user',
      employeeId: 'source-employee',
      code: 'ANON',
      name: '匿名经办',
      department: '财务',
      permissions: [Perm.expenseApply],
    ),
  );
}

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void advance() => state++;
}

class _Sources extends ApiClient {
  _Sources(this.result) : super(Dio());
  final Future<Map<String, dynamic>> result;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) => result;
}

Future<({ProviderContainer container, Future<void> Function() close})>
openPicker(
  WidgetTester tester,
  Future<Map<String, dynamic>> result,
  void Function(Map<String, dynamic>?) selected,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1100, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWith(_Session.new),
      apiBaseUrlProvider.overrideWithValue('https://source.invalid/api'),
      sharedPreferencesProvider.overrideWithValue(preferences),
      apiClientProvider.overrideWithValue(_Sources(result)),
      exportContextEpochProvider.overrideWith(_Epoch.new),
    ],
  );
  var disposed = false;
  Future<void> close() async {
    if (disposed) return;
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    disposed = true;
    await tester.pump();
  }

  addTearDown(close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected(
                  await pickFinanceApplicationSource(
                    context,
                    kind: 'TRAVEL_APPLICATION',
                  ),
                );
              },
              child: const Text('选择出差来源'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('选择出差来源'));
  await tester.pump();
  return (container: container, close: close);
}

void main() {
  testWidgets(
    'equal UUIDs from the two source tables remain distinct choices',
    (tester) async {
      Map<String, dynamic>? selected;
      final handle = await openPicker(
        tester,
        Future.value({
          'items': [
            {
              'id': 'shared-id',
              'sourceKind': 'BUSINESS_APPLICATION',
              'code': 'NATIVE-TRAVEL',
              'name': '匿名新出差',
            },
            {
              'id': 'shared-id',
              'sourceKind': 'FINANCE_APPLICATION',
              'code': 'LEGACY-TRAVEL',
              'name': '匿名原出差',
            },
          ],
        }),
        (value) => selected = value,
      );
      await tester.pumpAndSettle();
      expect(find.text('NATIVE-TRAVEL'), findsOneWidget);
      expect(find.text('LEGACY-TRAVEL'), findsOneWidget);
      await tester.tap(find.text('LEGACY-TRAVEL'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('LEGACY-TRAVEL'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(selected?['id'], 'shared-id');
      expect(selected?['sourceKind'], 'FINANCE_APPLICATION');
      expect(tester.takeException(), isNull);
      await handle.close();
    },
  );
  testWidgets(
    'reader replacement removes the busy overlay and rejects the old response',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final handle = await openPicker(tester, pending.future, (_) {});
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('正在读取申请来源'), findsOneWidget);
      (handle.container.read(exportContextEpochProvider.notifier) as _Epoch)
          .advance();
      await tester.pumpAndSettle();
      expect(find.text('正在读取申请来源'), findsNothing);
      pending.complete({
        'items': [
          {
            'id': 'old',
            'sourceKind': 'BUSINESS_APPLICATION',
            'code': 'OLD-RESPONSE',
            'name': '匿名旧结果',
          },
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('OLD-RESPONSE'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('选择出差来源'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await handle.close();
    },
  );
}
