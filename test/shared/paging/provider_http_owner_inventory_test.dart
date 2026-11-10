import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_mutation_reload_safety.dart';
import 'package:uten_imp/core/network/api_provider_retry.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/applications/providers/business_application_providers.dart';
import 'package:uten_imp/features/dashboard/providers/dashboard_overview_provider.dart';
import 'package:uten_imp/features/hr_task/providers/hr_task_summary_provider.dart';
import 'package:uten_imp/features/department/providers/my_department_providers.dart';
import 'package:uten_imp/features/employee/providers/employee_picker_department_tree_provider.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:uten_imp/features/payroll/providers/payroll_providers.dart';
import 'package:uten_imp/features/profile/providers/profile_change_providers.dart';
import 'package:uten_imp/features/quality/providers/production_fqc_capability_provider.dart';
import 'package:uten_imp/features/suggestion/providers/suggestion_providers.dart';
import 'package:uten_imp/features/visitor/network/visitor_api_client.dart';
import 'package:uten_imp/features/visitor/providers/visitor_providers.dart';
import 'package:uten_imp/features/visitor/providers/visitor_session_provider.dart';
import 'package:uten_imp/features/visitor_approval/providers/visitor_approval_providers.dart';
import 'package:uten_imp/features/webinquiry/providers/website_inquiry_providers.dart';
import 'package:uten_imp/features/website_management/providers/website_management_providers.dart';
import 'package:uten_imp/features/website_management/repositories/website_management_repository.dart';
import 'package:uten_imp/shared/ai/ai_status_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/accounting_expense_purpose.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/providers/document_status_counts_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/paging/shared_read_provider_owner.dart';
import '../../helpers/badge_summary_fixture.dart';

const _id = '00000000-0000-0000-0000-000000000001';
final _cases = <String, ProviderListenable<Object?>>{
  'employee picker department tree': employeePickerDepartmentTreeProvider,
  'business application detail': businessApplicationDetailProvider(_id),
  'business application counts': businessApplicationCountsProvider,
  'expense settings': expenseSettingsProvider,
  'expense mine facets': expenseMineFacetsProvider,
  'expense detail': expenseDetailProvider(_id),
  'expense history detail': expenseHistoryDetailProvider(_id),
  'expense queue summary': expenseQueueSummaryProvider,
  'expense approval facets': expenseApprovalFacetsProvider(
    ApprovalQueue.pending,
  ),
  'expense payment options': expensePaymentOptionsProvider,
  'expense payment purpose options': expensePaymentOptionsForPurposeProvider(
    AccountingExpensePurpose.values.first,
  ),
  'payroll slip detail': payrollDetailProvider(_id),
  'payroll department options': payrollDepartmentOptionsProvider,
  'payroll batch detail': payrollBatchDetailProvider(_id),
  'my employee profile': myEmployeeProfileProvider,
  'my profile change detail': myProfileChangeDetailProvider(_id),
  'HR profile preview': hrProfileChangesProvider((status: null, page: 1)),
  'HR employee pending profile': hrProfileEmployeePendingProvider(_id),
  'HR profile facets': hrProfileChangeFacetsProvider(null),
  'HR profile change detail': hrProfileChangeDetailProvider(_id),
  'my department tree': myDepartmentTreeProvider,
  'my department roster': myDepartmentRosterProvider(_id),
  'FQC decision capability': productionFqcDecisionCapabilityProvider,
  'suggestion detail': suggestionDetailProvider(_id),
  'visitor approval facets': visitorApprovalFacetsProvider(null),
  'visitor approval detail': visitorApprovalDetailProvider(_id),
  'visitor own application detail': visitorApplicationDetailProvider(_id),
  'website inquiry detail': websiteInquiryDetailProvider(_id),
  'dashboard overview': dashboardOverviewProvider,
  'AI availability': aiStatusProvider,
};

