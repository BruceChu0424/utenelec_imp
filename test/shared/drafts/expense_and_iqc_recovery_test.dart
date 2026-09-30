import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/expense/pages/expense_claim_edit_page.dart';
import 'package:uten_imp/features/expense/pages/expense_item_dialog.dart';
import 'package:uten_imp/features/quality/pages/quality_pending_disposal_page.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';

import 'memory_form_draft_storage.dart';

const _iqcPath = '${RouteName.warehouseInspections}/PURCHASE/receipt-1';

void main() {
  testWidgets(
    'legacy expense rows without unique local IDs never share extension values',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      final env = await _open(tester, storage, '/expense/new');
      final editor =
          tester.state(find.byType(ExpenseClaimEditPage))
              as FormDraftMixin<ExpenseClaimEditPage>;
      await editor.restoreFormDraft({
        'title': '旧报销草稿',
        'items': [
          for (final description in ['住宿', '车费'])
            {
              'category': 'TRAVEL',
              'date': '2026-09-29',
              'amount': 10,
              'description': description,
            },
          {
            'id': 'kept',
            'category': 'TRAVEL',
            'date': '2026-09-29',
            'amount': 20,
          },
          {
            'id': 'kept',
            'category': 'TRAVEL',
            'date': '2026-09-29',
            'amount': 30,
          },
        ],
      });
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<ExpenseItem>>(
        find.byType(MasterDataTableView<ExpenseItem>),
      );
      expect(table.items.map((item) => item.id).toSet(), hasLength(4));
      expect(table.items.every((item) => item.id.isNotEmpty), isTrue);
      expect(table.items[2].id, 'kept');
      final fields = table.platformBinding!.draftOf!(table.items.first)!;
      fields.setValue(
        const PlatformColumnDefinition(
          id: 'note',
          scope: 'expense_claim_item',
          name: '用途',
        ),
        '项目A',
      );
      expect(table.platformBinding!.draftOf!(table.items[1])!.cells, isEmpty);
      expect(
        table.items.map(table.platformBinding!.recordIdOf),
        everyElement(isNull),
      );
      await editor.saveFormDraftNow();
      final restoredRows = (editor.captureFormDraft()['items'] as List)
          .cast<Map<String, dynamic>>();
      final firstFields = restoredRows[0]['platformFieldDraft'] as Map;
      final secondFields = restoredRows[1]['platformFieldDraft'] as Map;
      final firstCell = (firstFields['cells'] as List).first as Map;
      expect(firstCell['value'], '项目A');
      expect(secondFields['cells'], isEmpty);
      await _dispose(tester, env);
    },
  );
  testWidgets(
    'unfinished expense item survives hard disposal without losing raw input',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      var env = await _open(tester, storage, '/expense/new');
      await tester.enterText(find.byType(TextField).first, '九月出差报销');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '办公用品'));
      final fields = find.descendant(
        of: find.byType(ExpenseItemDialog),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(fields.at(0), '12.');
      await tester.enterText(fields.at(1), '给项目采购材料，尚未录完');
      final editor =
          tester.state(find.byType(ExpenseClaimEditPage))
              as FormDraftMixin<ExpenseClaimEditPage>;
      await editor.saveFormDraftNow();
      final draft = env.container.read(formDraftsProvider).single;
      final pending = draft.data['pendingItem'] as Map<String, dynamic>;
      expect(pending['amount'], '12.');
      expect(pending['category'], 'office');
      expect(pending['description'], '给项目采购材料，尚未录完');
      expect(
        draft.data['items'],
        isEmpty,
        reason: 'unfinished modal is not a validated expense line',
      );
      await _dispose(tester, env);

      env = await _open(tester, storage, draft.resumeLocation);
      final resumedEditor =
          tester.state(find.byType(ExpenseClaimEditPage))
              as FormDraftMixin<ExpenseClaimEditPage>;
      expect(resumedEditor.captureFormDraft()['title'], '九月出差报销');
      expect(resumedEditor.captureFormDraft()['pendingItem'], pending);
      await tester.tap(find.text('继续未完成明细'));
      await tester.pumpAndSettle();
      final restored = tester
          .widgetList<TextFormField>(
            find.descendant(
              of: find.byType(ExpenseItemDialog),
              matching: find.byType(TextFormField),
            ),
          )
          .toList();
      expect(restored[0].controller!.text, '12.');
      expect(restored[1].controller!.text, '给项目采购材料，尚未录完');
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '办公用品'))
            .selected,
        isTrue,
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.text('是否保存未完成的明细？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '保存草稿'));
      await tester.pumpAndSettle();
      expect(find.byType(ExpenseItemDialog), findsNothing);
      expect(
        (env.container.read(formDraftsProvider).single.data['pendingItem']
            as Map<String, dynamic>)['amount'],
        '12.',
      );
      expect(env.api.writes, 0);
      expect(tester.takeException(), isNull);
      await _dispose(tester, env);
    },
  );

  testWidgets(
    'IQC response loss restores frozen report after its live rows disappear',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      final iqc = _Iqc();
      var env = await _open(tester, storage, _iqcPath, iqc: iqc);
      await _prepareIqc(tester);
      await tester.tap(find.byKey(const Key('iqc-submit-report')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '检验原始结论');
      await tester.tap(
        find.byKey(const Key('inspection-report-confirm-submit')),
      );
      await tester.pumpAndSettle();
      expect(iqc.sent.length, 1);
      final frozen = iqc.sent.single;
      final editor =
          tester.state(find.byType(ProcurementInspectionDetailPage))
              as FormDraftMixin<ProcurementInspectionDetailPage>;
      await editor.saveFormDraftNow();
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.data['submission'], isNotNull);
      expect(draft.data['_formDraftSubmissionPending'], isTrue);
      await _dispose(tester, env);

      env = await _open(tester, storage, draft.resumeLocation, iqc: iqc);
      expect(find.text('上次检验报告提交结果待确认'), findsOneWidget);
      await tester.tap(find.text('核对原报告'));
      await tester.pumpAndSettle();
      expect(iqc.sent.length, 2);
      expect(
        iqc.sent.last,
        frozen,
        reason: 'same receipt, quantities, reason and per-line key must replay',
      );
      expect(env.container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester, env);
    },
  );

  testWidgets(
    'IQC definite conflict permits fresh review without dropping entered quantities',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      final iqc = _Iqc()..rejectConflict = true;
      final env = await _open(tester, storage, _iqcPath, iqc: iqc);
      await _prepareIqc(tester);
      await tester.tap(find.byKey(const Key('iqc-submit-report')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '核对结论');
      await tester.tap(
        find.byKey(const Key('inspection-report-confirm-submit')),
      );
      await tester.pumpAndSettle();
      expect(iqc.sent.length, 1);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      final pass = tester.widget<TextField>(
        find.byKey(const Key('iqc-report-pass-item-1')),
      );
      expect(
        pass.enabled,
        isTrue,
        reason:
            'a definite rejected command must be replaceable after fresh authority is read',
      );
      expect(pass.controller!.text, '3.25');
      final state =
          tester.state(find.byType(ProcurementInspectionDetailPage))
              as FormDraftMixin<ProcurementInspectionDetailPage>;
      expect(state.captureFormDraft()['submission'], isNull);
      final restoredRow =
          (state.captureFormDraft()['rows'] as List<dynamic>).single
              as Map<String, dynamic>;
      final rejectedRow =
          (iqc.sent.single['items'] as List<dynamic>).single
              as Map<String, dynamic>;
      expect(restoredRow['key'], isNot(rejectedRow['idempotencyKey']));
      expect(
        env.container
            .read(formDraftsProvider)
            .single
            .data['_formDraftSubmissionPending'],
        isNull,
      );
      expect(
        ((env.container.read(formDraftsProvider).single.data['rows']
                    as List<dynamic>)
                .single
            as Map<String, dynamic>)['pass'],
        '3.25',
      );
      expect(tester.takeException(), isNull);
      await _dispose(tester, env);
    },
  );
}

