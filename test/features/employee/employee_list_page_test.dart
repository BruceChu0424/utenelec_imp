// 员工列表页交互契约（2026-09-10 改版）：
// 1) 顶部状态 FilterChip 已下线，状态筛选交给表头 autofilter（初始请求不再带 statuses 预筛）；
// 2) 搜索框驻表格工具条（「全屏」按钮右侧）；
// 3) 「加载更多」按钮下线：滚动临近底部自动请求下一页，末页后不再请求；
// 4) 表头排序（工号等）→ 服务端带 sort/order 重查。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_list_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

/// 固定两页（各 20 行）并记录请求参数的假仓库。
class _PagingEmployeeRepository extends Fake implements EmployeeRepository {
  final requestedPages = <int>[];
  String? lastSort;
  String? lastOrder;
  Set<String>? lastStatuses;

  EmployeeSummary _row(int n) => EmployeeSummary(
    id: 'e-$n',
    code: 'UT${n.toString().padLeft(4, '0')}',
    fullName: '员工$n',
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
    lastSort = sort;
    lastOrder = order;
    lastStatuses = statuses;
    return PagedResult(
      items: [for (var i = (page - 1) * 20 + 1; i <= page * 20; i++) _row(i)],
      page: page,
      size: size,
      total: 40,
      totalPages: 2,
    );
  }
}

Widget _app(_PagingEmployeeRepository repo) => ProviderScope(
  overrides: [
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
  testWidgets('初始加载不带状态预筛；无状态 FilterChip；搜索框在工具条', (tester) async {
    final repo = _PagingEmployeeRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    expect(repo.requestedPages, [1]);
    expect(repo.lastStatuses, isNull, reason: '状态筛选交给表头 autofilter');
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byType(UtenSearchBar), findsOneWidget);
    expect(find.text('员工1'), findsOneWidget);
  });

  testWidgets('滚动临近底部自动加载下一页；末页后不再请求', (tester) async {
    final repo = _PagingEmployeeRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(repo.requestedPages, [1]);

    // 拖到第 1 页底部 → 自动触发第 2 页（页面上已无「加载更多」按钮）。
    expect(find.text('加载更多'), findsNothing);
    await tester.drag(find.text('员工1'), const Offset(0, -1500));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(repo.requestedPages, [1, 2]);

    // 已到末页（totalPages=2）：继续滚动不再请求第 3 页，第 2 页行已追加。
    await tester.drag(find.text('员工20'), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(repo.requestedPages, [1, 2]);
    expect(find.text('员工40'), findsOneWidget);
  });

  testWidgets('工号表头排序菜单 → 服务端带 sort/order 重查', (tester) async {
    final repo = _PagingEmployeeRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('工号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从小到大'));
    await tester.pumpAndSettle();

    expect(repo.lastSort, 'code');
    expect(repo.lastOrder, 'asc');
  });
}
