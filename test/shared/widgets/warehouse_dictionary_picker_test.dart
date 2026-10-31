import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/master_party_lookup.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/widgets/warehouse_picker_panel.dart';
import 'package:uten_imp/shared/widgets/warehouse_selection.dart';

final _epoch = StateProvider<int>((ref) => 0);

class _ExportEpoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void retire() => state++;
}

const _warehouses = <Map<String, dynamic>>[
  {'id': 'root', 'code': 'WH000001', 'name': '主仓库', 'status': '使用'},
  {
    'id': 'package',
    'code': 'WH000008',
    'name': '包材仓库',
    'parentId': 'root',
    'status': '使用',
    'accountable': true,
    'selectableForNew': true,
  },
];

class _Api extends ApiClient {
  _Api() : super(Dio());
  int calls = 0, failures = 0;
  Completer<List<Map<String, dynamic>>>? pending;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.warehousesDict) return [];
    calls++;
    if (failures-- > 0) throw ApiException('FORBIDDEN', '没有仓库查看权限');
    return pending?.future ?? _warehouses;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Api api, {
  bool realPartyScope = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        if (!realPartyScope)
          masterPartyLookupProvider.overrideWithValue(MasterPartyLookup(api)),
        exportContextEpochProvider.overrideWith(_ExportEpoch.new),
        masterDataSessionKeyProvider.overrideWith(
          (ref) => ref.watch(_epoch).toString(),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showUtenWarehouseDictionaryPickerPanel(
                context,
                use: WarehouseUse.goodIn,
              ),
              child: const Text('选仓'),
            ),
          ),
        ),
      ),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.text('选仓')));
}

void main() {
  testWidgets(
    'successful warehouse read is restored after the real party-scope dependency replaces the names service',
    (tester) async {
      final api = _Api();
      final container = await _pump(tester, api, realPartyScope: true);
      final first = container.read(masterNameServiceProvider);
      await first.ensureWarehousesLoaded();
      expect(first.warehouseHierarchy, hasLength(2));
      (container.read(exportContextEpochProvider.notifier) as _ExportEpoch)
          .retire();
      await tester.pump();
      final replacement = container.read(masterNameServiceProvider);
      expect(identical(replacement, first), isFalse);
      expect(
        replacement.warehouseHierarchy,
        isEmpty,
        reason:
            'This is the original empty-picker root cause even when the warehouse API returned 200.',
      );
      await tester.tap(find.text('选仓'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-root')));
      await tester.pumpAndSettle();
      expect(find.text('包材仓库'), findsOneWidget);
      expect(
        api.calls,
        1,
        reason:
            'The current-session dictionary is reused, not fetched for every field.',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'initial optional failure recovers on selection without granting rights',
    (tester) async {
      final api = _Api()..failures = 1;
      final container = await _pump(tester, api);
      await container.read(masterNameServiceProvider).ensureWarehousesLoaded();
      expect(
        container.read(masterNameServiceProvider).warehouseHierarchy,
        isEmpty,
      );
      await tester.tap(find.text('选仓'));
      await tester.pumpAndSettle();
      expect(api.calls, 2);
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-root')));
      await tester.pumpAndSettle();
      expect(find.text('包材仓库'), findsOneWidget);
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-package')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('包材仓库'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'required failure has a real error and retry instead of maintenance guidance',
    (tester) async {
      final api = _Api()..failures = 1;
      await _pump(tester, api);
      await tester.tap(find.text('选仓'));
      await tester.pumpAndSettle();
      expect(find.text('没有仓库查看权限'), findsOneWidget);
      expect(find.byKey(const Key('warehouse-picker-confirm')), findsNothing);
      await tester.tap(find.byKey(const Key('warehouse-picker-retry')));
      await tester.pumpAndSettle();
      expect(api.calls, 2);
      expect(
        find.byKey(const Key('warehouse-picker-entry-root')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'session replacement retires old hierarchy and pending selection',
    (tester) async {
      final api = _Api();
      final container = await _pump(tester, api);
      await tester.tap(find.text('选仓'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-root')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-package')));
      await tester.pumpAndSettle();
      api.pending = Completer<List<Map<String, dynamic>>>();
      container.read(_epoch.notifier).state++;
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('warehouse-picker-loading')), findsOneWidget);
      expect(find.text('包材仓库'), findsNothing);
      expect(find.byKey(const Key('warehouse-picker-confirm')), findsNothing);
      api.pending!.complete([]);
      await tester.pumpAndSettle();
      expect(find.text('暂无仓库资料，请联系仓库管理员维护'), findsOneWidget);
      expect(find.text('包材仓库'), findsNothing);
      api.pending = null;
      await tester.tap(find.byKey(const Key('warehouse-picker-refresh-empty')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('warehouse-picker-entry-root')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
