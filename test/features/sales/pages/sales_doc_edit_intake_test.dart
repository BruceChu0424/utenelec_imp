// 报价/订货编辑页与「识别客户文件」的整合(ADR-134):
//  - 新建报价: 入口卡 → 识别 → 核对面板 → 套用补丁(客户/合同号/备注黄框、本位币、明细黄标)
//    → 保存请求体带 aiIntake / clientFileCurrency / 文件型号·品名·单价 / 学习字段, 折扣待财务留空提交 null;
//  - 原文件暂存进附件(客户确认);
//  - 已有订货草稿: 看不到价格时折扣不默认 1、提交 null; 报价核定的折扣只读; 文件字段往返不丢;
//    折扣或文件单价不同的同货品行不合并;
//  - 已审核订单不提供识别, 只给一句说明; 手工选货品带出英文名称;
//  - 导入后换了表头客户: 文件里的客户信息不补给别的客户; 追加时旧行不再回传识别行键;
//  - 同一份文件「替换」重新导入, 备注不重复; 明细里给识别行换货品按文件单价重算折扣;
//  - 重新打开的外币订单换货品: 不知道参考汇率, 折扣留空请销售核对。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_client_picker.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_launcher.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_repository.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/ai/ai_status_provider.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../intake/sales_intake_fixture.dart';
import '../intake/sales_intake_test_support.dart';

const _quotePerms = {
  Perm.salesQuoteView,
  Perm.salesQuoteCreate,
  Perm.salesQuoteEdit,
  Perm.salesOrderPriceView,
};

const _orderPerms = {
  Perm.salesOrderView,
  Perm.salesOrderCreate,
  Perm.salesOrderEdit,
  Perm.salesOrderPriceView,
  Perm.salesQuoteCreate,
};

class _Env {
  _Env(this.api, this.runner, this.repo);

  final _IntakeApi api;
  final FakeAiJobRunner runner;
  final FakeSalesIntakeRepository repo;
}

Future<_Env> _pump(
  WidgetTester tester, {
  required SalesDocType docType,
  String? id,
  Map<String, dynamic>? detail,
  Set<String> permissions = _quotePerms,
  AiStatus status = AiStatus.unavailable,
  List<GoodsListItem> pickedGoods = const [],
  Map<String, dynamic>? lastTerms,
  Map<String, dynamic>? intakeResult,
}) async {
  await tester.binding.setSurfaceSize(const Size(1800, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _IntakeApi(detail, lastTerms: lastTerms);
  final runner = FakeAiJobRunner(result: intakeResult ?? intakeResultJson());
  final repo = FakeSalesIntakeRepository();
  final presenter = FakeProgressPresenter();
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
        currentPermissionsProvider.overrideWithValue(permissions),
        aiJobRunnerProvider.overrideWithValue(runner),
        salesIntakeProgressPresenterProvider.overrideWithValue(
          presenterOf(presenter),
        ),
        aiStatusProvider.overrideWith((ref) async => status),
        salesIntakeRepositoryProvider.overrideWithValue(repo),
        salesGridGoodsPickerProvider.overrideWithValue(
          (_, _) async => pickedGoods,
        ),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) => SalesDocEditPage(docType: docType, id: id),
            ),
            GoRoute(
              path: '/:rest(.*)',
              builder: (_, _) => const SizedBox.shrink(),
            ),
          ],
        ),
        builder: (context, child) => Stack(
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
  return _Env(api, runner, repo);
}

/// 把假文件直接加进暂存附件区(与「添加文件」同一条校验链)。
Future<void> _addPendingFile(WidgetTester tester, String name) async {
  final controller = tester
      .widget<PendingAttachmentSection>(find.byType(PendingAttachmentSection))
      .controller;
  expect(controller.add(fakeFile(name)), isNull, reason: '文件应能加入暂存');
  await tester.pumpAndSettle();
}

