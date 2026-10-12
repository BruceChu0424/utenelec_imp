import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/settlement_method_admin.dart';
import 'package:uten_imp/features/basic_data/pages/settlement_method_page.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Repository extends ReferenceMethodRepository {
  _Repository() : super(ApiClient(Dio()));
  final requests =
      <(Map<String, String?>, Completer<List<SettlementMethodAdminItem>>)>[];

  @override
  Future<List<SettlementMethodAdminItem>> settlementAdminList({
    Map<String, String?> filters = const {},
  }) {
    final completion = Completer<List<SettlementMethodAdminItem>>();
    requests.add((Map.of(filters), completion));
    return completion.future;
  }

  @override
  Future<SettlementMethodFacets> settlementAdminFacets() async =>
      const SettlementMethodFacets(fields: {}, nullCounts: {});
}

SettlementMethodAdminItem _item(String name) => SettlementMethodAdminItem(
  id: name,
  name: name,
  termsBase: 'RECEIPT_DATE',
  dueRule: 'NET_DAYS',
  defaultDueDays: 0,
  monthsAhead: 0,
);

void main() {
  for (final oldFails in [false, true]) {
    testWidgets(
      'old ${oldFails ? 'failure' : 'result'} cannot replace cleared status',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final repository = _Repository();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              referenceMethodRepositoryProvider.overrideWithValue(repository),
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: SettlementMethodPage(),
            ),
          ),
        );
        await tester.pump();
        repository.requests[0].$2.complete([_item('初始方式')]);
        await tester.pumpAndSettle();
        MasterDataTableView<SettlementMethodAdminItem> table() => tester.widget(
          find.byWidgetPredicate(
            (widget) =>
                widget is MasterDataTableView<SettlementMethodAdminItem>,
          ),
        );
        table().onFilterChanged('status', '禁用');
        await tester.pump();
        table().onFilterChanged('status', null);
        await tester.pump();
        expect(repository.requests[1].$1['status'], '禁用');
        expect(repository.requests[2].$1.containsKey('status'), isFalse);
        repository.requests[2].$2.complete([_item('当前方式')]);
        await tester.pumpAndSettle();
        if (oldFails) {
          repository.requests[1].$2.completeError(StateError('旧请求失败'));
        } else {
          repository.requests[1].$2.complete([_item('过时禁用方式')]);
        }
        await tester.pumpAndSettle();
        expect(table().items.single.name, '当前方式');
        expect(table().filters['status'], isNull);
        expect(find.text('过时禁用方式'), findsNothing);
        expect(find.text('加载结算方式失败'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