Future<void> _prepareIqc(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('iqc-report-pass-item-1')),
    '3.25',
  );
  await tester.enterText(
    find.byKey(const Key('iqc-report-fail-item-1')),
    '1.75',
  );
  final table = tester.widget<MasterDataTableView<ProcurementInspectionItem>>(
    find.byKey(const ValueKey('iqc-item-table-receipt-1')),
  );
  table.onSelectedIdsChanged!({'item-1'});
  await tester.pumpAndSettle();
}

typedef _Environment = ({
  ProviderContainer container,
  GoRouter router,
  _Api api,
});

Future<_Environment> _open(
  WidgetTester tester,
  MemoryFormDraftStorage storage,
  String location, {
  _Iqc? iqc,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1050));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = _Api();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue(
        'https://expense-iqc-draft.test/api',
      ),
      sharedPreferencesProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'operator-1'),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.expenseApply,
        Perm.procurementInspectionView,
        Perm.procurementInspectionHandle,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      formDraftStorageProvider.overrideWithValue(storage),
      if (iqc != null)
        procurementInspectionRepositoryProvider.overrideWithValue(iqc),
    ],
  );
  final router = GoRouter(
    initialLocation: location,
    routes: [
      DraftAwareGoRoute(
        path: '/expense/new',
        builder: (_, _) => const ExpenseClaimEditPage(),
      ),
      DraftAwareGoRoute(
        path: _iqcPath,
        builder: (_, _) => const ProcurementInspectionDetailPage(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, router: router, api: api);
}

Future<void> _dispose(WidgetTester tester, _Environment env) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  env.router.dispose();
  env.container.dispose();
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  int writes = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes++;
    throw StateError('No business write expected: $path');
  }
}

class _Iqc extends DioProcurementInspectionRepository {
  _Iqc() : super(_Api());
  bool resolved = false;
  bool rejectConflict = false;
  final sent = <Map<String, dynamic>>[];
  @override
  Future<List<PendingInspectionReceipt>> pendingReceipts() async => resolved
      ? []
      : [
          const PendingInspectionReceipt(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
            billNo: 'SH-001',
            itemCount: 1,
            pendingBaseQty: 5,
          ),
        ];
  @override
  Future<List<ProcurementInspectionItem>> items(
    String receiptType,
    String receiptId,
  ) async => resolved
      ? []
      : [
          const ProcurementInspectionItem(
            id: 'item-1',
            goodsName: '材料',
            goodsCode: 'G1',
            remainingBaseQty: 5,
            baseUnitName: '个',
            unitRate: 1,
            status: 'PENDING',
          ),
        ];
  @override
  Future<void> decideBatch({
    required String receiptType,
    required String receiptId,
    required List<ProcurementInspectionDecideItem> items,
    String? reason,
  }) async {
    sent.add(
      jsonDecode(
            jsonEncode({
              'receiptType': receiptType,
              'receiptId': receiptId,
              'items': items.map((item) => item.toJson()).toList(),
              'reason': reason,
            }),
          )
          as Map<String, dynamic>,
    );
    if (rejectConflict) {
      throw ApiException('CONFLICT', '待检数量已变化', httpStatus: 409);
    }
    resolved = true;
    if (sent.length == 1) throw NetworkTimeoutException();
  }
}
