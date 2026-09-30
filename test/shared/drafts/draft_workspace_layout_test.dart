import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_sources.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_drafts_page.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Drafts extends FormDraftsNotifier {
  @override
  List<FormDraft> build() => [
    FormDraft(
      id: 'expense-local',
      title: '新建一般费用单',
      module: BadgeModule.finance,
      draftKind: 'financeExpense',
      route: '/finance/expenses/new',
      permission: Perm.financeExpenseCreate,
      updatedAt: DateTime.utc(2026, 9, 30, 2, 30),
      data: const {
        'header': {'billDate': '2026-09-30', 'remark': '办公室日常费用'},
      },
    ),
    FormDraft(
      id: 'account-local',
      title: '新增账户',
      module: BadgeModule.finance,
      route: '/basicinfo/account?draftForm=account',
      permission: '',
      updatedAt: DateTime.utc(2026, 9, 30, 1),
      data: const {'name': '基本账户'},
    ),
  ];
}

void main() {
  const capture = bool.fromEnvironment('CAPTURE_DRAFT_UI');
  setUpAll(() async {
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'));
    await font.load();
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final size in [const Size(1440, 900), const Size(390, 844)]) {
    for (final dark in [false, true]) {
      final label = '${size.width.toInt()}-${dark ? 'dark' : 'light'}';
      testWidgets('统一草稿页 $label 类别首列、单表且无布局异常', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final boundary = GlobalKey();
        final theme = dark ? buildDarkTheme() : buildLightTheme();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'layout-test'),
              ),
              currentPermissionsProvider.overrideWithValue({
                for (final kind in formDraftsPageCategories['finance']!.kinds)
                  kind.viewPerm,
                Perm.financeExpenseCreate,
              }),
              isSuperAdminProvider.overrideWithValue(false),
              fixedBadgeSummaryOverride(),
              formDraftsProvider.overrideWith(_Drafts.new),
              for (final kind in formDraftsPageCategories['finance']!.kinds)
                draftWorkspaceRowsProvider(kind).overrideWith(
                  (ref) async => [
                    if (kind == DraftDocKind.financeReceipt ||
                        kind == DraftDocKind.financePayment)
                      DraftWorkspaceRow(
                        kind: kind,
                        id: kind.name,
                        category: draftWorkspaceKindLabel(kind),
                        location: '/finance/receipts/fixture',
                        billNo: kind == DraftDocKind.financeReceipt
                            ? 'SK202609300001'
                            : 'FK202609300002',
                        billDate: '2026-09-30',
                        party: kind == DraftDocKind.financeReceipt
                            ? '示例客户'
                            : '示例供应商',
                        amount: '12800.00',
                        deletable: true,
                      ),
                  ],
                ),
            ],
            child: MaterialApp(
              // The test engine has no OS Chinese font fallback for the
              // AppBar's explicit text style; use the same bundled font.
              theme: theme.copyWith(
                appBarTheme: theme.appBarTheme.copyWith(
                  titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                    fontFamily: 'NotoSansSC',
                  ),
                ),
              ),
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: RepaintBoundary(
                key: boundary,
                child: const FormDraftsPage(categoryId: 'finance'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
          find.byType(MasterDataTableView<DraftWorkspaceRow>),
        );
        expect(table.columns.first.key, 'category');
        expect(table.items.length, 4);
        expect(find.text('钱流管理 · 草稿'), findsOneWidget);
        if (capture) {
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = File('.local-tmp/draft-ui/finance-$label.png');
            await output.parent.create(recursive: true);
            await output.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