/// 点某张暂存卡上的「AI识别」→ 核对面板 → 导入全部。
Future<void> _tapIntakeAction(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('pending-attachment-action-$name')));
  await tester.pumpAndSettle();
  expect(find.text('核对识别结果'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
  await tester.pumpAndSettle();
}

Future<void> _runIntake(
  WidgetTester tester, {
  String name = 'UJ23 quotation.xlsx',
}) async {
  await _addPendingFile(tester, name);
  await _tapIntakeAction(tester, name);
}

TextField _fieldLabelled(WidgetTester tester, String label) => tester
    .widgetList<TextField>(find.byType(TextField))
    .firstWhere((f) => f.decoration?.labelText == label);

Map<String, dynamic> _item(List<Map<String, dynamic>> items, String goodsId) =>
    items.singleWhere((i) => i['goodsId'] == goodsId);

Map<String, dynamic> _orderDetail({
  int status = 0,
  bool priceMasked = false,
  required List<Map<String, dynamic>> items,
}) => {
  'id': 'order-1',
  'status': status,
  'writable': true,
  'priceMasked': priceMasked,
  'clientId': 'client-1',
  'sellerId': 'seller-1',
  'currencyId': 'cny',
  'settlementMethodId': 'settlement-net30',
  'deliverDate': '2026-10-30',
  'shipmentPolicy': 'ALLOW_PARTIAL',
  'clientFileCurrency': 'USD',
  'items': items,
};

Map<String, dynamic> _draftSnapshot(WidgetTester tester) =>
    (tester.state(find.byType(SalesDocEditPage))
            as FormDraftMixin<SalesDocEditPage>)
        .captureFormDraft();

void main() {
  for (final masked in [false, true]) {
    testWidgets(
      'quote edit sends displayed revision and ${masked ? 'omits hidden prices' : 'keeps negotiated price and discount'}',
      (tester) async {
        final detail = {
          ..._orderDetail(
            priceMasked: masked,
            items: [
              {
                'id': 'it-1',
                'goodsId': 'goods-1',
                'unitId': 'unit-pcs',
                'unitRate': 1,
                'qty': 10,
                'price': masked ? null : 100,
                'discount': masked ? null : 0.95,
              },
            ],
          ),
          'id': 'quote-1',
          'validUntil': '2026-12-31',
          'reviewRevision': 17,
        };
        final env = await _pump(
          tester,
          docType: SalesDocType.quote,
          id: 'quote-1',
          detail: detail,
        );
        final row = tester
            .widget<UtenEditableGrid<SalesGridRow>>(
              find.byType(UtenEditableGrid<SalesGridRow>),
            )
            .controller
            .rows
            .first;
        // Simulate an old recovered price in memory after price access was revoked.
        row.price.text = '80.25';
        row.discount.text = '0.9';
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(env.api.lastPutBody?['expectedRevision'], 17);
        final item = (env.api.lastPutBody!['items'] as List).single as Map;
        expect(item['id'], 'it-1');
        expect(item['price'], masked ? null : '80.25');
        expect(item['discount'], masked ? null : '0.9');
        if (masked) expect(item.containsKey('price'), isFalse);
      },
    );
  }

  testWidgets(
    'batch stops after first extra-column failure without launching next file',
    (tester) async {
      final result = intakeResultJson();
      result['extraColumns'] = [
        {'key': 'packing', 'label': '包装说明', 'dataType': 'TEXT'},
      ];
      ((result['lines'] as List).first as Map<String, dynamic>)['extraValues'] =
          {'packing': 'Carton'};
      final env = await _pump(
        tester,
        docType: SalesDocType.quote,
        intakeResult: result,
      );
      env.api.failBusinessColumns = true;
      final grid = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller;
      final original = grid.rows.single..qty.text = '77';
      await _addPendingFile(tester, 'A quotation.xlsx');
      await _addPendingFile(tester, 'B quotation.xlsx');
      await tester.tap(find.byKey(const ValueKey('sales-intake-batch-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('sales-intake-batch-select-all')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('sales-intake-batch-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sales-intake-replace')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
      await tester.pumpAndSettle();
      expect(env.runner.requests, hasLength(1));
      expect(grid.rows.single, same(original));
      expect(original.qty.text, '77');
      expect(find.text('核对识别结果'), findsNothing);
      expect(find.textContaining('批量识别完成'), findsNothing);
      final section = tester.widget<PendingAttachmentSection>(
        find.byType(PendingAttachmentSection),
      );
      expect(
        section.controller.items.every(
          (item) => !section.actionFor!(item)!.done,
        ),
        isTrue,
      );
    },
  );

  for (final currencies in <(String?, String?)>[(null, 'USD'), ('USD', null)]) {
    testWidgets(
      'append rejects file-price currency mismatch ${currencies.$1} to ${currencies.$2}',
      (tester) async {
        final result = intakeResultJson();
        final currency = result['currency'] as Map<String, dynamic>;
        if (currencies.$1 == null) {
          currency.remove('fileCurrency');
        } else {
          currency['fileCurrency'] = currencies.$1!;
        }
        await _pump(tester, docType: SalesDocType.quote, intakeResult: result);
        await _runIntake(tester, name: 'A quotation.xlsx');
        final grid = tester
            .widget<UtenEditableGrid<SalesGridRow>>(
              find.byType(UtenEditableGrid<SalesGridRow>),
            )
            .controller;
        final originals = grid.rows;
        if (currencies.$2 == null) {
          currency.remove('fileCurrency');
        } else {
          currency['fileCurrency'] = currencies.$2!;
        }
        await _runIntake(tester, name: 'B quotation.xlsx');
        await tester.tap(find.byKey(const ValueKey('sales-intake-append')));
        await tester.pumpAndSettle();
        expect(grid.rows, orderedEquals(originals));
        expect(_draftSnapshot(tester)['clientFileCurrency'], currencies.$1);
        final section = tester.widget<PendingAttachmentSection>(
          find.byType(PendingAttachmentSection),
        );
        expect(
          section.actionFor!(section.controller.items.last)!.done,
          isFalse,
        );
      },
    );
  }

  testWidgets(
    'replacement with unknown currency clears previous file currency',
    (tester) async {
      final result = intakeResultJson();
      await _pump(tester, docType: SalesDocType.quote, intakeResult: result);
      await _runIntake(tester, name: 'A quotation.xlsx');
      expect(_draftSnapshot(tester)['clientFileCurrency'], 'USD');
      (result['currency'] as Map<String, dynamic>).remove('fileCurrency');
      await _runIntake(tester, name: 'B quotation.xlsx');
      await tester.tap(find.byKey(const ValueKey('sales-intake-replace')));
      await tester.pumpAndSettle();
      final draft = _draftSnapshot(tester);
      expect(draft['clientFileCurrency'], isNull);
      expect(
        (draft['aiIntake'] as Map<String, dynamic>)['clientFileCurrency'],
        isNull,
      );
      final section = tester.widget<PendingAttachmentSection>(
        find.byType(PendingAttachmentSection),
      );
      expect(section.actionFor!(section.controller.items.last)!.done, isTrue);
    },
  );

  testWidgets(
    'information-only append preserves existing price currency and rate',
    (tester) async {
      final result = intakeResultJson();
      await _pump(tester, docType: SalesDocType.quote, intakeResult: result);
      await _runIntake(tester, name: 'A quotation.xlsx');
      final currency = result['currency'] as Map<String, dynamic>;
      currency['fileCurrency'] = 'EUR';
      currency['financeRate'] = '9.5';
      currency['rateMissing'] = true;
      for (final line
          in (result['lines'] as List).cast<Map<String, dynamic>>()) {
        line.remove('customerUnitPrice');
      }
      await _runIntake(tester, name: 'B quotation.xlsx');
      await tester.tap(find.byKey(const ValueKey('sales-intake-append')));
      await tester.pumpAndSettle();
      final draft = _draftSnapshot(tester);
      expect(draft['clientFileCurrency'], 'USD');
      final session = draft['aiIntake'] as Map<String, dynamic>;
      expect(session['clientFileCurrency'], 'USD');
      expect(session['financeRate'], '7.1');
      expect(session['rateMissing'], isFalse);
      final grid = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller;
      expect(grid.rows, hasLength(10));
      expect(grid.rows.skip(5).every((row) => row.clientPrice == null), isTrue);
      final section = tester.widget<PendingAttachmentSection>(
        find.byType(PendingAttachmentSection),
      );
      expect(section.actionFor!(section.controller.items.last)!.done, isTrue);
    },
  );

  testWidgets(
    'failed extra-column resolution preserves existing rows and leaves file unadopted',
    (tester) async {
      final result = intakeResultJson();
      result['extraColumns'] = [
        {
          'key': 'packing',
          'label': '包装说明',
          'dataType': 'TEXT',
          'suggestedOperation': 'NONE',
        },
      ];
      ((result['lines'] as List).first as Map<String, dynamic>)['extraValues'] =
          {'packing': 'Carton'};
      final env = await _pump(
        tester,
        docType: SalesDocType.quote,
        intakeResult: result,
      );
      env.api.failBusinessColumns = true;
      final grid = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller;
      final original = grid.rows.single..qty.text = '77';
      await _runIntake(tester);
      await tester.tap(find.byKey(const ValueKey('sales-intake-replace')));
      await tester.pumpAndSettle();
      expect(grid.rows.single, same(original));
      expect(original.qty.text, '77');
      final section = tester.widget<PendingAttachmentSection>(
        find.byType(PendingAttachmentSection),
      );
      expect(
        section.actionFor!(section.controller.items.single)!.done,
        isFalse,
      );
      expect(env.api.lastPostBody, isNull);
    },
  );

  testWidgets(
    'canceling replacement keeps user data and file available for recognition',
    (tester) async {
      await _pump(tester, docType: SalesDocType.quote);
      final grid = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller;
      final original = grid.rows.single..qty.text = '77';
      await _runIntake(tester);
      await tester.tap(
        find
            .descendant(of: find.byType(AlertDialog), matching: find.text('取消'))
            .last,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(grid.rows.single, same(original));
      expect(original.qty.text, '77');
      final section = tester.widget<PendingAttachmentSection>(
        find.byType(PendingAttachmentSection),
      );
      expect(
        section.actionFor!(section.controller.items.single)!.done,
        isFalse,
      );
    },
  );

  testWidgets('新建报价: 识别客户文件 → 表头/明细带入 → 保存请求体带识别与学习字段', (tester) async {
    final env = await _pump(tester, docType: SalesDocType.quote);
    // 2026-09-29 入口统一进附件卡片区: 顶部横幅与表头上方按钮都已退役。
    expect(find.byKey(const ValueKey('sales-intake-entry-card')), findsNothing);
    expect(
      find.byKey(const ValueKey('sales-intake-toolbar-button')),
      findsNothing,
    );
    expect(find.text('拖入或点击添加客户文件，加入后可在文件卡上 AI 识别'), findsOneWidget);
    // 没有附件上传权限也能加文件识别(manageWithoutUploadPerm 通道)。
    expect(
      find.byKey(const ValueKey('pending-attachment-add')),
      findsOneWidget,
    );

    await _runIntake(tester);
    expect(env.runner.lastRequest!.params['docType'], 'quote');

    // 表头: 合同号 = 客户单号(黄框), 备注 = 条款 + 没找到的行。
    expect(_fieldLabelled(tester, '合同号').controller!.text, 'UJ23');
    final remark = _fieldLabelled(tester, '备注').controller!.text;
    expect(remark, contains('EXW; T/T 30% deposit'));
    expect(remark, contains('以下 1 行没找到对应货品: XX-999 MYSTERY PART × 5'));
    // 卡片动作转「重新识别」(灰色安静态)；文件单价列带文件币种。
    expect(find.text('重新识别'), findsOneWidget);
    expect(find.text('文件单价(USD)'), findsOneWidget);

    // 只有需要核对的行货品格黄框; 自动对上的不再标。
    expect(
      find.byKey(const ValueKey('sales-goods-ai-review-g-gz23-gold')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sales-goods-ai-review-g-gz23-white')),
      findsNothing,
    );

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final body = env.api.lastPostBody!;
    expect(env.api.lastPostPath, '/sales/quotes');
    expect(body['clientId'], 'client-sunas');
    expect(body['contractNo'], 'UJ23');
    expect(body['currencyId'], 'cny');
    expect(body['clientFileCurrency'], 'USD');
    expect(body['aiIntake'], {
      'jobId': 'job-42',
      'clientFields': {'email': 'buyer@example.com'},
    });
    expect(body.containsKey('taxRate'), isFalse);
    final items = (body['items'] as List).cast<Map<String, dynamic>>();
    expect(items, hasLength(5));

    final matched = _item(items, 'g-gz23-white');
    expect(matched['qty'], '1800');
    expect(matched['price'], '21');
    expect(matched['discount'], '1');
    expect(matched['clientModel'], 'GZ23/D');
    expect(
      matched['clientGoodsName'],
      'DOUBLE 3 PIN UNIVERSAL SOCKET WITH SWITCH',
    );
    expect(matched['clientPrice'], '21');
    expect(matched['intakeLineKey'], 'job-42:S1R9');
    expect(matched['userConfirmed'], isFalse);
    expect(matched['setNameEn'], isTrue);
    expect(matched.containsKey('amountOriginal'), isFalse);

    // 报价: 没标价的货品照常保存, 折扣留空 = 交财务核价(提交 null), 单价只是标价预览。
    final unpriced = _item(items, 'g-plate');
    expect(unpriced.containsKey('discount'), isTrue);
    expect(unpriced['discount'], isNull);
    expect(unpriced['price'], '0');
    expect(unpriced['intakeLineKey'], 'job-42:S1R12');

    final carton = _item(items, 'g-gk12');
    expect(carton['qty'], '600');
    expect(tester.takeException(), isNull);
  });

  testWidgets('原文件存进暂存附件(客户确认), 不重复加入', (tester) async {
    await _pump(
      tester,
      docType: SalesDocType.quote,
      permissions: {..._quotePerms, Perm.attachmentUpload},
    );
    await _runIntake(tester);
    final controller = tester
        .widget<BusinessAttachmentSection>(
          find.byType(BusinessAttachmentSection),
        )
        .draftController!;
    expect(controller.items.single.name, 'UJ23 quotation.xlsx');
    expect(controller.items.single.category, '客户确认');

    // 同一个文件再识别一次(已完成卡片仍可点): 明细已有内容 → 问替换/追加; 不重复加文件。
    await _tapIntakeAction(tester, 'UJ23 quotation.xlsx');
    expect(find.text('明细里已经有货品'), findsOneWidget);
    // 同一份文件重新识别: 弹窗点名覆盖「它之前识别出的结果」。
    expect(find.textContaining('之前识别的结果已在明细里'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-intake-replace')));
    await tester.pumpAndSettle();
    expect(controller.items, hasLength(1));
  });

  testWidgets('订货草稿看不到价格: 折扣不默认 1, 提交 null; 文件字段与客户编号往返', (tester) async {
    final env = await _pump(
      tester,
      docType: SalesDocType.order,
      id: 'order-1',
      permissions: _orderPerms,
      detail: _orderDetail(
        priceMasked: true,
        items: [
          {
            'id': 'it-1',
            'goodsId': 'goods-1',
            'unitId': 'unit-pcs',
            'unitRate': 1,
            'qty': 10,
            'clientModel': 'GZ23/D',
            'clientGoodsName': 'SOCKET',
            'clientPrice': 21,
            'clientNo': 'C-9',
          },
        ],
      ),
    );
    final row = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller
        .rows
        .first;
    expect(row.discount.text, isEmpty);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final item = (env.api.lastPutBody!['items'] as List).single as Map;
    expect(item['id'], 'it-1');
    expect(item.containsKey('discount'), isTrue);
    expect(item['discount'], isNull);
    expect(item.containsKey('price'), isFalse);
    expect(item['clientModel'], 'GZ23/D');
    expect(item['clientGoodsName'], 'SOCKET');
    expect(item['clientPrice'], '21');
    expect(item['clientNo'], 'C-9');
    expect(env.api.lastPutBody!['clientFileCurrency'], 'USD');
    expect(env.api.lastPutBody!.containsKey('aiIntake'), isFalse);
  });

  testWidgets('报价转入的订货行折扣只读(报价核定); 折扣不同的同货品行分开保留', (tester) async {
    final env = await _pump(
      tester,
      docType: SalesDocType.order,
      id: 'order-1',
      permissions: _orderPerms,
      detail: _orderDetail(
        items: [
          {
            'id': 'it-1',
            'goodsId': 'goods-1',
            'unitId': 'unit-pcs',
            'unitRate': 1,
            'qty': 10,
            'price': 20,
            'discount': 0.85,
            'quotePrice': 20,
            'quoteDiscount': 0.85,
          },
          {
            'id': 'it-2',
            'goodsId': 'goods-1',
            'unitId': 'unit-pcs',
            'unitRate': 1,
            'qty': 5,
            'price': 20,
            'discount': 0.9,
          },
        ],
      ),
    );
    expect(find.text('(报价核定)'), findsOneWidget);
    final locked = tester
        .widgetList<TextField>(find.byType(TextField))
        .where((f) => f.controller?.text == '0.85')
        .single;
    expect(locked.readOnly, isTrue);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    // 折扣不同 → 不算重复, 不弹合并, 两行都提交。
    expect(find.text('发现重复货品'), findsNothing);
    final items = (env.api.lastPutBody!['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items.map((i) => i['discount']), ['0.85', '0.9']);
  });

  testWidgets('报价核定的行重新选同一个货品: 单价折扣与锁定都不变; 换别的货品才解锁并提示', (tester) async {
    final picked = <GoodsListItem>[
      const GoodsListItem(
        id: 'goods-1',
        code: 'G-1',
        name: '报价货品',
        price: 25,
        unitId: 'unit-pcs',
      ),
    ];
    await _pump(
      tester,
      docType: SalesDocType.order,
      id: 'order-1',
      permissions: _orderPerms,
      pickedGoods: picked,
      detail: _orderDetail(
        items: [
          {
            'id': 'it-1',
            'goodsId': 'goods-1',
            'goodsNameSnapshot': '报价货品',
            'unitId': 'unit-pcs',
            'unitRate': 1,
            'qty': 10,
            'price': 20,
            'discount': 0.85,
            'quotePrice': 20,
            'quoteDiscount': 0.85,
          },
        ],
      ),
    );
    final grid = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller;
    final row = grid.rows.first;
    expect(row.quoteDiscountLocked, isTrue);
    // 测试里货品字典是空的: 给这一行一个可点的名称(同一个货品 id)。
    row.goods = const GoodsOption(id: 'goods-1', code: 'G-1', name: '报价货品');
    await tester.pumpAndSettle();
    await tester.tap(find.text('报价货品').first);
    await tester.pumpAndSettle();
    expect(row.price.text, '20', reason: '不被当前标价 25 覆盖');
    expect(row.discount.text, '0.85');
    expect(row.quoteDiscountLocked, isTrue);

    picked
      ..clear()
      ..add(
        const GoodsListItem(
          id: 'goods-9',
          code: 'G-9',
          name: '别的货品',
          price: 30,
          unitId: 'unit-pcs',
        ),
      );
    await tester.tap(find.text('报价货品').first);
    await tester.pumpAndSettle();
    expect(row.goods?.id, 'goods-9');
    expect(row.quoteDiscountLocked, isFalse);
    expect(find.textContaining('不再按报价的单价和折扣'), findsOneWidget);
  });

  testWidgets('已审核订单不提供识别, 只给一句说明', (tester) async {
    await _pump(
      tester,
      docType: SalesDocType.order,
      id: 'order-1',
      permissions: _orderPerms,
      detail: _orderDetail(
        status: 1,
        items: [
          {
            'id': 'it-1',
            'goodsId': 'goods-1',
            'unitId': 'unit-pcs',
            'unitRate': 1,
            'qty': 10,
            'price': 20,
            'discount': 1,
          },
        ],
      ),
    );
    expect(find.byKey(const ValueKey('sales-intake-entry-card')), findsNothing);
    expect(
      find.byKey(const ValueKey('sales-intake-toolbar-button')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('sales-intake-approved-order-hint')),
      findsOneWidget,
    );
  });

  testWidgets('新建报价选客户: 不按客户上次订货的外币预填币种, 币种只能选本位币', (tester) async {
    final env = await _pump(
      tester,
      docType: SalesDocType.quote,
      lastTerms: {'currencyId': 'usd', 'settlementMethodId': null},
    );
    tester
        .widget<ClientPickerField>(find.byType(ClientPickerField))
        .onChanged('client-b');
    await tester.pumpAndSettle();
    final currency = tester.widget<UtenDropdownField>(
      find.byWidgetPredicate((w) => w is UtenDropdownField && w.label == '币种'),
    );
    expect(currency.value, isNull, reason: '报价不带客户上次订货的外币');
    expect(
      currency.items.where((i) => i.value != null).map((i) => i.value),
      ['cny'],
      reason: '报价按标价(本位币)计价, 下拉只列本位币',
    );
    expect(currency.onAddNew, isNull, reason: '报价不内联新增币种');
    expect(env.api.lastPostBody, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建订货选客户: 仍按客户上次订货的币种预填', (tester) async {
    await _pump(
      tester,
      docType: SalesDocType.order,
      permissions: _orderPerms,
      lastTerms: {'currencyId': 'usd', 'settlementMethodId': null},
    );
    tester
        .widget<ClientPickerField>(find.byType(ClientPickerField))
        .onChanged('client-b');
    await tester.pumpAndSettle();
    final currency = tester.widget<UtenDropdownField>(
      find.byWidgetPredicate((w) => w is UtenDropdownField && w.label == '币种'),
    );
    expect(currency.value, 'usd');
    expect(
      currency.items.where((i) => i.value != null).map((i) => i.value),
      containsAll(['cny', 'usd']),
    );
  });

  testWidgets('导入后换了表头客户: 保存不把文件里的客户信息补给新客户', (tester) async {
    final env = await _pump(tester, docType: SalesDocType.quote);
    await _runIntake(tester);
    tester
        .widget<ClientPickerField>(find.byType(ClientPickerField))
        .onChanged('client-b');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final body = env.api.lastPostBody!;
    expect(body['clientId'], 'client-b');
    expect(body['aiIntake'], {
      'jobId': 'job-42',
      'clientFields': <String, String>{},
    });
  });

  testWidgets('批量识别: 进选卡模式勾选卡片, 第二份起自动追加不再问', (tester) async {
    await _pump(tester, docType: SalesDocType.quote);
    await _addPendingFile(tester, 'A quotation.xlsx');
    await _addPendingFile(tester, 'B quotation.xlsx');
    expect(
      find.byKey(const ValueKey('sales-intake-batch-button')),
      findsOneWidget,
    );
    // 点「批量识别」进选卡模式: 卡片动作/删除让位给勾选圈, 出现 取消/全选/识别(N)。
    await tester.tap(find.byKey(const ValueKey('sales-intake-batch-button')));
    await tester.pumpAndSettle();
    expect(find.text('AI识别'), findsNothing, reason: '选卡模式不显示单卡动作');
    expect(
      find.byKey(const ValueKey('sales-intake-batch-confirm')),
      findsOneWidget,
    );
    // 勾选两张卡(点卡片本体切换), 确认识别。
    await tester.tap(find.text('A quotation.xlsx'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B quotation.xlsx'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-batch-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('核对识别结果'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    // 第二份自动追加: 不再弹「明细里已经有货品」, 直接进核对面板。
    expect(find.text('明细里已经有货品'), findsNothing);
    expect(find.text('核对识别结果'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    final rows = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller
        .rows;
    expect(rows, hasLength(10), reason: '两份各 5 行, 追加不替换');
    expect(find.text('重新识别'), findsNWidgets(2), reason: '两张卡片都转重新识别');
    // 批量完成退出选卡模式; 队列不再满 2 份, 入口按钮收起。
    expect(
      find.byKey(const ValueKey('sales-intake-batch-confirm')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('sales-intake-batch-button')),
      findsNothing,
    );
  });

  testWidgets('批量识别: 只识别勾选的那张卡, 其余不动', (tester) async {
    await _pump(tester, docType: SalesDocType.quote);
    await _addPendingFile(tester, 'A quotation.xlsx');
    await _addPendingFile(tester, 'B quotation.xlsx');
    await tester.tap(find.byKey(const ValueKey('sales-intake-batch-button')));
    await tester.pumpAndSettle();
    // 没勾选时确认按钮置灰。
    final confirm = find.byKey(const ValueKey('sales-intake-batch-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.tap(find.text('A quotation.xlsx'));
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    final rows = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller
        .rows;
    expect(rows, hasLength(5), reason: '只识别了勾选的那一份');
    expect(find.text('重新识别'), findsOneWidget);
    expect(find.text('AI识别'), findsOneWidget, reason: '未勾选的卡仍待识别');
  });

  testWidgets('批量识别: 明细已有内容先统一问一次, 选追加后每份都追加', (tester) async {
    await _pump(tester, docType: SalesDocType.quote);
    await _runIntake(tester);
    await _addPendingFile(tester, 'B quotation.xlsx');
    await _addPendingFile(tester, 'C quotation.xlsx');
    await tester.tap(find.byKey(const ValueKey('sales-intake-batch-button')));
    await tester.pumpAndSettle();
    // 全选(含已完成的 UJ23 也可以重新识别, 这里全选)后确认。
    await tester.tap(
      find.byKey(const ValueKey('sales-intake-batch-select-all')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-batch-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('明细里已经有货品'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-intake-append')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    // 选了追加之后第二份不再问, 直接进核对面板。
    expect(find.text('明细里已经有货品'), findsNothing);
    expect(find.text('核对识别结果'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    final rows = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller
        .rows;
    expect(rows, hasLength(20), reason: '已有 5 行 + 三份(全选)各 5 行追加');
  });

  testWidgets('追加保留旧行识别来源和学习选择; 备注里已有的条款不重复', (tester) async {
    await _pump(tester, docType: SalesDocType.quote);
    await _runIntake(tester);
    await _tapIntakeAction(tester, 'UJ23 quotation.xlsx');
    await tester.tap(find.byKey(const ValueKey('sales-intake-append')));
    await tester.pumpAndSettle();
    final rows = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller
        .rows;
    expect(rows, hasLength(10));
    expect(
      rows.take(5).map((r) => r.intakeLineKey),
      rows.skip(5).map((r) => r.intakeLineKey),
    );
    expect(rows.first.setNameEn, isTrue);
    expect(rows.skip(5).map((r) => r.intakeLineKey), [
      'job-42:S1R9',
      'job-42:S1R10',
      'job-42:S1R12',
      'job-42:S1R13',
      'job-42:S1R14',
    ]);
    final remark = _fieldLabelled(tester, '备注').controller!.text;
    expect('EXW; T/T'.allMatches(remark), hasLength(1));
    expect('没找到对应货品'.allMatches(remark), hasLength(1));
  });

  testWidgets('替换重新导入: 上一次识别带进备注的那段换掉, 不重复; 手写的备注保留', (tester) async {
    await _pump(tester, docType: SalesDocType.quote);
    await _runIntake(tester);
    final remarkField = _fieldLabelled(tester, '备注').controller!;
    remarkField.text = '客户要求加急\n${remarkField.text}';
    await tester.pumpAndSettle();
    await _tapIntakeAction(tester, 'UJ23 quotation.xlsx');
    await tester.tap(find.byKey(const ValueKey('sales-intake-replace')));
    await tester.pumpAndSettle();
    final remark = _fieldLabelled(tester, '备注').controller!.text;
    expect(remark, startsWith('客户要求加急'));
    expect('EXW; T/T'.allMatches(remark), hasLength(1));
    expect('没找到对应货品'.allMatches(remark), hasLength(1));
  });

  testWidgets('识别行在明细里换货品: 按文件单价重算折扣, 文件品名保留; 空行选货品只在基础英文列显示名称', (
    tester,
  ) async {
    await _pump(
      tester,
      docType: SalesDocType.quote,
      pickedGoods: const [
        GoodsListItem(
          id: 'goods-2',
          code: 'G-2',
          name: '一开开关',
          price: 21,
          unitId: 'unit-pcs',
          nameEn: 'ONE GANG SWITCH',
        ),
      ],
    );
    await _runIntake(tester);
    final grid = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller;
    final row = grid.rows.singleWhere((r) => r.intakeLineKey == 'job-42:S1R10');
    expect(row.clientPrice, '19.95');
    await tester.tap(
      find.byKey(const ValueKey('sales-goods-ai-review-g-gz23-gold')),
    );
    await tester.pumpAndSettle();
    expect(row.goods?.id, 'goods-2');
    expect(row.price.text, '21');
    // 19.95 / 21 = 0.95 (按 1 折算落在区间, 按参考汇率 7.1 不在区间)。
    expect(row.discount.text, '0.95');
    expect(row.userConfirmed, isTrue);
    expect(row.aiReview, isNull);
    // 客户文件里的品名是客户自己的叫法, 换货品不覆盖。
    expect(row.clientGoodsName.text, 'DOUBLE 3 PIN SOCKET GOLD');

    // 空行手工选货品: 英文只在独立列，文件原文保持空。
    final blank = SalesGridRow(amountUsesDiscount: true);
    grid.addRow(blank);
    await tester.pumpAndSettle();
    await tester.tap(find.text('点击选择').last);
    await tester.pumpAndSettle();
    expect(blank.goods?.id, 'goods-2');
    expect(blank.clientGoodsName.text, isEmpty);
    expect(blank.goods!.nameEn, 'ONE GANG SWITCH');
    expect(blank.discount.text, '1');
  });

  testWidgets('手工选货品仅显示基础十列，主档英文不写入客户文件品名', (tester) async {
    final env = await _pump(
      tester,
      docType: SalesDocType.quote,
      pickedGoods: const [
        GoodsListItem(
          id: 'goods-2',
          code: 'G-2',
          name: '一开开关',
          price: 21,
          unitId: 'unit-pcs',
          nameEn: 'ONE GANG SWITCH',
        ),
        GoodsListItem(
          id: 'goods-3',
          code: 'G-3',
          name: '两开开关',
          price: 25,
          unitId: 'unit-pcs',
          nameEn: 'TWO GANG SWITCH',
        ),
      ],
    );
    tester
        .widget<ClientPickerField>(find.byType(ClientPickerField))
        .onChanged('client-b');
    await tester.pumpAndSettle();
    final grid = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller;
    await tester.tap(find.text('点击选择').first);
    await tester.pumpAndSettle();
    final auto = grid.rows.firstWhere((r) => r.goods?.id == 'goods-2');
    final typed = grid.rows.firstWhere((r) => r.goods?.id == 'goods-3');
    expect(auto.clientGoodsName.text, isEmpty);
    expect(typed.clientGoodsName.text, isEmpty);
    expect(auto.goods!.nameEn, 'ONE GANG SWITCH');
    expect(typed.goods!.nameEn, 'TWO GANG SWITCH');
    expect(find.text('文件品名'), findsNothing);
    expect(find.text('文件型号'), findsNothing);
    final table = tester.widget<UtenEditableGrid<SalesGridRow>>(
      find.byType(UtenEditableGrid<SalesGridRow>),
    );
    expect(table.columns.where((c) => c.defaultVisible).map((c) => c.key), [
      'goods',
      'nameEn',
      'goodsCode',
      'color',
      'qty',
      'unit',
      'price',
      'discount',
      'amount',
      'remark',
    ]);
    // 第二行改成客户自己的叫法。
    typed.clientGoodsName.text = 'SWITCH 2G';
    auto.qty.text = '5';
    typed.qty.text = '6';
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final items = (env.api.lastPostBody!['items'] as List)
        .cast<Map<String, dynamic>>();
    final autoSaved = _item(items, 'goods-2');
    expect(autoSaved['clientGoodsName'], isNull);
    expect(autoSaved.containsKey('userConfirmed'), isFalse);
    expect(autoSaved.containsKey('setNameEn'), isFalse);
    final typedSaved = _item(items, 'goods-3');
    expect(typedSaved['clientGoodsName'], 'SWITCH 2G');
    expect(typedSaved['userConfirmed'], isTrue);
  });

  testWidgets('重新打开的外币订单换货品: 不知道参考汇率, 折扣留空并黄标', (tester) async {
    await _pump(
      tester,
      docType: SalesDocType.order,
      id: 'order-1',
      permissions: _orderPerms,
      pickedGoods: const [
        GoodsListItem(id: 'goods-2', code: 'G-2', name: '一开开关', price: 3),
      ],
      detail: _orderDetail(
        items: [
          {
            'id': 'it-1',
            'goodsId': 'goods-1',
            'unitId': 'unit-pcs',
            'unitRate': 1,
            'qty': 10,
            'price': 20,
            'discount': 1,
            'clientPrice': 2.8,
          },
        ],
      ),
    );
    final row = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller
        .rows
        .single;
    await tester.tap(find.byIcon(Icons.search_rounded).first);
    await tester.pumpAndSettle();
    expect(row.goods?.id, 'goods-2');
    // 按 1 折算 2.8/3 本可得到 0.9333, 但文件是美元而汇率未知: 不猜。
    expect(row.discount.text, isEmpty);
    expect(row.aiReview, '折扣没能自动算出, 请按文件单价核对后填写');
  });

  testWidgets('没有新建权限不显示入口', (tester) async {
    await _pump(
      tester,
      docType: SalesDocType.quote,
      permissions: {Perm.salesQuoteView},
    );
    expect(find.byKey(const ValueKey('sales-intake-entry-card')), findsNothing);
  });
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _IntakeApi extends ApiClient {
  _IntakeApi(this.detail, {this.lastTerms}) : super(Dio());

  final Map<String, dynamic>? detail;

  /// 客户上次订货条款(`/sales/orders/last-terms`); 为空时按空分页返回。
  final Map<String, dynamic>? lastTerms;
  Map<String, dynamic>? lastPutBody;
  Map<String, dynamic>? lastPostBody;
  String? lastPostPath;
  bool failBusinessColumns = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final d = detail;
    if (d != null && path.endsWith('/${d['id']}')) return d;
    final terms = lastTerms;
    if (terms != null && path.endsWith('/last-terms')) return terms;
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('currencies')) {
      return [
        {'id': 'cny', 'name': '人民币', 'baseCurrency': true},
        {'id': 'usd', 'name': '美元', 'baseCurrency': false},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/business-columns' && failBusinessColumns) {
      throw StateError('column catalog unavailable');
    }
    // 只记录单据本身的写入; 保存后暂存附件的 presign/confirm 不算(否则断言被冲掉)。
    if (path.startsWith('/sales/')) {
      lastPostPath = path;
      lastPostBody = Map<String, dynamic>.from(body! as Map);
    }
    return {'id': 'quote-1', 'status': 0, 'writable': true};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail!;
  }
}
