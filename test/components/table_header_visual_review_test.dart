import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/widgets/procurement_difference_column.dart';

import '../support/audit_screenshot_support.dart';

void main() {
  for (final compact in [false, true]) {
    testWidgets(
      'header menu visual geometry ${compact ? 'compact dark' : 'desktop light'}',
      (tester) async {
        const capture = bool.fromEnvironment('UI_CAPTURE');
        final oldShadows = debugDisableShadows;
        if (capture) {
          debugDisableShadows = false;
        }
        addTearDown(() => debugDisableShadows = oldShadows);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = compact
            ? const Size(390, 620)
            : const Size(1000, 640);
        addTearDown(tester.view.reset);
        if (capture) await loadAuditScreenshotFonts(tester);
        final key = GlobalKey();
        final theme = compact ? buildDarkTheme() : buildLightTheme();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: capture ? auditScreenshotTheme(theme) : theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(compact ? 2 : 1)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        '采购 / 委外明细',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      MasterDataTableView<(String, String?, String)>(
                        showColumnChooser: false,
                        embedded: true,
                        columns: [
                          MasterColumnDef(
                            key: 'billNo',
                            label: '单号',
                            width: 130,
                            value: (r) => r.$1,
                          ),
                          if (!compact)
                            procurementDifferenceColumn(
                              context: context,
                              differenceOf: (r) => r.$2,
                              unitOf: (_) => '件',
                            ),
                          MasterColumnDef(
                            key: 'status',
                            label: '状态',
                            width: 180,
                            value: (r) => r.$3,
                          ),
                        ],
                        items: const [
                          ('CG-001', '-2', '待审核'),
                          ('CG-002', '0', '已审核'),
                          ('CG-003', '3', '已审核'),
                        ],
                        facets: const {
                          'status': [
                            MasterFacetBucket(value: '待审核', count: 1),
                            MasterFacetBucket(value: '已审核', count: 2),
                          ],
                        },
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final header = find
            .byKey(
              ValueKey(
                'master-column-filter-${compact ? 'status' : 'differenceQty'}',
              ),
            )
            .hitTestable()
            .first;
        await tester.tapAt(tester.getTopLeft(header) + const Offset(16, 22));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('uten-column-keyword-input')),
          compact ? '审核' : '<0',
        );
        await tester.pumpAndSettle();
        final menu = tester.getRect(
          find.byKey(const Key('uten-table-header-menu')),
        );
        expect(menu.left, greaterThanOrEqualTo(0));
        expect(menu.right, lessThanOrEqualTo(compact ? 390 : 1000));
        expect(menu.bottom, lessThanOrEqualTo(compact ? 620 : 640));
        expect(tester.takeException(), isNull);
        if (capture) {
          await saveAuditScreenshot(
            tester,
            key,
            compact
                ? 'table-header-compact-dark'
                : 'table-header-difference-desktop',
          );
        }
        debugDisableShadows = oldShadows;
      },
    );
  }
}
