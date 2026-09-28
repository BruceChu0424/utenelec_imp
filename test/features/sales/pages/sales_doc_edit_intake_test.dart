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
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
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
import 'package:uten_imp/shared/ai/ai_status_provider.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
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
}) async {
  await tester.binding.setSurfaceSize(const Size(1800, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _IntakeApi(detail);
  final runner = FakeAiJobRunner(result: intakeResultJson());
  final repo = FakeSalesIntakeRepository(
    nameEn: {'goods-2': 'ONE GANG SWITCH'},
  );
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

Future<void> _runIntake(WidgetTester tester) async {
  FilePicker.platform = FakeFilePicker(fakeFile('UJ23 quotation.xlsx'));
  await tester.tap(find.byKey(const ValueKey('sales-intake-entry-button')));
  await tester.pumpAndSettle();
  expect(find.text('核对识别结果'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
  await tester.pumpAndSettle();
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

void main() {
  testWidgets('新建报价: 识别客户文件 → 表头/明细带入 → 保存请求体带识别与学习字段', (tester) async {
    final env = await _pump(tester, docType: SalesDocType.quote);
    expect(
      find.byKey(const ValueKey('sales-intake-entry-card')),
      findsOneWidget,
    );
    // AI 没开: 只加一句提示(Excel 仍可识别)。
    expect(
      find.byKey(const ValueKey('sales-intake-ai-off-hint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sales-intake-toolbar-button')),
      findsOneWidget,
    );

    await _runIntake(tester);
    expect(env.runner.lastRequest!.params['docType'], 'quote');

    // 表头: 合同号 = 客户单号(黄框), 备注 = 条款 + 没找到的行。
    expect(_fieldLabelled(tester, '合同号').controller!.text, 'UJ23');
    final remark = _fieldLabelled(tester, '备注').controller!.text;
    expect(remark, contains('EXW; T/T 30% deposit'));
    expect(remark, contains('以下 1 行没找到对应货品: XX-999 MYSTERY PART × 5'));
    expect(find.text('已从 UJ23 quotation.xlsx 导入 5 行'), findsOneWidget);
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
    expect(matched['intakeLineKey'], 'S1R9');
    expect(matched['userConfirmed'], isFalse);
    expect(matched['setNameEn'], isTrue);
    expect(matched.containsKey('amountOriginal'), isFalse);

    // 报价: 没标价的货品照常保存, 折扣留空 = 交财务核价(提交 null), 单价只是标价预览。
    final unpriced = _item(items, 'g-plate');
    expect(unpriced.containsKey('discount'), isTrue);
    expect(unpriced['discount'], isNull);
    expect(unpriced['price'], '0');
    expect(unpriced['intakeLineKey'], 'S1R12');

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

    // 同一个文件再识别一次: 明细已有内容 → 问替换/追加; 附件不重复。
    FilePicker.platform = FakeFilePicker(fakeFile('UJ23 quotation.xlsx'));
    await tester.tap(find.byKey(const ValueKey('sales-intake-entry-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    expect(find.text('明细里已经有货品'), findsOneWidget);
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

  testWidgets('追加: 旧行不再回传识别行键/英文名勾选; 备注里已有的条款不重复', (tester) async {
    await _pump(tester, docType: SalesDocType.quote);
    await _runIntake(tester);
    FilePicker.platform = FakeFilePicker(fakeFile('UJ23 quotation.xlsx'));
    await tester.tap(find.byKey(const ValueKey('sales-intake-entry-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-append')));
    await tester.pumpAndSettle();
    final rows = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller
        .rows;
    expect(rows, hasLength(10));
    for (final old in rows.take(5)) {
      expect(old.intakeLineKey, isNull);
      expect(old.setNameEn, isFalse);
    }
    expect(rows.skip(5).map((r) => r.intakeLineKey), [
      'S1R9',
      'S1R10',
      'S1R12',
      'S1R13',
      'S1R14',
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
    FilePicker.platform = FakeFilePicker(fakeFile('UJ23 quotation.xlsx'));
    await tester.tap(find.byKey(const ValueKey('sales-intake-entry-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-replace')));
    await tester.pumpAndSettle();
    final remark = _fieldLabelled(tester, '备注').controller!.text;
    expect(remark, startsWith('客户要求加急'));
    expect('EXW; T/T'.allMatches(remark), hasLength(1));
    expect('没找到对应货品'.allMatches(remark), hasLength(1));
  });

  testWidgets('识别行在明细里换货品: 按文件单价重算折扣, 文件品名保留; 空行选货品带出英文名称', (tester) async {
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
        ),
      ],
    );
    await _runIntake(tester);
    final grid = tester
        .widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        )
        .controller;
    final row = grid.rows.singleWhere((r) => r.intakeLineKey == 'S1R10');
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

    // 空行手工选货品: 文件品名带出货品英文名称。
    final blank = SalesGridRow(amountUsesDiscount: true);
    grid.addRow(blank);
    await tester.pumpAndSettle();
    await tester.tap(find.text('点击选择').last);
    await tester.pumpAndSettle();
    expect(blank.goods?.id, 'goods-2');
    expect(blank.clientGoodsName.text, 'ONE GANG SWITCH');
    expect(blank.discount.text, '1');
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
  _IntakeApi(this.detail) : super(Dio());

  final Map<String, dynamic>? detail;
  Map<String, dynamic>? lastPutBody;
  Map<String, dynamic>? lastPostBody;
  String? lastPostPath;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final d = detail;
    if (d != null && path.endsWith('/${d['id']}')) return d;
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
        {'id': 'cny', 'name': '人民币'},
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
    lastPostPath = path;
    lastPostBody = Map<String, dynamic>.from(body! as Map);
    return {'id': 'quote-1', 'status': 0, 'writable': true};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail!;
  }
}