void main() {
  final scoped = <String, ProviderListenable<Object?>>{
    'my profile changes': myProfileChangesProvider((status: null, page: 1)),
    'my profile table': myProfileChangeTableProvider((status: null, page: 1)),
    'HR profile queue': hrProfileChangeQueueProvider((
      status: null,
      departmentId: null,
      page: 1,
    )),
    'visitor applications': visitorApplicationsProvider((
      status: null,
      page: 1,
    )),
    'visitor approvals': visitorApprovalListProvider((
      status: null,
      hostDepartmentId: null,
      page: 1,
    )),
    'visitor host queue': myAsHostProvider((status: null, page: 1)),
  };
  for (final entry in scoped.entries) {
    test('scoped list shared owner: ${entry.key}', () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      var caller = true;
      final first = PagedReadIntent.scopedRead(
        () => caller,
        () => f.container.listen(entry.value, (_, _) {}),
      );
      final second = f.container.listen(entry.value, (_, _) {});
      await f.adapter.ready();
      caller = false;
      first.close();
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, [false]);
      second.close();
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, [true]);
    });
  }
  test('website shared owner outlives its initiating consumer', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    var caller = true;
    final first = PagedReadIntent.scopedRead(
      () => caller,
      () => f.container.listen(websiteManagementProvider, (_, _) {}),
    );
    final second = f.container.listen(websiteManagementProvider, (_, _) {});
    await f.adapter.ready();
    caller = false;
    first.close();
    await f.container.pump();
    await f.settle();
    expect(f.adapter.cancelled, [false]);
    second.close();
    await f.container.pump();
    await f.settle();
    expect(f.adapter.cancelled, [true]);
  });
  test(
    'an awaiting bootstrap retires on identity change without adopting the successor future',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final pending = readSharedProviderFuture(
        f.container,
        employeePickerDepartmentTreeProvider.future,
        boundary: sensitiveReadBoundaryProvider,
      );
      final retired = expectLater(pending, throwsA(isA<ApiException>()));
      await f.adapter.ready();
      f.container.read(f.identity.notifier).state = const AuthenticatedScope(
        userId: 'successor',
      );
      await retired;
      await f.container.pump();
      await f.settle();
      expect(f.adapter.pending, hasLength(1));
      expect(f.adapter.cancelled, [true]);
    },
  );
  test(
    'retiring one awaited consumer preserves another consumer of the shared future',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final firstOwner = StateProvider<int>((ref) => 0);
      final first = readSharedProviderFuture(
        f.container,
        employeePickerDepartmentTreeProvider.future,
        boundary: firstOwner,
      );
      final retired = expectLater(first, throwsA(isA<ApiException>()));
      final second = readSharedProviderFuture(
        f.container,
        employeePickerDepartmentTreeProvider.future,
        boundary: sensitiveReadBoundaryProvider,
      );
      await f.adapter.ready();
      f.container.read(firstOwner.notifier).state++;
      await retired;
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, [false]);
      f.adapter.pending.single.complete(
        ResponseBody.fromString(
          '[]',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      expect(await second, isEmpty);
      await f.container.pump();
      expect(f.container.exists(employeePickerDepartmentTreeProvider), isFalse);
    },
  );
  testWidgets(
    'widget disposal releases its read lease and the suspended await finishes',
    (tester) async {
      final f = _Fixture();
      addTearDown(() => tester.runAsync(f.dispose));
      var started = false, settled = false;
      Object? failure;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: Consumer(
            builder: (context, ref, _) {
              if (!started) {
                started = true;
                unawaited(
                  readSharedWidgetFuture(
                    ref,
                    employeePickerDepartmentTreeProvider.future,
                  ).then<void>(
                    (_) => settled = true,
                    onError: (Object error, StackTrace _) {
                      failure = error;
                      settled = true;
                    },
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.adapter.pending, hasLength(1));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: const SizedBox.shrink(),
        ),
      );
      for (var frame = 0; frame < 5 && !settled; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(f.adapter.cancelled, [true]);
      expect(settled, isTrue);
      expect(failure, isA<ApiException>());
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'direct future consumers keep a shared bootstrap read alive until completion',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final pending = readSharedProviderFuture(
        f.container,
        employeePickerDepartmentTreeProvider.future,
        boundary: sensitiveReadBoundaryProvider,
      );
      unawaited(
        pending.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      await f.adapter.ready();
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, [false]);
      f.adapter.pending.single.complete(
        ResponseBody.fromString(
          '[]',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      expect(await pending, isEmpty);
      await f.container.pump();
      expect(f.container.exists(employeePickerDepartmentTreeProvider), isFalse);
    },
  );
  test(
    'retained document counts survive a brief departure but retire on invalidation',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final provider = documentStatusCountsProvider(
        const DocumentStatusScope(DraftDocKind.salesOrder),
      );
      final listener = f.container.listen(provider, (_, _) {});
      await f.adapter.ready();
      listener.close();
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, [false]);
      f.container.invalidate(provider);
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, [true]);
    },
  );
  test('HR summary refresh retires the previous shared request', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    final listener = f.container.listen(hrTaskSummaryProvider, (_, _) {});
    await f.adapter.ready();
    final refreshed = f.container
        .read(hrTaskSummaryProvider.notifier)
        .refresh();
    await f.adapter.ready(2);
    await f.settle();
    expect(f.adapter.cancelled, [true, false]);
    f.adapter.pending[1].complete(
      ResponseBody.fromString(
        '{}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    await refreshed;
    listener.close();
  });
  for (final entry in _cases.entries) {
    test('${entry.key}: final consumer retires bounded HTTP', () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      final listener = f.container.listen(entry.value, (_, _) {});
      await f.adapter.ready();
      listener.close();
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, everyElement(isTrue), reason: entry.key);
      expect(f.safety.pendingReadCount, 0);
    });
  }
  test(
    'a remaining shared department consumer keeps its HTTP despite the initiating page leaving',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      var page = true;
      final first = PagedReadIntent.scopedRead(
        () => page,
        () =>
            f.container.listen(employeePickerDepartmentTreeProvider, (_, _) {}),
      );
      final second = f.container.listen(
        employeePickerDepartmentTreeProvider,
        (_, _) {},
      );
      await f.adapter.ready();
      page = false;
      first.close();
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, everyElement(isFalse));
      second.close();
      await f.container.pump();
      await f.settle();
      expect(f.adapter.cancelled, everyElement(isTrue));
    },
  );
}

