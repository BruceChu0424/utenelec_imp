import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_table.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <({String path, Map<String, dynamic> query})>[];
  String? holdPath;
  Completer<Map<String, dynamic>>? holdNext;
  final labels = <String, String>{};

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add((path: path, query: Map.of(query ?? const {})));
    if (path == holdPath && holdNext != null) {
      final gate = holdNext!;
      holdNext = null;
      return gate.future;
    }
    if (path.endsWith('/facets')) return const {};
    if (path.endsWith('/summary')) return const {};
    if (labels[path] case final label?) return _page(path, label);
    return const {
      'items': <Object?>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [
    {'name': 'WS-A'},
  ];
}

Map<String, dynamic> _page(String path, String label) => {
  'items': [
    path == '/production/execution-workbench'
        ? {
            'rootType': 'ANALYSIS',
            'rootId': label,
            'rootLabel': label,
            'status': 'IN_PROGRESS',
          }
        : {'planId': label, 'billNo': label, 'closed': true},
  ],
  'page': 1,
  'size': 20,
  'total': 1,
  'totalPages': 1,
};

Future<void> _mount(WidgetTester tester, _Api api) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'planner'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionPlanView,
          Perm.productionDailyReportView,
          Perm.productionMaterialAnalysisCreate,
          Perm.productionExecutionOverview,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionBoardPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final stage in const {
    '进行中': '/production/execution-workbench',
    '历史记录': '/production/plans/progress',
  }.entries) {
    testWidgets('${stage.key}顶栏刷新迟到不覆盖新关键词结果', (tester) async {
      final api = _Api()..labels[stage.value] = 'INITIAL-ROW';
      await _mount(tester, api);
      await tester.tap(find.text(stage.key));
      await tester.pumpAndSettle();
      expect(find.text('INITIAL-ROW'), findsOneWidget);
      final gate = Completer<Map<String, dynamic>>();
      api.holdPath = stage.value;
      api.holdNext = gate;
      await tester.tap(find.byKey(const Key('production-pending-refresh')));
      await tester.pump(const Duration(milliseconds: 50));
      api.labels[stage.value] = 'LATEST-ROW';
      await tester.enterText(
        find.descendant(
          of: find.byType(UtenSearchBar).first,
          matching: find.byType(TextField),
        ),
        'LATEST-QUERY',
      );
      await tester.pump(const Duration(milliseconds: 350));
      // The old clicked refresh still owns an unfinished future and its shared
      // loading feedback. Observe the newer query before releasing that future.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('LATEST-ROW'), findsOneWidget);
      gate.complete(_page(stage.value, 'STALE-ROW'));
      await tester.pumpAndSettle();
      expect(find.text('LATEST-ROW'), findsOneWidget);
      expect(find.text('STALE-ROW'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final stage in const {
    '草稿': '/production/plans',
    '待排产': '/production/schedule/pending',
    '进行中': '/production/execution-workbench',
    '历史记录': '/production/plans/progress',
  }.entries) {
    testWidgets('顶栏刷新${stage.key}一次且保留当前检索与筛选', (tester) async {
      final api = _Api();
      await _mount(tester, api);
      await tester.tap(find.text(stage.key));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(UtenSearchBar).first,
          matching: find.byType(TextField),
        ),
        'KEEP-QUERY',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      if (stage.key == '进行中') {
        final table = tester
            .widget<MasterDataTableView<ProductionExecutionWorkbenchGroup>>(
              find.byType(
                MasterDataTableView<ProductionExecutionWorkbenchGroup>,
              ),
            );
        table.onFilterChanged('orders', 'SO-KEEP');
        await tester.pumpAndSettle();
        table.onSortChange!('orders', false);
        await tester.pumpAndSettle();
      } else if (stage.key == '历史记录') {
        tester
            .widget<UtenDropdownField>(
              find.byWidgetPredicate(
                (widget) => widget is UtenDropdownField && widget.label == '车间',
              ),
            )
            .onChanged('WS-A');
        await tester.pumpAndSettle();
      }
      final refresh = find.byKey(const Key('production-pending-refresh'));
      expect(
        find.ancestor(of: refresh, matching: find.byType(UtenAppBar)),
        findsOneWidget,
      );
      final before = api.reads.where((read) => read.path == stage.value).length;
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      final reads = api.reads
          .where((read) => read.path == stage.value)
          .toList();
      expect(reads.length, before + 1, reason: '顶栏必须刷新当前分段，且不重复加载');
      if (stage.key == '草稿') {
        expect(
          tester
              .widget<DraftWorkspaceTable>(find.byType(DraftWorkspaceTable))
              .search,
          'KEEP-QUERY',
        );
        expect(reads.last.query['status'], 0);
      } else {
        expect(reads.last.query['keyword'], 'KEEP-QUERY');
      }
      if (stage.key == '进行中') {
        expect(reads.last.query['salesOrder'], 'SO-KEEP');
        expect(reads.last.query['sort'], 'orders');
        expect(reads.last.query['order'], 'desc');
      } else if (stage.key == '历史记录') {
        expect(reads.last.query['workshop'], 'WS-A');
        expect(reads.last.query['closed'], true);
      }
      expect(find.byTooltip('刷新'), findsOneWidget, reason: '正文不再出现重复的页面刷新');
      expect(tester.takeException(), isNull);
    });
  }
}
