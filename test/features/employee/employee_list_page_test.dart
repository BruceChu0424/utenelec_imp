import 'dart:async';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
// 员工列表页交互契约（2026-09-10 改版）：
// 1) 顶部状态 FilterChip 已下线，状态筛选交给表头 autofilter（初始请求不再带 statuses 预筛）；
// 2) 搜索框驻表格工具条（「全屏」按钮右侧）；
// 3) 首次完整读取当前授权结果，滚动不请求数据；切页停止旧读，返页重新核对完整结果；
// 4) 表头排序（工号等）→ 服务端带 sort/order 重查。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/employee/pages/employee_list_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

/// 固定两页（各 20 行）并记录请求参数的假仓库。
class _NoNetworkApi extends ApiClient {
  _NoNetworkApi() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _PagingEmployeeRepository extends Fake implements EmployeeRepository {
  final requestedPages = <int>[];
  final versionedRequests = <(int, int)>[];
  int pages = 2;
  int version = 1;
  Completer<PagedResult<EmployeeSummary>>? pendingSecond;
  final sortRequests = <(String?, String?)>[];
  Set<String>? lastStatuses;

  EmployeeSummary _row(int n) => EmployeeSummary(
    id: 'e-$n',
    code: 'UT${n.toString().padLeft(4, '0')}',
    fullName: '${version == 1 ? '' : '新'}员工$n',
    departmentName: '生产部',
    positionName: '操作工',
    status: 'active',
    hireDate: '2020-01-01',
  );

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
  }) async {
    requestedPages.add(page);
    versionedRequests.add((version, page));
    sortRequests.add((sort, order));
    lastStatuses = statuses;
    if (page == 2 && pendingSecond != null) return pendingSecond!.future;
    return result(page, size);
  }

  PagedResult<EmployeeSummary> result(int page, int size) => PagedResult(
    items: [for (var i = (page - 1) * 20 + 1; i <= page * 20; i++) _row(i)],
    page: page,
    size: size,
    total: pages * 20,
    totalPages: pages,
  );
}

Widget _app(_PagingEmployeeRepository repo) => ProviderScope(
  overrides: [
    apiClientProvider.overrideWithValue(_NoNetworkApi()),
    sessionProvider.overrideWith(_Session.new),
    sessionSnapshotProvider.overrideWith(_Snapshot.new),
    currentPermissionsProvider.overrideWithValue({Perm.employeeView}),
    employeeRepositoryProvider.overrideWithValue(repo),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: EmployeeListPage(),
  ),
);

void main() {
  for (final returnBeforeReply in [false, true]) {
    testWidgets(
      'retained employee roster stops hidden reads and returns fresh ABA=$returnBeforeReply',
      (tester) async {
        final repo = _PagingEmployeeRepository()
          ..pages = 3
          ..pendingSecond = Completer<PagedResult<EmployeeSummary>>();
        await tester.pumpWidget(_app(repo));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pump();
        expect(repo.requestedPages, [1, 2]);
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        final covering = navigator.push<void>(
          MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另一页'))),
        );
        await tester.pumpAndSettle();
        expect(repo.requestedPages, [1, 2]);
        if (returnBeforeReply) {
          navigator.pop();
          await covering;
          // Complete the return transition while the original fake transport
          // is deliberately still held; its loading animation cannot settle.
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pump();
        }
        final oldSecond = repo.result(2, 100);
        final pending = repo.pendingSecond!;
        repo.pendingSecond = null;
        repo.version = 2;
        pending.complete(oldSecond);
        await tester.pumpAndSettle();
        if (!returnBeforeReply) {
          expect(
            repo.requestedPages,
            [1, 2],
            reason:
                'opaque cover must not drain page3 or publish a complete old roster',
          );
          navigator.pop();
          await covering;
          await tester.pumpAndSettle();
        }
        expect(repo.versionedRequests, [
          (1, 1),
          (1, 2),
          (2, 1),
          (2, 2),
          (2, 3),
        ]);
        final table = tester.widget<MasterDataTableView<EmployeeSummary>>(
          find.byKey(const Key('employee-list-table')),
        );
        expect(table.items, hasLength(60));
        expect(
          table.items.every((row) => row.fullName.startsWith('新员工')),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('初始加载不带状态预筛；无状态 FilterChip；搜索框在工具条', (tester) async {
    final repo = _PagingEmployeeRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    expect(repo.requestedPages, [1, 2]);
    expect(repo.lastStatuses, isNull, reason: '状态筛选交给表头 autofilter');
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byType(UtenSearchBar), findsOneWidget);
    expect(find.text('员工1'), findsOneWidget);
  });

  testWidgets('无需滚动就加载全部分页，表头筛选范围包含末页员工', (tester) async {
    final repo = _PagingEmployeeRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(repo.requestedPages, [1, 2]);
    final table = tester.widget<MasterDataTableView<EmployeeSummary>>(
      find.byKey(const Key('employee-list-table')),
    );
    expect(table.items.length, 40);
    expect(table.items.last.fullName, '员工40');
    expect(table.onLoadMore, isNull);
    expect(table.facets['departmentName']!.single.count, 40);
    expect(find.text('共 40 人'), findsOneWidget);
  });

  testWidgets('默认和恢复默认均按工号升序，支持手动降序', (tester) async {
    final repo = _PagingEmployeeRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(repo.sortRequests, [('code', 'asc'), ('code', 'asc')]);
    final table = find.byKey(const Key('employee-list-table'));
    expect(
      tester.widget<MasterDataTableView<EmployeeSummary>>(table).sortColumn,
      'code',
    );

    await tester.tap(find.text('工号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从大到小'));
    await tester.pumpAndSettle();
    expect(repo.sortRequests.sublist(2), [('code', 'desc'), ('code', 'desc')]);

    await tester.tap(find.text('工号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消排序'));
    await tester.pumpAndSettle();
    expect(repo.sortRequests.sublist(4), [('code', 'asc'), ('code', 'asc')]);
  });
}
