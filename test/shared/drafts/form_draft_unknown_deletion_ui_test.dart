import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_table.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_drafts_panel.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';

import '../../helpers/badge_summary_fixture.dart';

FormDraft _draft({
  bool unknown = true,
  bool created = false,
  String revision = 'one',
}) => FormDraft(
  id: 'local',
  title: '采购填写',
  module: BadgeModule.purchase,
  draftKind: 'purchaseOrder',
  route: '/purchase/orders/new',
  permission: Perm.purchaseOrderCreate,
  updatedAt: DateTime(2026, 9, 30),
  revision: revision,
  data: {
    '_formDraftHasUnknownSubmission': unknown,
    if (created) 'createdDocId': 'formal',
  },
);

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.initial);
  final FormDraft initial;
  final deleted = <String>[];
  bool failDelete = false;
  @override
  List<FormDraft> build() => [initial];
  void emit(FormDraft draft) => state = [draft];
  @override
  Future<void> delete(String id, {String? expectedRevision}) async {
    if (failDelete) throw StateError('local CAS/storage failed');
    deleted.add(id);
    state = [];
  }
}

class _Repo extends PurchaseRepository {
  _Repo() : super(ApiClient(Dio()), PurchaseDocType.order);
  Future<void>? detailGate;
  final deletes = <String>[];
  final deleteCalls = <String>[];
  Object? detailError;
  Object? deleteError;
  VoidCallback? beforeDelete;
  @override
  Future<PurchaseDocDetail> detail(String id) async {
    await detailGate;
    if (detailError != null) throw detailError!;
    return PurchaseDocDetail.fromJson({
      'id': id,
      'status': 0,
      'makerId': 'maker',
    });
  }

  @override
  Future<void> delete(String id) async {
    deleteCalls.add(id);
    beforeDelete?.call();
    if (deleteError != null) throw deleteError!;
    deletes.add(id);
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Drafts drafts,
  Widget body, {
  _Repo? repo,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 950));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'owner'),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.purchaseOrderView,
          Perm.purchaseOrderCreate,
          Perm.purchaseOrderDelete,
        }),
        formDraftsProvider.overrideWith(() => drafts),
        fixedBadgeSummaryOverride(),
        if (repo != null)
          purchaseRepositoryProvider(
            PurchaseDocType.order,
          ).overrideWithValue(repo),
        documentScopeCapabilityProvider(
          DocumentDataScope.purchase,
        ).overrideWith(
          (ref) async => const DocumentScopeCapability(
            scope: 'purchase',
            writeAll: true,
            writableOwnerIds: {},
          ),
        ),
        draftWorkspaceRowsProvider(DraftDocKind.purchaseOrder).overrideWith(
          (ref) async => [
            if (repo?.deletes.isEmpty ?? true)
              const DraftWorkspaceRow(
                kind: DraftDocKind.purchaseOrder,
                id: 'formal',
                category: '采购订货单',
                location: '/purchase/orders/formal',
                billNo: 'PO-1',
                deletable: true,
              ),
          ],
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: body),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _workspace = DraftWorkspaceTable(
  kinds: [DraftDocKind.purchaseOrder],
  localScope: FormDraftCategoryScope(kind: 'purchaseOrder'),
);
MasterDataTableView<DraftWorkspaceRow> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<DraftWorkspaceRow>));
Finder get _deleteButton => find.byWidgetPredicate(
  (widget) =>
      widget is UtenButton &&
      widget.child is Text &&
      ((widget.child as Text).data ?? '').startsWith('删除所选草稿'),
);

Future<void> _beginFormalDelete(WidgetTester tester) async {
  _table(tester).onSelectedIdsChanged!({'purchaseOrder:formal'});
  await tester.pump();
  final button = tester.widget<UtenButton>(_deleteButton);
  if (button.onPressed == null) return;
  button.onPressed!();
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认删除'));
  await tester.pump();
}

