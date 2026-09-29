// 独立草稿页 + 顶栏「草稿」按钮契约（2026-09-27）：
// 1. 顶栏按钮徽章数与该宿主 scope 的可见草稿数同口径，未知类别隐藏按钮；
// 2. 按钮落点 /form-drafts/:categoryId 渲染草稿表；
// 3. 纯草稿表常驻右下悬浮组：「已选 N 项」胶囊恒在，删除按钮未选时禁用但
//    可见、选中后可删（用户口径：已选 X 项放右下角悬浮）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_drafts_page.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.initial);
  final List<FormDraft> initial;
  @override
  List<FormDraft> build() => initial;
}

FormDraft _basicDraft(String id) => FormDraft(
  id: id,
  title: '新建客户资料',
  module: BadgeModule.people,
  route: '/basicinfo/client/new',
  permission: 'client:create',
  updatedAt: DateTime(2026, 9, 27),
  data: const {'name': '甲客户'},
);

Widget _app(
  List<FormDraft> drafts, {
  Widget? home,
  FormDraftsPage? draftsPage,
}) {
  return ProviderScope(
    overrides: [formDraftsProvider.overrideWith(() => _Drafts(drafts))],
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
      routes: {
        RouteName.formDrafts: (context) =>
            draftsPage ?? const FormDraftsPage(categoryId: 'basicinfo'),
      },
    ),
  );
}

void main() {
  testWidgets('app bar button badge follows scope count', (tester) async {
    await tester.pumpWidget(
      _app(
        [_basicDraft('a'), _basicDraft('b')],
        home: Scaffold(
          appBar: AppBar(
            actions: const [FormDraftsAppBarButton(categoryId: 'basicinfo')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('草稿'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(FormDraftsAppBarButton),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('app bar button hides for unknown category', (tester) async {
    await tester.pumpWidget(
      _app(
        const [],
        home: Scaffold(
          appBar: AppBar(
            actions: const [FormDraftsAppBarButton(categoryId: 'nope')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 按钮本体保留（build 里收敛为空盒），可点的形态不出现。
    expect(find.text('草稿'), findsNothing);
    expect(find.byTooltip('草稿'), findsNothing);
  });

  testWidgets('button navigates to the standalone drafts page by category id', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/basicinfo',
      routes: [
        GoRoute(
          path: '/basicinfo',
          builder: (_, _) => Scaffold(
            appBar: AppBar(
              actions: const [FormDraftsAppBarButton(categoryId: 'basicinfo')],
            ),
          ),
        ),
        GoRoute(
          path: RouteName.formDrafts,
          builder: (_, s) =>
              FormDraftsPage(categoryId: s.pathParameters['categoryId']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          formDraftsProvider.overrideWith(() => _Drafts([_basicDraft('a')])),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();
    expect(find.textContaining('新建客户资料'), findsOneWidget);
    expect(find.text('未知的草稿类别'), findsNothing);
  });

  testWidgets('unknown category id shows empty state', (tester) async {
    await tester.pumpWidget(
      _app(const [], home: const FormDraftsPage(categoryId: 'nope')),
    );
    await tester.pumpAndSettle();
    expect(find.text('未知的草稿类别'), findsOneWidget);
  });

  testWidgets(
    'selection summary pill floats bottom-right and delete stays visible disabled',
    (tester) async {
      await tester.pumpWidget(
        _app([
          _basicDraft('d1'),
          _basicDraft('d2'),
        ], home: const FormDraftsPage(categoryId: 'basicinfo')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('新建客户资料'), findsNWidgets(2));

      // 未选态：悬浮组已在右下角，胶囊 + 禁用删除按钮同框常驻。
      final group = find.byType(UtenFloatingActionGroup);
      expect(group, findsOneWidget);
      expect(
        find.descendant(
          of: group,
          matching: find.byType(UtenSelectionSummaryPill),
        ),
        findsOneWidget,
      );
      expect(find.text('已选 0 项'), findsOneWidget);
      final disabled = tester.widget<UtenButton>(
        find.descendant(of: group, matching: find.byType(UtenButton)),
      );
      expect(disabled.onPressed, isNull);
      expect(find.text('删除填写草稿 (0)'), findsOneWidget);

      // 选中一份：胶囊计数与删除按钮联动，删除可用。
      final table = tester
          .widget<MasterDataTableView<FormDraftCategoryRow<Object>>>(
            find.byType(MasterDataTableView<FormDraftCategoryRow<Object>>),
          );
      table.onSelectedIdsChanged!(const {'form-draft:d1'});
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      final enabled = tester.widget<UtenButton>(
        find.descendant(of: group, matching: find.byType(UtenButton)),
      );
      expect(enabled.onPressed, isNotNull);
      expect(find.text('删除填写草稿 (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
