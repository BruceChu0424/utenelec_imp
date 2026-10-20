import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

typedef _Row = ({String id, String name, int version});

final _boundary = NotifierProvider<_Boundary, SensitiveReadBoundary>(
  _Boundary.new,
);
final _api = ApiClient(Dio());

SensitiveReadBoundary _scope(String id, {bool editable = true}) =>
    SensitiveReadBoundary(
      identity: AuthenticatedScope(userId: id),
      api: _api,
      permissions: {'goods:view', if (editable) 'goods:edit'},
      superAdmin: false,
    );

class _Boundary extends Notifier<SensitiveReadBoundary> {
  @override
  SensitiveReadBoundary build() => _scope('A');
  void replace(SensitiveReadBoundary value) => state = value;
}

PagedResult<_Row> _rows(String owner) => PagedResult(
  items: [
    (id: '1', name: '$owner 私有资料一', version: 1),
    (id: '2', name: '$owner 私有资料二', version: 1),
  ],
  page: 1,
  size: 20,
  total: 2,
  totalPages: 1,
);

class _Host extends ConsumerWidget {
  const _Host({required this.read, required this.save});
  final Future<PagedResult<_Row>> Function(String owner) read;
  final Future<void> Function(String id) save;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(sensitiveReadBoundaryProvider);
    final capturedOwner = scope.identity!.userId;
    return MasterEntityDetailPane<_Row, _Row>(
      categoryId: 'cat',
      externalKeyword: null,
      config: MasterEntityPaneConfig(
        noun: '货品',
        icon: Icons.inventory_2_outlined,
        defaultCodePrefix: 'HP',
        columns: [
          MasterColumnDef(
            key: 'name',
            label: '名称',
            width: 220,
            value: (row) => row.name,
          ),
        ],
        idOf: (row) => row.id,
        labelOf: (row) => row.name,
        statusOf: (_) => '使用',
        versionOf: (row) => row.version,
        loadCategory: (id) async => ProductCategoryDetail(
          id: id,
          code: 'C1',
          name: '分类',
          level: 0,
          path: '分类',
          childCount: 0,
        ),
        // Deliberately capture the owner's repository like the real hosts.
        loadPage: (_) => read(capturedOwner),
        loadFacets: (_) async =>
            const MasterPaneFacets(fields: {}, nullCounts: {}),
        batchEntityPath: '/master/goods',
        statusResourceOf: (id) => '/master/goods/$id',
        canCreate: false,
        canEdit: scope.permissions.contains('goods:edit'),
        canDelete: false,
        canStatus: false,
        inlineFields: {
          'name': MasterInlineField(key: 'name', read: (row) => row.name),
        },
        onInlineSave: (id, _, _) => save(id),
      ),
    );
  }
}

void main() {
  testWidgets(
    'owner replacement uses rebuilt repository closures, ignores late reads and fences the remaining writes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1250, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final originalRead = Completer<PagedResult<_Row>>();
      final pendingWrite = Completer<void>();
      final reads = <String>[];
      final writes = <String>[];
      final container = ProviderContainer(
        overrides: [
          apiBaseUrlProvider.overrideWithValue('https://company.invalid/api'),
          authenticatedScopeProvider.overrideWith(
            (ref) => ref.watch(_boundary).identity,
          ),
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          sensitiveReadBoundaryProvider.overrideWith(
            (ref) => ref.watch(_boundary),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: _Host(
                read: (owner) async {
                  reads.add(owner);
                  return owner == 'A' ? originalRead.future : _rows(owner);
                },
                save: (id) {
                  writes.add(id);
                  return pendingWrite.future;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(reads, ['A']);
      container.read(_boundary.notifier).replace(_scope('B'));
      await tester.pumpAndSettle();
      expect(reads, ['A', 'B']);
      originalRead.complete(_rows('A'));
      await tester.pumpAndSettle();
      expect(find.text('A 私有资料一'), findsNothing);
      expect(find.text('B 私有资料一'), findsOneWidget);

      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      final inputs = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.hintText == '名称',
      );
      await tester.tap(find.byKey(const ValueKey('inline-activate-1-name')));
      await tester.pumpAndSettle();
      await tester.enterText(inputs.at(0), '第一行修改');
      await tester.tap(find.byKey(const ValueKey('inline-activate-2-name')));
      await tester.pumpAndSettle();
      await tester.enterText(inputs.at(1), '第二行修改');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 2 行修改'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(writes, ['1']);
      container.read(_boundary.notifier).replace(_scope('C', editable: false));
      await tester.pumpAndSettle();
      pendingWrite.complete();
      await tester.pumpAndSettle();
      expect(writes, ['1']);
      expect(find.text('B 私有资料一'), findsNothing);
      expect(find.text('C 私有资料一'), findsOneWidget);
      expect(find.text('编辑模式'), findsNothing);
      expect(find.text('保存 1 行修改'), findsNothing);
      expect(inputs, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