void main() {
  testWidgets(
    'category formal overlay protects host destructive menu and batch selection',
    (tester) async {
      final drafts = _Drafts(_draft(created: true));
      final selected = <String>{};
      var deletes = 0;
      await _mount(
        tester,
        drafts,
        FormDraftCategoryTable<String>(
          scope: const FormDraftCategoryScope(kind: 'purchaseOrder'),
          table: MasterDataTableView<String>(
            columns: [
              MasterColumnDef(
                key: 'billNo',
                label: '单号',
                width: 180,
                value: (id) => id,
              ),
            ],
            items: const ['formal'],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            selectable: true,
            idOf: (id) => id,
            selectedIds: const {'formal'},
            onSelectedIdsChanged: selected.addAll,
            rowMenuBuilder: (_) => [
              UtenMenuItem(
                label: '删除正式草稿',
                destructive: true,
                onTap: () {
                  deletes++;
                },
              ),
            ],
          ),
        ),
      );
      final table = tester
          .widget<MasterDataTableView<FormDraftCategoryRow<String>>>(
            find.byType(MasterDataTableView<FormDraftCategoryRow<String>>),
          );
      final action = table.rowMenuBuilder!(table.items.single)
          .whereType<UtenMenuItem>()
          .where((item) => item.destructive)
          .single;
      expect(action.enabled, isFalse);
      await action.onTap();
      table.onSelectedIdsChanged!({'formal'});
      expect(deletes, 0);
      expect(selected, isEmpty);
      expect(table.selectedIds, isEmpty);
    },
  );
  testWidgets('formal preflight failure preserves ordinary local input', (
    tester,
  ) async {
    final drafts = _Drafts(_draft(unknown: false, created: true));
    final repo = _Repo()
      ..detailError = ApiException('FORBIDDEN', '权限已撤回', httpStatus: 403);
    await _mount(tester, drafts, _workspace, repo: repo);
    await _beginFormalDelete(tester);
    await tester.pumpAndSettle();
    expect(drafts.deleted, isEmpty);
    expect(repo.deleteCalls, isEmpty);
  });
  for (final unknown in [false, true]) {
    testWidgets(
      'formal DELETE ${unknown ? 'unknown' : 'rejected'} reports prior local discard truthfully',
      (tester) async {
        final drafts = _Drafts(_draft(unknown: false, created: true));
        final repo = _Repo()
          ..deleteError = unknown
              ? NetworkTimeoutException()
              : ApiException('CONFLICT', '正式状态已变化', httpStatus: 409);
        await _mount(tester, drafts, _workspace, repo: repo);
        await _beginFormalDelete(tester);
        await tester.pumpAndSettle();
        expect(drafts.deleted, ['local']);
        expect(repo.deleteCalls, ['formal']);
        final notifications = ProviderScope.containerOf(
          tester.element(find.byType(DraftWorkspaceTable)),
        ).read(appNotificationProvider);
        expect(notifications.last.message, contains('本机填写已按确认清除'));
        expect(notifications.last.message, contains('不会自动恢复'));
        if (unknown) expect(notifications.last.message, contains('删除结果尚未确认'));
      },
    );
  }
  testWidgets(
    'unknown delete UI old panel disables removal but keeps recovery available',
    (tester) async {
      final drafts = _Drafts(_draft());
      await _mount(tester, drafts, const FormDraftsPanel());
      final delete = tester.widget<IconButton>(
        find.byKey(const ValueKey('delete-form-draft-local')),
      );
      expect(delete.onPressed, isNull);
      expect(delete.tooltip, '先核对提交');
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('resume-form-draft-local')),
            )
            .onPressed,
        isNotNull,
      );
      expect(drafts.deleted, isEmpty);
    },
  );

  testWidgets('unknown delete UI category disables row and bulk deletion', (
    tester,
  ) async {
    final drafts = _Drafts(_draft());
    await _mount(
      tester,
      drafts,
      const FormDraftCategoryList(
        scope: FormDraftCategoryScope(kind: 'purchaseOrder'),
      ),
    );
    final table = tester
        .widget<MasterDataTableView<FormDraftCategoryRow<Object>>>(
          find.byType(MasterDataTableView<FormDraftCategoryRow<Object>>),
        );
    final deletion = table.rowMenuBuilder!(table.items.single)
        .whereType<UtenMenuItem>()
        .where((item) => item.destructive)
        .single;
    expect(deletion.enabled, isFalse);
    table.onSelectedIdsChanged!({'form-draft:local'});
    await tester.pump();
    final bulk = tester.widget<UtenButton>(
      find.widgetWithText(UtenButton, '删除填写草稿 (1)'),
    );
    expect(bulk.onPressed, isNull);
    expect(drafts.deleted, isEmpty);
  });

  testWidgets(
    'unknown delete UI bulk confirmation rechecks newly pending records',
    (tester) async {
      final drafts = _Drafts(_draft(unknown: false));
      await _mount(
        tester,
        drafts,
        const FormDraftCategoryList(
          scope: FormDraftCategoryScope(kind: 'purchaseOrder'),
        ),
      );
      final table = tester
          .widget<MasterDataTableView<FormDraftCategoryRow<Object>>>(
            find.byType(MasterDataTableView<FormDraftCategoryRow<Object>>),
          );
      table.onSelectedIdsChanged!({'form-draft:local'});
      await tester.pump();
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '删除填写草稿 (1)'))
          .onPressed!();
      await tester.pumpAndSettle();
      drafts.emit(_draft(revision: 'two'));
      await tester.pump();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(drafts.deleted, isEmpty);
    },
  );

  testWidgets('unknown delete UI formal overlay never dispatches DELETE', (
    tester,
  ) async {
    final drafts = _Drafts(_draft(created: true));
    final repo = _Repo();
    await _mount(tester, drafts, _workspace, repo: repo);
    await _beginFormalDelete(tester);
    await tester.pumpAndSettle();
    expect(repo.deletes, isEmpty);
    expect(drafts.deleted, isEmpty);
  });

  testWidgets(
    'unknown delete UI changed local revision during detail read prevents DELETE',
    (tester) async {
      final gate = Completer<void>();
      final repo = _Repo()..detailGate = gate.future;
      final drafts = _Drafts(_draft(unknown: false, created: true));
      await _mount(tester, drafts, _workspace, repo: repo);
      await _beginFormalDelete(tester);
      drafts.emit(_draft(created: true, revision: 'two'));
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.deletes, isEmpty);
      expect(drafts.deleted, isEmpty);
    },
  );

  testWidgets(
    'unknown delete UI local CAS failure occurs before formal DELETE',
    (tester) async {
      final drafts = _Drafts(_draft(unknown: false, created: true))
        ..failDelete = true;
      final repo = _Repo();
      await _mount(tester, drafts, _workspace, repo: repo);
      await _beginFormalDelete(tester);
      await tester.pumpAndSettle();
      expect(repo.deletes, isEmpty);
      expect(drafts.deleted, isEmpty);
    },
  );

  testWidgets(
    'unknown delete UI known checkpoint discards local revision before formal DELETE',
    (tester) async {
      final drafts = _Drafts(_draft(unknown: false, created: true));
      final localAtDispatch = <List<String>>[];
      final repo = _Repo()
        ..beforeDelete = () => localAtDispatch.add(List.of(drafts.deleted));
      await _mount(tester, drafts, _workspace, repo: repo);
      await _beginFormalDelete(tester);
      await tester.pumpAndSettle();
      expect(drafts.deleted, ['local']);
      expect(repo.deletes, ['formal']);
      expect(localAtDispatch, [
        ['local'],
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}
