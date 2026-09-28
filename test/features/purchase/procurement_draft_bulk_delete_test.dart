import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_page_factory.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _ListCase {
  const _ListCase.purchase(this.purchase) : subcontract = null;
  const _ListCase.subcontract(this.subcontract) : purchase = null;

  final PurchaseDocType? purchase;
  final SubcontractDocType? subcontract;
  bool get isOrder =>
      purchase == PurchaseDocType.order ||
      subcontract == SubcontractDocType.order;
  String get path => purchase != null
      ? '/purchase/${purchase!.pathSegment}'
      : '/subcontract/${subcontract!.pathSegment}';
  String get viewPerm => purchase != null
      ? PurchaseDocConfig.by(purchase!).listPerm
      : SubcontractDocConfig.by(subcontract!).listPerm;
  String get deletePerm => purchase != null
      ? PurchaseDocConfig.by(purchase!).deletePerm!
      : SubcontractDocConfig.by(subcontract!).deletePerm!;
  Widget page(String? status) => purchase != null
      ? PurchaseDocListPage(docType: purchase!, initialStatus: status)
      : SubcontractPageFactory.list(subcontract!, initialStatus: status);
}

const _cases = [
  _ListCase.purchase(PurchaseDocType.order),
  _ListCase.purchase(PurchaseDocType.receipt),
  _ListCase.purchase(PurchaseDocType.returnDoc),
  _ListCase.subcontract(SubcontractDocType.order),
  _ListCase.subcontract(SubcontractDocType.returnDoc),
  _ListCase.subcontract(SubcontractDocType.materialReturn),
  _ListCase.subcontract(SubcontractDocType.waste),
];

typedef _TableProbe = ({
  bool selectable,
  Set<String> selected,
  List<String> eligible,
  void Function(Set<String>)? select,
  void Function(String, String?) filter,
});

_TableProbe _probe(WidgetTester tester, _ListCase spec) {
  if (spec.purchase != null) {
    final table = tester.widget<MasterDataTableView<PurchaseDocListItem>>(
      find.byWidgetPredicate(
        (w) => w is MasterDataTableView<PurchaseDocListItem>,
      ),
    );
    return (
      selectable: table.selectable,
      selected: table.selectedIds,
      eligible: [
        for (final row in table.items)
          if (table.idOf?.call(row) != null) row.id,
      ],
      select: table.onSelectedIdsChanged,
      filter: table.onFilterChanged,
    );
  }
  final table = tester.widget<MasterDataTableView<SubcontractDocListItem>>(
    find.byWidgetPredicate(
      (w) => w is MasterDataTableView<SubcontractDocListItem>,
    ),
  );
  return (
    selectable: table.selectable,
    selected: table.selectedIds,
    eligible: [
      for (final row in table.items)
        if (table.idOf?.call(row) != null) row.id,
    ],
    select: table.onSelectedIdsChanged,
    filter: table.onFilterChanged,
  );
}

Future<_DraftApi> _pump(
  WidgetTester tester,
  _ListCase spec, {
  bool canDelete = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final api = _DraftApi(spec);
  final router = GoRouter(
    initialLocation: '${spec.path}?status=draft',
    routes: [
      GoRoute(
        path: spec.path,
        builder: (_, state) => spec.page(state.uri.queryParameters['status']),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          spec.viewPerm,
          if (canDelete) spec.deletePerm,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'user-1'),
        ),
        documentScopeCapabilityProvider.overrideWith(
          (ref, scope) async => DocumentScopeCapability(
            scope: scope.apiValue,
            writeAll: false,
            writableOwnerIds: const {'own'},
          ),
        ),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (_, child) => Stack(
          children: [
            Positioned.fill(child: child!),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppNotificationHost(),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  for (final spec in _cases) {
    testWidgets('${spec.path} 草稿仅勾选可删除状态，筛选清除选择', (tester) async {
      await _pump(tester, spec);
      final table = _probe(tester, spec);
      expect(table.selectable, isTrue);
      expect(table.eligible, ['ok-1', 'ok-2', 'readonly', 'changed']);
      table.select!({'ok-1', 'ok-2'});
      await tester.pumpAndSettle();
      expect(find.text('删除所选草稿 (2)'), findsOneWidget);
      expect(_probe(tester, spec).selected, {'ok-1', 'ok-2'});

      _probe(tester, spec).filter('supplier', 'supplier-2');
      await tester.pumpAndSettle();
      expect(_probe(tester, spec).selected, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final spec in [_cases.first, _cases[3]]) {
    testWidgets('${spec.path} 无删除权限不提供批量删除或多选', (tester) async {
      await _pump(tester, spec, canDelete: false);
      expect(_probe(tester, spec).selectable, isFalse);
      expect(find.textContaining('删除所选草稿'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${spec.path} 删除逐张复核当前状态和归属，仅成功单移除', (tester) async {
      final api = await _pump(tester, spec);
      _probe(tester, spec).select!({'ok-1', 'readonly', 'changed', 'ok-2'});
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除所选草稿 (4)'));
      await tester.pumpAndSettle();
      expect(api.deleted, isEmpty, reason: '确认之前不发删除');
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();

      expect(api.detailReads, ['ok-1', 'readonly', 'changed', 'ok-2']);
      expect(api.deleted, ['ok-1', 'ok-2']);
      expect(_probe(tester, spec).selected, {'readonly', 'changed'});
      expect(find.textContaining('2 张未删除'), findsOneWidget);

      // 财审中仍是 status=0，但该分段不允许批量删除。
      final stage = spec.purchase != null ? '等待财务审核' : '进行中';
      await tester.tap(find.text(stage).first);
      await tester.pumpAndSettle();
      expect(_probe(tester, spec).selectable, isFalse);
      expect(_probe(tester, spec).selected, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}

class _DraftApi extends ApiClient {
  _DraftApi(this.spec) : super(Dio());

  final _ListCase spec;
  final List<String> deleted = [];
  final List<String> detailReads = [];

  List<Map<String, dynamic>> get rows => [
    for (final id in [
      'ok-1',
      'ok-2',
      'readonly',
      'changed',
      'approved',
      'legacy',
      'closed',
      if (spec.isOrder) ...['pending', 'rejected', 'finance-approved'],
    ])
      if (!deleted.contains(id))
        {
          'id': id,
          'billNo': 'DOC-$id',
          'billDate': '2026-09-26',
          'status': id == 'approved' ? 1 : 0,
          'closed': id == 'closed',
          'legacyImported': id == 'legacy',
          if (spec.isOrder)
            'financeApproval': {
              'status': switch (id) {
                'pending' => 'PENDING',
                'rejected' => 'REJECTED',
                'finance-approved' => 'APPROVED',
                _ => 'DRAFT',
              },
            },
        },
  ];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/status-counts')) return const {'DRAFT': 4};
    if (path.endsWith('/facets')) return const {'items': <Object>[]};
    if (path.endsWith(spec.path)) {
      return {'items': rows, 'page': 1, 'total': rows.length, 'totalPages': 1};
    }
    if (path.contains('${spec.path}/')) {
      final id = path.split('/').last;
      detailReads.add(id);
      return {
        ...rows.firstWhere((row) => row['id'] == id),
        'makerId': id == 'readonly' ? 'other-owner' : 'own',
        if (id == 'changed') 'status': 1,
        'items': <Object>[],
      };
    }
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    deleted.add(path.split('/').last);
  }
}
