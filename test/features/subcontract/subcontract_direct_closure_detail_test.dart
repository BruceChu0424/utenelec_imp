import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart' as names;

import '../../support/document_scope_capability_overrides.dart';
import '../../support/native_detail_reader_overrides.dart';

class _ClosureDetailApi extends ApiClient {
  _ClosureDetailApi({required this.completed, this.includeSummary = true})
    : super(Dio());
  final bool completed;
  final bool includeSummary;
  int previewReads = 0;

  Map<String, dynamic> get line => {
    'orderItemId': 'item-1',
    'lineNo': 1,
    'goodsCode': 'G001',
    'goodsName': '铜线',
    'unitName': '公斤',
    'orderedQty': '100.0001',
    'receivedQty': '40',
    'remainingQty': '60.0001',
    'remainingGiftQty': '2',
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/closure-preview')) {
      previewReads++;
      return {
        'billNo': 'WO-DIRECT-1',
        'fingerprint': 'current-facts',
        'canSubmit': true,
        'items': [line],
      };
    }
    if (path == '/subcontract/orders/order-1') {
      return {
        'id': 'order-1',
        'makerId': 'maker-1',
        'billNo': 'WO-DIRECT-1',
        'status': 1,
        'closed': completed,
        'canReverse': true,
        'financeApproval': {'status': 'APPROVED'},
        if (includeSummary)
          'closureRequest': {
            'caseId': 'close-1',
            'status': completed ? 'APPROVED' : 'PENDING',
            'mode': 'CLOSE',
            if (completed) ...{
              'executionMode': 'DIRECT',
              'closedByName': '委外员张三',
              'closedAt': '2026-10-26T02:30:00Z',
            },
            'reason': '生产用量已满足',
            'items': [line],
          },
        'items': [
          {'id': 'item-1', 'qty': 100.0001, 'price': 5},
        ],
      };
    }
    return {};
  }
}

void main() {
  for (final scenario in [
    (completed: false, includeSummary: true),
    (completed: true, includeSummary: true),
    (completed: true, includeSummary: false),
  ]) {
    final completed = scenario.completed;
    testWidgets(
      !scenario.includeSummary
          ? 'naturally completed subcontract retains quantity changes but cannot cancel remaining delivery'
          : completed
          ? '委外直接结束详情显示取消数量并停用再次结束'
          : '委外历史结束申请能由业务人员重新直接结束且无需财务权限',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = _ClosureDetailApi(
          completed: completed,
          includeSummary: scenario.includeSummary,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...nativeDetailReaderOverrides(),
              subcontractWriteAllDocumentScope(),
              currentPermissionsProvider.overrideWithValue(const {
                Perm.subcontractOrderView,
                Perm.subcontractOrderSubmitFinance,
                Perm.subcontractOrderReverse,
                Perm.subcontractOrderChangeQty,
              }),
              apiClientProvider.overrideWithValue(api),
              subcontractRepositoryProvider(
                SubcontractDocType.order,
              ).overrideWithValue(
                SubcontractRepository(api, SubcontractDocType.order),
              ),
              names.masterNameServiceProvider.overrideWithValue(
                names.MasterNameService(api),
              ),
            ],
            child: const MaterialApp(
              locale: Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: SubcontractDocDetailPage(
                docType: SubcontractDocType.order,
                id: 'order-1',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final action = find.byKey(const Key('subcontract-order-request-close'));
        expect(action, findsOneWidget);
        expect(tester.widget<UtenButton>(action).onPressed == null, completed);
        if (scenario.includeSummary) expect(find.text('反审'), findsNothing);
        expect(
          find.byKey(const Key('subcontract-order-change-qty')),
          scenario.includeSummary ? findsNothing : findsOneWidget,
        );
        if (completed && scenario.includeSummary) {
          expect(find.text('已直接结束'), findsOneWidget);
          expect(find.textContaining('取消未收数量: 60.0001 公斤'), findsOneWidget);
          expect(find.textContaining('委外员张三'), findsOneWidget);
          expect(api.previewReads, 0);
        } else if (!completed) {
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(api.previewReads, 1);
          expect(
            find.byKey(const Key('procurement-order-closure-dialog')),
            findsOneWidget,
          );
          expect(find.textContaining('无需财务批准'), findsWidgets);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
