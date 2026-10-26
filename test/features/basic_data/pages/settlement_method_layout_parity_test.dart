import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/search/keyword_search.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_form_grid.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/models/settlement_method_admin.dart';
import 'package:uten_imp/features/basic_data/pages/settlement_method_page.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

final _grants = StateProvider<Set<String>>(
  (_) => {Perm.settlementMethodView, Perm.settlementMethodEdit},
);

class _Repository extends ReferenceMethodRepository {
  _Repository({bool locked = false, this.multiple = false})
    : item = SettlementMethodAdminItem(
        id: 'settlement-1',
        code: 'JS0188',
        name: '次月十号',
        status: '使用',
        systemRole: locked ? 'MONTHLY' : null,
        termsBase: 'RECEIPT_DATE',
        dueRule: 'FIXED_DAY_OF_MONTH',
        defaultDueDays: 15,
        fixedDayOfMonth: 10,
        monthsAhead: 1,
        remark: '核对账单后结算',
      ),
      super(ApiClient(Dio()));

  final SettlementMethodAdminItem item;
  final bool multiple;
  final writes = <Map<String, dynamic>>[];

  @override
  Future<PagedResult<SettlementMethodAdminItem>> settlementAdminPage({
    int page = 1,
    int size = 100,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async {
    final all = (await settlementAdminList(keyword: keyword, filters: filters))
        .where((item) => matchesKeywordSearch([item.name, item.code], keyword ?? '')).toList();
    return PagedResult(
      items: all.skip((page - 1) * size).take(size).toList(),
      page: page,
      size: size,
      total: all.length,
      totalPages: (all.length / size).ceil(),
    );
  }

  @override
  Future<List<SettlementMethodAdminItem>> settlementAdminList({
    String? keyword,
    Map<String, String?> filters = const {},
  }) async => [
    item,
    if (multiple)
      const SettlementMethodAdminItem(
        id: 'settlement-locked',
        code: 'JS0001',
        name: '现金锁定',
        status: '使用',
        systemRole: 'CASH',
        termsBase: 'RECEIPT_DATE',
        dueRule: 'NET_DAYS',
        defaultDueDays: 0,
        monthsAhead: 0,
      ),
  ];

  @override
  Future<SettlementMethodFacets> settlementAdminFacets() async =>
      const SettlementMethodFacets(fields: {}, nullCounts: {});

  @override
  Future<void> updateSettlementTerms(
    String id,
    Map<String, dynamic> body,
  ) async {
    expect(id, item.id);
    writes.add(Map.of(body));
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repository repository, {
  double width = 1280,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SettlementMethodPage()),
      GoRoute(
        path: '/basicinfo/history',
        builder: (_, state) => Scaffold(
          body: Text(
            '独立历史:${state.uri.queryParameters['entityType']}:'
            '${state.uri.queryParameters['recordId']}',
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        referenceMethodRepositoryProvider.overrideWithValue(repository),
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        authenticatedScopeProvider.overrideWithValue(const AuthenticatedScope(userId: 'settlement-test')),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp.router(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(SettlementMethodPage)),
  );
}

Future<void> _open(WidgetTester tester, _Repository repository) async {
  final table = tester.widget<MasterDataTableView<SettlementMethodAdminItem>>(
    find.byType(MasterDataTableView<SettlementMethodAdminItem>),
  );
  table.onRowTap!(repository.item);
  await tester.pumpAndSettle();
}

MasterEditForm _form(WidgetTester tester) =>
    tester.widget(find.byType(MasterEditForm));

List<Rect> _fieldRects(WidgetTester tester) => [
  for (final grid in tester.widgetList<UtenFormGrid>(
    find.descendant(
      of: find.byType(MasterEditForm),
      matching: find.byType(UtenFormGrid),
    ),
  ))
    for (final field in grid.children) tester.getRect(find.byWidget(field)),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [1280.0, 390.0]) {
    testWidgets('结算方式多选和编辑共用悬浮组，系统行只读且不伪造删除 $width', (tester) async {
      final repository = _Repository(multiple: true);
      final container = await _pump(
        tester,
        repository,
        width: width,
        scale: width < 500 ? 1.5 : 1,
      );
      container.read(_grants.notifier).state = {
        Perm.settlementMethodView,
        Perm.settlementMethodEdit,
        Perm.settlementMethodCreate,
      };
      await tester.pumpAndSettle();
      await tester.tap(find.text('次月十号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('现金锁定'));
      await tester.pumpAndSettle();
      final table = tester
          .widget<MasterDataTableView<SettlementMethodAdminItem>>(
            find.byType(MasterDataTableView<SettlementMethodAdminItem>),
          );
      expect(table.selectable, isTrue);
      expect(table.selectedIds, {'settlement-1', 'settlement-locked'});
      expect(table.requiredLeadingColumnKeys, ['code', 'name']);
      expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
      expect(find.text('添加结算方式'), findsOneWidget);
      for (final action in ['删除选中', '停用选中', '启用选中']) {
        expect(find.text(action), findsNothing);
      }
      final rect = tester.getRect(find.byType(UtenFloatingActionGroup));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(width));
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('inline-activate-settlement-1-name')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('inline-activate-settlement-locked-name')),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey('inline-activate-settlement-locked-defaultDueDays'),
        ),
        findsNothing,
      );
      expect(repository.writes, isEmpty);
      container.read(_grants.notifier).state = {Perm.settlementMethodView};
      await tester.pumpAndSettle();
      final after = tester
          .widget<MasterDataTableView<SettlementMethodAdminItem>>(
            find.byType(MasterDataTableView<SettlementMethodAdminItem>),
          );
      expect(after.selectedIds, isEmpty);
      expect(find.text('编辑模式'), findsNothing);
      expect(repository.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scenario in [
    (width: 1280.0, scale: 1.0),
    (width: 390.0, scale: 1.5),
  ]) {
    testWidgets('查看与编辑共享字段顺序和网格，撤权即时只读 '
        '${scenario.width}/${scenario.scale}', (tester) async {
      final repository = _Repository();
      final container = await _pump(
        tester,
        repository,
        width: scenario.width,
        scale: scenario.scale,
      );
      await _open(tester, repository);
      final edit = _form(tester);
      expect(edit.fields.map((field) => field.key), [
        'code',
        'name',
        'termsBase',
        'dueRule',
        'defaultDueDays',
        'fixedDayOfMonth',
        'monthsAhead',
        'status',
        'systemRole',
        'termsSummary',
        'remark',
      ]);
      expect(edit.fields.first.readOnly, isTrue);
      expect(edit.initialValues['code'], 'JS0188');
      expect(edit.readOnlyKeys, isNull);
      final before = _fieldRects(tester);
      container.read(_grants.notifier).state = {Perm.settlementMethodView};
      await tester.pumpAndSettle();
      expect(find.text('原输入已保留，此窗口不会提交'), findsOneWidget);
      expect(find.byType(MasterEditForm), findsNothing);
      final retained = tester.widget<MasterEditForm>(find.byType(MasterEditForm, skipOffstage: false));
      expect(retained.initialValues, edit.initialValues);
      expect(find.widgetWithText(UtenButton, '保存'), findsNothing);
      await tester.tap(find.widgetWithText(UtenButton, '关闭'));
      await tester.pumpAndSettle();
      await _open(tester, repository);
      final view = _form(tester);
      expect(
        view.fields.map((field) => (field.key, field.label, field.group)),
        edit.fields.map((field) => (field.key, field.label, field.group)),
      );
      expect(view.initialValues, edit.initialValues);
      expect(view.readOnlyKeys, {for (final field in edit.fields) field.key});
      final after = _fieldRects(tester);
      expect(after, hasLength(before.length));
      for (var index = 0; index < before.length; index++) {
        expect(after[index].left, closeTo(before[index].left, 0.01));
        expect(after[index].width, closeTo(before[index].width, 0.01));
      }
      expect(find.widgetWithText(UtenButton, '保存'), findsNothing);
      await tester.tap(find.widgetWithText(UtenButton, '关闭'));
      await tester.pumpAndSettle();
      expect(repository.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('维护显示只读系统编号且提交仅含可编辑账期字段', (tester) async {
    final repository = _Repository();
    await _pump(tester, repository);
    await _open(tester, repository);
    final name = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.controller?.text == repository.item.name,
    );
    await tester.enterText(name, '更改后的账期');
    await tester.tap(find.widgetWithText(UtenButton, '保存'));
    await tester.pumpAndSettle();
    expect(repository.writes.single, {
      'name': '更改后的账期',
      'termsBase': 'RECEIPT_DATE',
      'dueRule': 'FIXED_DAY_OF_MONTH',
      'defaultDueDays': 15,
      'fixedDayOfMonth': 10,
      'monthsAhead': 1,
    });
    expect(find.byType(MasterEditForm), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统角色即使持编辑权限仍全只读且可以进入独立历史页', (tester) async {
    final repository = _Repository(locked: true);
    await _pump(tester, repository);
    await _open(tester, repository);
    final form = _form(tester);
    expect(form.readOnlyKeys, {for (final field in form.fields) field.key});
    expect(form.initialValues['systemRole'], '月结 · 系统锁定');
    expect(find.widgetWithText(UtenButton, '保存'), findsNothing);
    final history = find.descendant(
      of: find
          .ancestor(
            of: find.byType(MasterEditForm),
            matching: find.byType(SafeArea),
          )
          .first,
      matching: find.text('修改历史'),
    );
    await tester.tap(history);
    await tester.pumpAndSettle();
    expect(find.text('独立历史:reference-methods:settlement-1'), findsOneWidget);
    expect(repository.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
