// 仓库单据详情（生产 DRAW）：出库弹窗备注随首轮「出库即审核」下发；
// 出库凭证区常驻详情页并按状态/权限门控（2026-09-10）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _AllowAllStockDocumentScope implements DocumentScopeCapabilityRepository {
  const _AllowAllStockDocumentScope();

  @override
  Future<DocumentScopeCapability> current(DocumentDataScope scope) async =>
      DocumentScopeCapability(
        scope: scope.apiValue,
        writeAll: true,
        writableOwnerIds: const <String>{},
      );
}

class _DrawDetailApi extends ApiClient {
  _DrawDetailApi({required this.status, required this.issuedQty})
    : super(Dio());

  int status;
  double issuedQty;
  Map<String, dynamic>? posted;
  String? postedPath;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/master/warehouses/dict'
      ? [
          {'id': 'main', 'name': '主仓库', 'accountable': true, 'status': '使用'},
        ]
      : const <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    postedPath = path;
    posted = Map<String, dynamic>.from(body as Map);
    status = 1;
    issuedQty = 5;
    return get('/stock/docs/draw-1');
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/stock/docs/draw-1') {
      throw StateError('Unexpected GET $path');
    }
    return <String, dynamic>{
      'id': 'draw-1',
      'docType': 'DRAW',
      'billNo': 'LL-TEST-001',
      'billDate': '2026-09-10',
      'status': status,
      'warehouseId': 'main',
      'issueStatus': issuedQty > 0 ? 1 : 0,
      'productionLinked': true,
      'canEdit': false,
      'canDelete': false,
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'draw-item-1',
          'lineNo': 1,
          'qty': 5,
          'issuedQty': issuedQty,
          'unitRate': 1,
          'executionSegmentId': 'segment-1',
        },
      ],
    };
  }
}

Future<_DrawDetailApi> _pumpDrawDetail(
  WidgetTester tester, {
  required int status,
  required double issuedQty,
  required Set<String> permissions,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final api = _DrawDetailApi(status: status, issuedQty: issuedQty);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        stockDocRepositoryProvider(
          StockDocType.draw,
        ).overrideWithValue(StockDocRepository(api, StockDocType.draw)),
        documentScopeCapabilityRepositoryProvider.overrideWithValue(
          const _AllowAllStockDocumentScope(),
        ),
        // 附件清单走共享 provider；本测试只验证详情页的常驻区与门控，不打网络。
        businessAttachmentsProvider.overrideWith(
          (ref, owner) async => const <Attachment>[],
        ),
      ],
      child: MaterialApp(
        builder: (context, child) => Stack(
          children: [
            child!,
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppNotificationHost(useSafeArea: false),
            ),
          ],
        ),
        home: const StockDocDetailPage(
          docType: StockDocType.draw,
          id: 'draw-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return api;
}

Finder _persistentSection() => find.byKey(const Key('stock-doc-attachments'));

BusinessAttachmentSection _section(WidgetTester tester) =>
    tester.widget<BusinessAttachmentSection>(_persistentSection());

const _viewer = {Perm.stockDocView, Perm.attachmentView};
const _issuer = {Perm.stockDocView, Perm.attachmentView, Perm.stockDocIssue};
const _approverIssuer = {
  Perm.stockDocView,
  Perm.attachmentView,
  Perm.stockDocIssue,
  Perm.stockDocApprove,
};

void main() {
  testWidgets('first issue of a draft passes the remark to approve-and-issue', (
    tester,
  ) async {
    final api = await _pumpDrawDetail(
      tester,
      status: 0,
      issuedQty: 0,
      permissions: _approverIssuer,
    );

    await tester.tap(find.widgetWithText(UtenButton, '出库'));
    await tester.pumpAndSettle();
    final remarkField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == '备注(选填)',
    );
    expect(remarkField, findsOneWidget);
    expect(
      tester.widget<TextField>(remarkField).maxLength,
      200,
      reason: '输入上限与服务端单条备注上限同值',
    );
    await tester.enterText(remarkField, '首轮出库备注');
    await tester.tap(find.widgetWithText(FilledButton, '确认出库'));
    await tester.pumpAndSettle();

    expect(api.postedPath, endsWith('/approve-and-issue'));
    expect(api.posted?['reason'], '首轮出库备注');
    expect(api.posted?['lines'], isNotEmpty);
  });

  testWidgets('draft attachments are manageable only with approve and issue', (
    tester,
  ) async {
    await _pumpDrawDetail(
      tester,
      status: 0,
      issuedQty: 0,
      permissions: _approverIssuer,
    );
    expect(_persistentSection(), findsOneWidget);
    expect(_section(tester).canView, isTrue);
    expect(_section(tester).canManage, isTrue);
    expect(_section(tester).ownerType, 'STOCK_DOCUMENT');
    expect(_section(tester).ownerId, 'draw-1');

    await _pumpDrawDetail(
      tester,
      status: 0,
      issuedQty: 0,
      permissions: _issuer,
    );
    expect(_section(tester).canManage, isFalse, reason: '草稿=出库即审核，缺审核权限只读');
  });

  testWidgets('approved attachments follow the issue permission', (
    tester,
  ) async {
    await _pumpDrawDetail(
      tester,
      status: 1,
      issuedQty: 5,
      permissions: _issuer,
    );
    expect(_section(tester).canManage, isTrue, reason: '出完后仍能补传/查看凭证');

    await _pumpDrawDetail(
      tester,
      status: 1,
      issuedQty: 5,
      permissions: _viewer,
    );
    expect(_persistentSection(), findsOneWidget, reason: '无出库权限也能看凭证');
    expect(_section(tester).canManage, isFalse);
  });

  testWidgets('reversed document keeps attachments read-only', (tester) async {
    await _pumpDrawDetail(
      tester,
      status: -1,
      issuedQty: 0,
      permissions: _approverIssuer,
    );
    expect(_persistentSection(), findsOneWidget);
    expect(_section(tester).canView, isTrue);
    expect(_section(tester).canManage, isFalse, reason: '红冲单据凭证冻结');
  });

  testWidgets('section is hidden without stock_doc:view', (tester) async {
    await _pumpDrawDetail(
      tester,
      status: 1,
      issuedQty: 5,
      permissions: const {Perm.attachmentView, Perm.stockDocIssue},
    );
    expect(_section(tester).canView, isFalse);
    expect(find.text('出库凭证/照片'), findsNothing);
  });
}
