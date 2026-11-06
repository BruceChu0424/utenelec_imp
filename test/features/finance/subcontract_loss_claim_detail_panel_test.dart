import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/payables/repositories/subcontract_loss_claim_repository.dart';
import 'package:uten_imp/features/finance/payables/widgets/subcontract_loss_claim_detail_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/components/data_display/uten_detail_summary_card.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';

import '../../attachments/attachment_test_actions.dart';

void main() {
  testWidgets(
    'loss offset candidate picker reads all eligible supplier payables and retains exact amount on later rows',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _DetailApi(_openDetail)..payableCount = 205;
      await _pump(
        tester,
        detail: _openDetail,
        api: api,
        permissions: const {
          Perm.subcontractLossClaimView,
          Perm.subcontractLossClaimReview,
          Perm.financeViewAll,
        },
      );
      await tester.tap(find.text('责任决定'));
      await tester.pumpAndSettle();
      final dropdown = tester.widget<UtenDropdownField>(
        find.byType(UtenDropdownField).last,
      );
      dropdown.onChanged('AP_OFFSET');
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择同供应商正应付'));
      await tester.pumpAndSettle();
      expect(api.payableReads, [
        {'page': 1, 'size': 200, 'supplierId': 'supplier-1'},
        {'page': 2, 'size': 200, 'supplierId': 'supplier-1'},
      ]);
      final list = find.byType(ListView).last;
      expect(tester.widget<ListView>(list).semanticChildCount, 205);
      final scroll = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final last = find.widgetWithText(CheckboxListTile, 'PI-204 · —');
      await tester.scrollUntilVisible(
        last,
        500,
        scrollable: scroll,
        maxScrolls: 65,
      );
      await tester.tap(last);
      await tester.pump();
      final amount = find.descendant(
        of: last,
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(amount).controller!.text, '100.0001');
      await tester.enterText(amount, '0.0001');
      expect(api.payableReads, hasLength(2));
      expect(find.text('加载更多'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cash fulfillment uses minimum account references without account master permission',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _DetailApi(_awaitingDetail);
      await _pump(
        tester,
        detail: _awaitingDetail,
        api: api,
        permissions: {
          Perm.subcontractLossClaimView,
          Perm.subcontractLossClaimFulfill,
        },
      );
      await tester.tap(find.text('登记履约').first);
      await tester.pumpAndSettle();
      expect(api.accountReads, ['/business-references/accounts']);
      final accounts = tester.widget<UtenDropdownField>(
        find.byType(UtenDropdownField),
      );
      expect(accounts.items.map((item) => item.value), ['cash', 'bank']);
      expect(find.textContaining('银行账号'), findsNothing);
      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1001 · 现金账户').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '履约证据(必填)',
        ),
        '实际到账凭证',
      );
      await tester.tap(find.text('确认履约'));
      await tester.pumpAndSettle();
      expect(api.fulfillments, hasLength(1));
      expect(api.fulfillments.single['accountId'], 'cash');
      expect(api.fulfillments.single['fulfilledQuantity'], '3.0000');
      expect(
        api.fulfillments.single['expectedCaseVersion'],
        _summaryBase['version'],
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final scenario in [
    (
      status: 'OPEN',
      review: true,
      masked: false,
      visible: true,
      writable: true,
    ),
    (
      status: 'DISPUTED',
      review: true,
      masked: false,
      visible: true,
      writable: true,
    ),
    (
      status: 'AWAITING_FULFILLMENT',
      review: true,
      masked: false,
      visible: true,
      writable: false,
    ),
    (
      status: 'OPEN',
      review: false,
      masked: false,
      visible: true,
      writable: false,
    ),
    (
      status: 'OPEN',
      review: true,
      masked: true,
      visible: false,
      writable: false,
    ),
  ]) {
    testWidgets(
      'loss originals freeze at decision: ${scenario.status}/${scenario.review}/${scenario.masked}',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _pump(
          tester,
          detail: {
            ..._openDetail,
            'summary': {
              ..._summaryBase,
              'status': scenario.status,
              'priceMasked': scenario.masked,
            },
          },
          permissions: {
            Perm.subcontractLossClaimView,
            Perm.financeViewAll,
            Perm.attachmentView,
            Perm.attachmentUpload,
            if (scenario.review) Perm.subcontractLossClaimReview,
          },
        );
        expect(
          find.text('损耗和责任凭证'),
          scenario.visible ? findsOneWidget : findsNothing,
        );
        expectAttachmentUploadAvailable(tester, available: scenario.writable);
        if (scenario.visible) {
          final section = tester.widget<BusinessAttachmentSection>(
            find.byType(BusinessAttachmentSection),
          );
          expect(section.ownerType, 'SUBCONTRACT_LOSS_CASE');
          expect(section.ownerId, 'case-1');
          expect(section.canManage, scenario.writable);
        }
      },
    );
  }

  testWidgets(
    'cash and physical plans are actionable while service reduction stays dedicated',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pump(
        tester,
        detail: _awaitingDetail,
        permissions: const {
          Perm.subcontractLossClaimView,
          Perm.subcontractLossClaimFulfill,
          Perm.subcontractLossClaimReverse,
        },
      );

      expect(find.text('等待专用资金到账，不可手工完成'), findsNothing);
      expect(find.text('等待红字发票或供应商贷项凭证，不可手工完成'), findsOneWidget);
      expect(find.text('登记履约'), findsNWidgets(2));
      expect(find.text('反转责任决定'), findsOneWidget);
      expect(find.text('责任决定'), findsNothing);
      expect(find.text('账面损失'), findsNothing);
      expect(find.text('索赔额'), findsNothing);
      expect(find.text('单位账面价值'), findsNothing);
      expect(find.textContaining('金额 ¥'), findsNothing);

      await tester.tap(find.text('登记履约').first);
      await tester.pumpAndSettle();
      final quantityField = tester.widget<TextField>(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '整笔履约数量',
        ),
      );
      expect(quantityField.readOnly, isTrue);
      expect(quantityField.decoration?.hintText, '整笔履约数量');
      expect(find.text('方案金额(本币)'), findsNothing);
    },
  );

  testWidgets('action buttons are hidden without action permissions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      detail: _awaitingDetail,
      permissions: const {Perm.subcontractLossClaimView},
    );

    expect(find.text('等待专用资金到账，不可手工完成'), findsNothing);
    expect(find.text('等待红字发票或供应商贷项凭证，不可手工完成'), findsOneWidget);
    expect(find.text('登记履约'), findsNothing);
    expect(find.text('反转责任决定'), findsNothing);
  });

  testWidgets('fulfilled cash and material resolutions expose reverse action', (
    tester,
  ) async {
    await _pump(
      tester,
      detail: _fulfilledDetail,
      permissions: const {
        Perm.subcontractLossClaimView,
        Perm.subcontractLossClaimFulfill,
        Perm.subcontractLossClaimReverse,
      },
    );

    expect(find.text('反转履约'), findsWidgets);
  });

  testWidgets('open case exposes review action only with review permission', (
    tester,
  ) async {
    await _pump(
      tester,
      detail: _openDetail,
      permissions: const {
        Perm.subcontractLossClaimView,
        Perm.subcontractLossClaimReview,
      },
    );

    expect(find.text('责任决定'), findsOneWidget);
    expect(find.text('反转责任决定'), findsNothing);
  });

  testWidgets('finance-wide viewer retains monetary facts', (tester) async {
    await _pump(
      tester,
      detail: _awaitingDetail,
      permissions: const {Perm.subcontractLossClaimView, Perm.financeViewAll},
    );

    expect(
      find.descendant(
        of: find.byType(UtenDetailSummaryCard),
        matching: find.text('账面损失'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(UtenDetailSummaryCard),
        matching: find.text('索赔额'),
      ),
      findsOneWidget,
    );
    expect(find.text('单位账面价值'), findsOneWidget);
    expect(find.textContaining('金额 ¥'), findsWidgets);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required Map<String, dynamic> detail,
  required Set<String> permissions,
  _DetailApi? api,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final client = api ?? _DetailApi(detail);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        sharedPreferencesProvider.overrideWithValue(preferences),
        businessAttachmentsProvider((
          type: 'SUBCONTRACT_LOSS_CASE',
          id: 'case-1',
        )).overrideWith((ref) async => []),
        subcontractLossClaimRepositoryProvider.overrideWithValue(
          SubcontractLossClaimRepository(client),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SubcontractLossClaimDetailPanel(caseId: 'case-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _summaryBase = <String, dynamic>{
  'id': 'case-1',
  'wasteId': 'waste-1',
  'wasteBillNo': 'SW-001',
  'supplierId': 'supplier-1',
  'supplierName': '精密加工厂',
  'actualLossQty': '10.0000',
  'allowedLossQty': '3.0000',
  'excessLossQty': '7.0000',
  'lossBookValueLocal': '70.0000',
  'claimAmountLocal': '100.0000',
  'version': 4,
};

const _line = <String, dynamic>{
  'id': 'line-1',
  'goodsCode': 'G-01',
  'goodsName': '铜料',
  'actualLossQty': '10.0000',
  'allowedLossQty': '3.0000',
  'excessLossQty': '7.0000',
  'unitBookValueLocal': '10.0000',
  'lossBookValueLocal': '70.0000',
  'valuationStatus': 'VALUED',
};

const _awaitingDetail = <String, dynamic>{
  'summary': <String, dynamic>{
    ..._summaryBase,
    'status': 'AWAITING_FULFILLMENT',
  },
  'lines': [_line],
  'resolutions': <Map<String, dynamic>>[
    {
      'id': 'cash-1',
      'caseLineId': 'line-1',
      'type': 'CASH_COMPENSATION',
      'quantity': '3.0000',
      'amountLocal': '30.0000',
      'status': 'PENDING',
    },
    {
      'id': 'service-1',
      'caseLineId': 'line-1',
      'type': 'SERVICE_PRICE_REDUCTION',
      'quantity': '1.0000',
      'amountLocal': '10.0000',
      'status': 'PENDING',
    },
    {
      'id': 'material-1',
      'caseLineId': 'line-1',
      'type': 'MATERIAL_REPLACEMENT',
      'quantity': '4.0000',
      'amountLocal': '0.0000',
      'status': 'PENDING',
    },
  ],
  'events': <Map<String, dynamic>>[],
};

const _fulfilledDetail = <String, dynamic>{
  'summary': <String, dynamic>{..._summaryBase, 'status': 'RESOLVED'},
  'lines': [_line],
  'resolutions': <Map<String, dynamic>>[
    {
      'id': 'cash-fulfilled',
      'caseLineId': 'line-1',
      'type': 'CASH_COMPENSATION',
      'quantity': '1.0000',
      'amountLocal': '10.0000',
      'status': 'FULFILLED',
    },
    {
      'id': 'material-fulfilled',
      'caseLineId': 'line-1',
      'type': 'MATERIAL_REPLACEMENT',
      'quantity': '1.0000',
      'amountLocal': '0.0000',
      'status': 'FULFILLED',
    },
    {
      'id': 'output-fulfilled',
      'caseLineId': 'line-1',
      'type': 'OUTPUT_REPLACEMENT',
      'quantity': '1.0000',
      'amountLocal': '0.0000',
      'status': 'FULFILLED',
      'fulfillmentDocType': 'SUBCONTRACT_RECEIPT',
      'fulfillmentDocId': '11111111-1111-4111-8111-111111111111',
      'fulfillmentDocNo': 'SRI-001',
    },
  ],
  'events': <Map<String, dynamic>>[],
};

const _openDetail = <String, dynamic>{
  'summary': <String, dynamic>{..._summaryBase, 'status': 'OPEN'},
  'lines': [_line],
  'resolutions': <Map<String, dynamic>>[],
  'events': <Map<String, dynamic>>[],
};

class _DetailApi extends ApiClient {
  _DetailApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;
  final accountReads = <String>[];
  int? payableCount;
  final payableReads = <Map<String, dynamic>>[];
  final fulfillments = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/platform-columns/scopes') return const [];
    accountReads.add(path);
    if (path != '/business-references/accounts') {
      throw StateError('Unexpected full account source $path');
    }
    return [
      {
        'id': 'cash',
        'code': '1001',
        'name': '现金账户',
        'accountType': 'CASH',
        'status': '使用',
      },
      {
        'id': 'bank',
        'code': '1002',
        'name': '银行账户',
        'accountType': 'BANK',
        'status': '使用',
      },
      {
        'id': 'ordinary',
        'code': 'other',
        'name': '普通往来户',
        'accountType': 'GENERAL',
        'status': '使用',
      },
      {
        'id': 'disabled',
        'code': 'old',
        'name': '停用户',
        'accountType': 'CASH',
        'status': '禁用',
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (!path.endsWith('/fulfill')) {
      throw StateError('Unexpected command $path');
    }
    fulfillments.add(Map<String, dynamic>.from(body! as Map));
    return detail;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/payables' && payableCount != null) {
      payableReads.add({...?query});
      final page = query!['page'] as int;
      final size = query['size'] as int;
      final total = payableCount!;
      return {
        'page': page,
        'size': size,
        'total': total,
        'totalPages': (total + size - 1) ~/ size,
        'items': [
          for (var i = (page - 1) * size; i < page * size && i < total; i++)
            {
              'id': 'p-$i',
              'sourceDocNo': 'PI-$i',
              'openItemKind': 'PAYABLE',
              'status': 'OPEN',
              'outstandingOriginal': '100.0001',
            },
        ],
      };
    }
    return detail;
  }
}