class _VisitorSession extends VisitorSessionNotifier {
  @override
  VisitorSessionState build() => const VisitorSessionState();
}

class _Fixture {
  final adapter = _Adapter();
  final safety = ApiMutationReloadSafety();
  final identity = StateProvider<AuthenticatedScope?>(
    (ref) => const AuthenticatedScope(userId: 'owner'),
  );
  late final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
    ..httpClientAdapter = adapter;
  late final api = ApiClient(dio, reloadSafety: safety);
  late final container = ProviderContainer(
    retry: apiProviderRetry,
    overrides: [
      apiClientProvider.overrideWithValue(api),
      visitorApiProvider.overrideWithValue(api),
      websiteManagementRepositoryProvider.overrideWithValue(
        DioWebsiteManagementRepository(api),
      ),
      visitorSessionProvider.overrideWith(_VisitorSession.new),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(identity)),
      currentPermissionsProvider.overrideWithValue({
        Perm.authorizationManage,
        Perm.productionQualityInspectionApprove,
        Perm.websiteView,
      }),
      isSuperAdminProvider.overrideWithValue(true),
      masterDataSessionKeyProvider.overrideWithValue('owner'),
      fixedBadgeSummaryOverride(),
    ],
  );
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 80));
  Future<void> dispose() async {
    container.dispose();
    await settle();
    for (final pending in adapter.pending) {
      if (!pending.isCompleted) {
        pending.complete(
          ResponseBody.fromString(
            '{}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          ),
        );
      }
    }
    dio.close(force: true);
  }
}

class _Adapter implements HttpClientAdapter {
  final pending = <Completer<ResponseBody>>[];
  final cancelled = <bool>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) {
    final index = pending.length;
    final result = Completer<ResponseBody>();
    pending.add(result);
    cancelled.add(false);
    cancelFuture?.then((_) => cancelled[index] = true);
    return result.future;
  }

  Future<void> ready([int count = 1]) async {
    for (var i = 0; pending.length < count && i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(pending.length, greaterThanOrEqualTo(count));
    await Future<void>.delayed(Duration.zero);
  }

  @override
  void close({bool force = false}) {}
}
