import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_page.dart';
import 'package:uten_imp/features/finance/pages/finance_reconciliation_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Permissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void replace(Set<String> permissions) => state = permissions;
}

final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);

class _Api extends ApiClient {
  _Api() : super(Dio());
  final pending = <Completer<Map<String, dynamic>>>[];

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    if (path == '/finance/ar-ap' || path == '/finance/reconciliations') {
      final result = Completer<Map<String, dynamic>>();
      pending.add(result);
      return result.future;
    }
    return Future.value({});
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

Map<String, dynamic> _response({bool large = false}) => {
  'items': [
    {
      'id': 'row-1',
      'billNo': 'reader-A-secret',
      'billDate': '2026-10-23T12:00:00',
      'direction': 'AR',
    },
  ],
  'page': 1,
  'size': 20,
  'total': 1,
  'totalPages': 1,
  'facets': {
    if (large)
      'billNo': List.generate(
        4000,
        (i) => {'value': '$i', 'label': '$i', 'count': 1},
      ),
  },
};

Future<ProviderContainer> _mount(
  WidgetTester tester,
  Widget page,
  _Api api,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1500, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'A'),
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  for (var i = 0; i < 10 && api.pending.isEmpty; i++) {
    await tester.pump();
  }
  expect(api.pending, isNotEmpty);
  return ProviderScope.containerOf(
    tester.element(find.byType(page.runtimeType)),
  );
}

void _aba(ProviderContainer container) {
  final epoch = container.read(exportContextEpochProvider);
  container.read(_permissions.notifier).replace({'reader-B'});
  container.read(exportContextEpochProvider);
  container.read(_permissions.notifier).replace({});
  expect(container.read(exportContextEpochProvider), greaterThan(epoch + 1));
}

void main() {
  final pages = <String, Widget>{
    'ar-ap': const FinanceArApPage(),
    'reconciliation': const FinanceReconciliationPage(),
  };
  for (final entry in pages.entries) {
    testWidgets(
      '${entry.key} rejects a read if owner changes inside large DTO decoding',
      (tester) async {
        final api = _Api();
        final container = await _mount(tester, entry.value, api);
        var changed = false;
        final previous = debugUiWorkSliceObserver;
        debugUiWorkSliceObserver = (_, _) {
          if (changed) return;
          changed = true;
          _aba(container);
        };
        addTearDown(() => debugUiWorkSliceObserver = previous);
        api.pending.single.complete(_response(large: true));
        await tester.pumpAndSettle();
        expect(changed, isTrue);
        expect(find.textContaining('reader-A-secret'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('${entry.key} clears accepted data on owner ABA', (
      tester,
    ) async {
      final api = _Api();
      final container = await _mount(tester, entry.value, api);
      api.pending.single.complete(_response());
      await tester.pumpAndSettle();
      expect(find.textContaining('reader-A-secret'), findsWidgets);
      _aba(container);
      await tester.pumpAndSettle();
      expect(find.textContaining('reader-A-secret'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
