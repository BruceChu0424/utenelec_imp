import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/payroll/models/payroll_slip.dart';
import 'package:uten_imp/features/payroll/pages/payroll_slip_list_page.dart';
import 'package:uten_imp/features/payroll/providers/payroll_providers.dart';
import 'package:uten_imp/features/suggestion/models/suggestion.dart';
import 'package:uten_imp/features/suggestion/pages/suggestion_list_page.dart';
import 'package:uten_imp/features/suggestion/providers/suggestion_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/retained_async_page.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

// Deliberately keep the legacy master-data key and API instance unchanged.
// Only the new reader fence can retire the cached rows in these cases.
final _server = StateProvider<String>((ref) => 'https://server-a.invalid/api');
final _permissions = StateProvider<Set<String>>((ref) => {'reader-a'});

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Api extends ApiClient {
  _Api(this.payroll) : super(Dio());
  final bool payroll;
  final requests = <Completer<Map<String, dynamic>>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != (payroll ? '/payroll/slips' : '/suggestions')) return const {};
    final gate = Completer<Map<String, dynamic>>();
    requests.add(gate);
    return gate.future;
  }

  Map<String, dynamic> result(String label) => {
    'items': [
      if (payroll)
        {
          'id': label,
          'employeeId': 'employee',
          'employeeName': label,
          'employeeCode': label,
          'year': 2026,
          'month': 10,
          'grossIncome': 123,
          'totalDeduction': 23,
          'netIncome': 100,
          'status': 'PUBLISHED',
        }
      else
        {
          'id': label,
          'submitterId': 'employee',
          'submitterName': '员工',
          'title': label,
          'content': label,
          'category': 'other',
          'status': 'submitted',
          'submittedAt': '2026-10-26T00:00:00Z',
        },
    ],
    'page': 1,
    'size': 20,
    'total': 1,
    'totalPages': 1,
  };
}

Future<ProviderContainer> _mount(WidgetTester tester, _Api api) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    retry: (count, error) => null,
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'same-reader'),
      ),
      masterDataSessionKeyProvider.overrideWithValue('unchanged-legacy-key'),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      sharedPreferencesProvider.overrideWithValue(preferences),
      isSuperAdminProvider.overrideWithValue(false),
      fixedBadgeSummaryOverride(badgeSummaryFixture()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: api.payroll
            ? const PayrollSlipListPage()
            : const SuggestionListPage(),
      ),
    ),
  );
  await tester.pump();
  expect(api.requests, hasLength(1), reason: '首次挂载不能额外重放冷请求');
  api.requests.single.complete(api.result('PRIVATE-A'));
  await tester.pumpAndSettle();
  return container;
}

List<String> _visible(WidgetTester tester, bool payroll) => payroll
    ? tester
          .widget<MasterDataTableView<PayrollSlip>>(
            find.byType(MasterDataTableView<PayrollSlip>),
          )
          .items
          .map((row) => row.id)
          .toList()
    : tester
          .widget<MasterDataTableView<Suggestion>>(
            find.byType(MasterDataTableView<Suggestion>),
          )
          .items
          .map((row) => row.id)
          .toList();

void main() {
  for (final error in [
    ApiException('UNAUTHORIZED', 'denied', httpStatus: 401),
    ApiException('FORBIDDEN', 'denied', httpStatus: 403),
    ApiException('READ_SCOPE_CHANGED', 'changed', httpStatus: 409),
    ApiException('SESSION_CHANGED', 'changed', httpStatus: 409),
    ApiException('SESSION_STATE_UNAVAILABLE', 'unknown', httpStatus: 409),
  ]) {
    test('${error.code} retires retained rows through a later retry', () {
      final page = RetainedAsyncPage<List<String>>();
      page.resolve('query', const AsyncData(['private']));
      final denied = page.resolve(
        'query',
        AsyncError(error, StackTrace.current),
      );
      expect(denied.hasError, isTrue);
      expect(denied.hasValue, isFalse);
      expect(page.resolve('query', const AsyncLoading()).hasValue, isFalse);
    });
  }

  for (final payroll in [false, true]) {
    final name = payroll ? '工资条' : '建议列表';
    for (final boundary in ['server', 'permissions']) {
      testWidgets('$name $boundary A-B-A期间不复活旧值，迟到B响应不能覆盖A新读', (tester) async {
        final api = _Api(payroll);
        final container = await _mount(tester, api);
        expect(_visible(tester, payroll), ['PRIVATE-A']);
        if (boundary == 'server') {
          container.read(_server.notifier).state =
              'https://server-b.invalid/api';
        } else {
          container.read(_permissions.notifier).state = {'reader-b'};
        }
        await tester.pump();
        expect(_visible(tester, payroll), isEmpty);
        expect(api.requests, hasLength(2));
        if (boundary == 'server') {
          container.read(_server.notifier).state =
              'https://server-a.invalid/api';
        } else {
          container.read(_permissions.notifier).state = {'reader-a'};
        }
        await tester.pump();
        expect(_visible(tester, payroll), isEmpty);
        expect(api.requests, hasLength(3));
        api.requests[1].complete(api.result('STALE-B'));
        await tester.pump();
        expect(_visible(tester, payroll), isEmpty);
        api.requests[2].complete(api.result('FRESH-A'));
        await tester.pumpAndSettle();
        expect(_visible(tester, payroll), ['FRESH-A']);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$name 同查询403清除已读行及重试期间保留值', (tester) async {
      final api = _Api(payroll);
      final container = await _mount(tester, api);
      if (payroll) {
        container.invalidate(payrollListProvider);
      } else {
        container.invalidate(suggestionListProvider);
      }
      await tester.pump();
      api.requests.last.completeError(
        ApiException('FORBIDDEN', 'denied', httpStatus: 403),
      );
      await tester.pumpAndSettle();
      expect(_visible(tester, payroll), isEmpty);
      if (payroll) {
        container.invalidate(payrollListProvider);
      } else {
        container.invalidate(suggestionListProvider);
      }
      await tester.pump();
      expect(_visible(tester, payroll), isEmpty);
      api.requests.last.complete(api.result('AFTER-RETRY'));
      await tester.pumpAndSettle();
      expect(_visible(tester, payroll), ['AFTER-RETRY']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('建议手动刷新旧回执不能写入新服务器代次', (tester) async {
    final api = _Api(false);
    final container = await _mount(tester, api);
    final oldRefresh = container
        .read(suggestionListProvider.notifier)
        .refresh();
    await tester.pump();
    expect(api.requests, hasLength(2));
    container.read(_server.notifier).state = 'https://server-b.invalid/api';
    await tester.pump();
    expect(api.requests, hasLength(3));
    api.requests[1].complete(api.result('STALE-A-REFRESH'));
    await oldRefresh;
    await tester.pump();
    expect(_visible(tester, false), isEmpty);
    api.requests[2].complete(api.result('NEW-SERVER'));
    await tester.pumpAndSettle();
    expect(_visible(tester, false), ['NEW-SERVER']);
    expect(tester.takeException(), isNull);
  });
}
