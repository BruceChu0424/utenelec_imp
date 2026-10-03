// The three audited failures through the real Mixin with its explicit stable-row
// hook. Derived rows are reconstructed independently of persisted business rows.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/identified_platform_drafts.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _Storage implements FormDraftStorage {
  final records = <String, String>{};
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final e in records.entries)
      if (e.key.startsWith(prefix)) e.key: e.value,
  };
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    records.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}

class _Row extends EditableGridRow {
  _Row(this.businessId);
  final String businessId;
  bool get product => businessId.startsWith('product:');
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({super.key, required this.rowIds});
  // Simulates fresh custody/allocation reconstruction after the business codec.
  // A created-report checkpoint reconstructs only products, matching page:357.
  final List<String> rowIds;
  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> with FormDraftMixin<_Editor> {
  final grid = UtenEditableGridController<_Row>();
  String note = '';
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec => const FormDraftSpec(
    title: '日报动态行审计夹具',
    module: BadgeModule.sales,
    route: '/new',
    permission: 'test:create',
  );
  @override
  Iterable<Listenable> get formDraftListenables => [grid];
  Iterable<IdentifiedPlatformDraftRow> get fields => [
    for (final row in grid.rows.where((row) => row.product))
      IdentifiedPlatformDraftRow(row.businessId, row.platformFields),
  ];
  @override
  Object? captureFormDraftPlatformFields() =>
      captureIdentifiedPlatformDrafts(fields);
  @override
  Future<void> restoreFormDraftPlatformFields(Object? snapshot) async {
    restoreIdentifiedPlatformDrafts(snapshot, fields);
  }

  @override
  Map<String, dynamic> captureFormDraft() => {
    'note': note,
    'rows': [for (final r in grid.rows.where((r) => r.product)) r.businessId],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    note = data['note'] as String? ?? '';
    // The real daily page restores product IDs, then rebuilds derived children.
    final products = (data['rows'] as List).cast<String>().toSet();
    if (widget.rowIds
        .where((id) => id.startsWith('product:'))
        .toSet()
        .difference(products)
        .isNotEmpty) {
      throw StateError('fixture cannot invent a product');
    }
    grid.replaceAll([for (final id in widget.rowIds) _Row(id)]);
  }

  @override
  void initState() {
    super.initState();
    grid.replaceAll([for (final id in widget.rowIds) _Row(id)]);
    WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());
  }

  @override
  void dispose() {
    grid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => withFormDraft(
    const Scaffold(body: Text('业务编辑区', key: Key('business-body'))),
  );
}

Future<({GoRouter router, ProviderContainer container})> _open(
  WidgetTester tester,
  _Storage storage,
  List<String> rows, {
  String location = '/new',
}) async {
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWith(
        (_) => const AuthenticatedScope(userId: 'row-audit-user'),
      ),
      currentPermissionsProvider.overrideWithValue({'test:create'}),
      apiBaseUrlProvider.overrideWith((_) => 'https://isolated.invalid/api'),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final router = GoRouter(
    initialLocation: location,
    routes: [
      DraftAwareGoRoute(
        path: '/new',
        builder: (_, state) => _Editor(key: state.pageKey, rowIds: rows),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, container: container);
}

Future<void> _close(
  WidgetTester tester,
  ({GoRouter router, ProviderContainer container}) env,
) async {
  await tester.pumpWidget(const SizedBox());
  env.router.dispose();
  env.container.dispose();
}

void main() {
  for (final restoredRows in [
    ['product:A', 'material:a', 'allocation:a', 'product:B'],
    ['product:A', 'product:B'],
  ]) {
    testWidgets(
      'empty extension drafts tolerate changed derived rows $restoredRows',
      (tester) async {
        final storage = _Storage();
        var env = await _open(tester, storage, [
          'product:A',
          'material:a',
          'product:B',
        ]);
        final editor = tester.state<_EditorState>(find.byType(_Editor));
        editor.note = 'already entered business input';
        await editor.saveFormDraftNow();
        final draft = env.container.read(formDraftsProvider).single;
        final original = Map<String, String>.of(storage.records);
        await _close(tester, env);
        env = await _open(
          tester,
          storage,
          restoredRows,
          location: draft.resumeLocation,
        );
        expect(
          find.text('这份草稿暂时无法恢复，原草稿已保留。'),
          findsNothing,
          reason:
              'No writable extension values exist; derived rows may grow, shrink, '
              'or disappear after an accepted report checkpoint.',
        );
        expect(
          storage.records,
          original,
          reason: 'Recovery cannot rewrite evidence.',
        );
        await _close(tester, env);
      },
    );
  }

  testWidgets(
    'same row count cannot move product extension onto a different product',
    (tester) async {
      final storage = _Storage();
      var env = await _open(tester, storage, [
        'product:A',
        'material:a',
        'product:B',
        'product:C',
      ]);
      final editor = tester.state<_EditorState>(find.byType(_Editor));
      final b = editor.grid.rows.singleWhere(
        (r) => r.businessId == 'product:B',
      );
      b.platformFields.setValue(
        const PlatformColumnDefinition(
          id: 'external-reference',
          scope: 'production_daily_report_item',
          name: '外部批号',
        ),
        'B-ONLY',
      );
      await editor.saveFormDraftNow();
      final draft = env.container.read(formDraftsProvider).single;
      final original = Map<String, String>.of(storage.records);
      await _close(tester, env);
      env = await _open(tester, storage, [
        'product:A',
        'product:B',
        'product:C',
        'material:c',
      ], location: draft.resumeLocation);
      final restored = tester.state<_EditorState>(find.byType(_Editor));
      final c = restored.grid.rows.singleWhere(
        (r) => r.businessId == 'product:C',
      );
      expect(
        c.platformFields.cells.any((cell) => cell.value == 'B-ONLY'),
        isFalse,
        reason:
            'Legacy positional metadata must fail closed or recover by proven '
            'identity; same length alone does not prove identity.',
      );
      expect(
        storage.records,
        original,
        reason: 'Never overwrite the legacy evidence.',
      );
      await _close(tester, env);
    },
  );
}
