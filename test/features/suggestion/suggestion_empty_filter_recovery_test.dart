import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/suggestion/models/suggestion.dart';
import 'package:uten_imp/features/suggestion/pages/suggestion_list_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/suggestions') return const {};
    queries.add(Map<String, dynamic>.of(query ?? const {}));
    final filtered = query?['status'] != null || query?['category'] != null;
    return {
      'items': filtered
          ? <Map<String, dynamic>>[]
          : [
              {
                'id': 'suggestion-1',
                'submitterId': 'employee-1',
                'submitterName': '员工甲',
                'title': '已有建议',
                'content': '建议内容',
                'category': 'process',
                'status': 'submitted',
                'submittedAt': '2026-10-11T08:00:00+08:00',
              },
            ],
      'page': 1,
      'size': 20,
      'total': filtered ? 0 : 1,
      'totalPages': 1,
    };
  }
}

void main() {
  for (final (key, value) in [('status', 'rejected'), ('category', 'other')]) {
    testWidgets('empty $key result retains header and can clear the filter', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _Api();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SuggestionListPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      MasterDataTableView<Suggestion> table() =>
          tester.widget(find.byKey(const Key('suggestion-list-table')));
      expect(table().items, hasLength(1));
      table().onFilterChanged(key, value);
      await tester.pumpAndSettle();
      expect(table().items, isEmpty);
      expect(table().filters[key], value);
      expect(table().facets[key], isNotEmpty);
      expect(find.text('当前筛选下暂无建议，可调整表头筛选'), findsOneWidget);
      expect(find.text('您还没有提交过建议'), findsNothing);
      expect(find.text('提交第一条建议，与同事一起推动改进'), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      table().onFilterChanged(key, null);
      await tester.pumpAndSettle();
      expect(api.queries.last.containsKey(key), isFalse);
      expect(table().items, hasLength(1));
      expect(find.text('已有建议'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
