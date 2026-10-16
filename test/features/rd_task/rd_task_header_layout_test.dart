import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/rd_task/pages/rd_task_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _RdApi extends ApiClient {
  _RdApi() : super(Dio());
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/rd-tasks') return {};
    queries.add(Map<String, dynamic>.of(query ?? {}));
    return {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }
}

void main() {
  for (final width in [1400.0, 375.0]) {
    testWidgets('研发四分段共用分类右侧搜索，宽度$width与大字适应空间', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _RdApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({Perm.rdTaskView}),
            isSuperAdminProvider.overrideWithValue(false),
            fixedBadgeSummaryOverride(badgeSummaryFixture()),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const RdTaskPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final stages = {
        '草稿': null,
        '待处理': 'pending',
        '进行中': 'in_progress',
        '历史单据': 'done',
      };
      for (final stage in stages.entries) {
        final segments = find.byKey(const Key('rd-task-segments'));
        final direct = find.descendant(
          of: segments,
          matching: find.text(stage.key),
        );
        if (direct.evaluate().isEmpty) {
          await tester.tap(
            find.descendant(
              of: segments,
              matching: find.byType(OutlinedButton),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(stage.key).last);
        } else {
          await tester.tap(direct);
        }
        await tester.pumpAndSettle();
        expect(
          find.byType(UtenSearchBar),
          findsOneWidget,
          reason: '草稿也不能出现第二个搜索框',
        );
        final search = find.byKey(const Key('rd-task-keyword'));
        final categoryRect = tester.getRect(segments);
        final searchRect = tester.getRect(search);
        if (width > 800) {
          expect(searchRect.left, greaterThanOrEqualTo(categoryRect.right));
          expect(
            (searchRect.center.dy - categoryRect.center.dy).abs(),
            lessThan(1),
          );
        } else {
          expect(searchRect.top, greaterThanOrEqualTo(categoryRect.bottom));
          expect(searchRect.right, lessThanOrEqualTo(width));
        }
        final text = '查${stage.key}';
        await tester.enterText(
          find.descendant(of: search, matching: find.byType(TextField)),
          text,
        );
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        if (stage.value == null) {
          final drafts = tester.widget<FormDraftCategoryList>(
            find.byType(FormDraftCategoryList),
          );
          expect(drafts.showSearch, isFalse);
          expect(drafts.search, text);
        } else {
          expect(api.queries.last['keyword'], text);
          expect(api.queries.last['status'], stage.value);
          expect(api.queries.last['page'], 1);
        }
        expect(tester.takeException(), isNull);
      }
    });
  }
}
