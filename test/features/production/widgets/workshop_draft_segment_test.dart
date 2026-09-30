import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/widgets/workshop_draft_segment.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.drafts);
  final List<FormDraft> drafts;

  @override
  List<FormDraft> build() => drafts;
}

const _scope = FormDraftCategoryScope(module: BadgeModule.workshop);
const _serverDraft = ProductionDailyReportListItem(
  id: 'report-1',
  billNo: 'SR-001',
  billDate: '2026-09-30',
  workshopName: '装配车间',
  status: 0,
);

void main() {
  testWidgets(
    'category header filters local requests and server daily reports',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final drafts = _Drafts([
        FormDraft(
          id: 'return-1',
          title: '生产余料退仓申请',
          module: BadgeModule.workshop,
          route: '/production/material-return/new',
          permission: 'production_material:settle',
          updatedAt: DateTime(2026, 9, 30),
          data: const {},
        ),
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [formDraftsProvider.overrideWith(() => drafts)],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: WorkshopDraftSegment(
                scope: _scope,
                serverDrafts: [_serverDraft],
                loading: false,
                error: null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SR-001'), findsOneWidget);
      expect(find.text('未提交草稿'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('类别')).dx,
        lessThan(tester.getTopLeft(find.text('单据号')).dx),
      );
      await tester.tap(find.text('类别'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生产日报 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('SR-001'), findsOneWidget);
      expect(find.text('未提交草稿'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('page search includes server report number and workshop', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var search = '';
    late StateSetter setSearch;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [formDraftsProvider.overrideWith(() => _Drafts([]))],
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setSearch = setState;
                return WorkshopDraftSegment(
                  scope: _scope,
                  serverDrafts: const [_serverDraft],
                  loading: false,
                  error: null,
                  search: search,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final keyword in ['SR-001', '装配车间']) {
      setSearch(() => search = keyword);
      await tester.pumpAndSettle();
      expect(find.text('SR-001'), findsOneWidget);
    }
    setSearch(() => search = '无此单据');
    await tester.pumpAndSettle();
    expect(find.text('SR-001'), findsNothing);
    expect(find.text('暂无草稿'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
