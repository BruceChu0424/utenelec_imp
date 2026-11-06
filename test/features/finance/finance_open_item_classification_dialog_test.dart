import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'finance_requirement_test_ui.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/widgets/finance_open_item_classification_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'receipt keeps all five exact axes and retries the identical request',
    (tester) async {
      final api = _ClassificationApi()
        ..receipt = true
        ..loseFirst = true;
      await _pump(tester, api, receipt: true);
      expect(find.text('收款金额分配'), findsOneWidget);
      await tester.ensureVisible(
        find.widgetWithText(TextButton, '全部分配为物料金额').first,
      );
      await tester.tap(find.widgetWithText(TextButton, '全部分配为物料金额').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(financeTextField('来源依据'));
      await tester.enterText(financeTextField('来源依据'), '原收款五轴分别按已核原事实分配');
      await tester.tap(find.text('确认分配'));
      await tester.pumpAndSettle();
      expect(api.saves, hasLength(1));
      final part = (api.saves.single['parts'] as List).single as Map;
      expect(part, {
        'category': 'MATERIAL',
        'amountOriginal': '90071992547409.123456789012345678901234',
        'writeOffOriginal': '0.000000000000000000000001',
        'cashLocal': '630503947831863.864197523086419752308638',
        'writeOffLocal': '0.000000000000000000000007',
        'bookLocal': '630503947831863.864197523086419752308645',
      });
      expect(api.saves.single['sourceClassificationId'], 'source-class-1');
      await tester.tap(find.text('核对并重试原请求'));
      await tester.pumpAndSettle();
      expect(api.saves, hasLength(2));
      expect(api.saves.first, api.saves.last);
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unknown source classification retries one request with exact decimal strings',
    (tester) async {
      final api = _ClassificationApi()..loseFirst = true;
      await _pump(tester, api);
      await tester.ensureVisible(
        find.widgetWithText(TextButton, '全部分配为货款').first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '全部分配为货款').first);
      await tester.pumpAndSettle();
      await tester.enterText(financeTextField('来源依据'), '原应付来源及财务已核验分类');
      await tester.tap(find.text('确认分配'));
      await tester.pumpAndSettle();
      expect(api.saves, hasLength(1));
      expect(
        tester
            .widget<UtenDialogHeader>(
              find.widgetWithText(UtenDialogHeader, '往来项目分类'),
            )
            .onClose,
        isNull,
      );
      final closeButton = find.descendant(
        of: find.widgetWithText(UtenDialogHeader, '往来项目分类'),
        matching: find.byType(UtenCloseButton),
      );
      expect(closeButton, findsOneWidget);
      expect(tester.widget<UtenCloseButton>(closeButton).onPressed, isNull);
      expect(
        tester.widget<TextField>(financeTextField('来源依据')).enabled,
        isFalse,
      );
      await tester.tap(find.text('核对并重试原请求'));
      await tester.pumpAndSettle();
      expect(api.saves, hasLength(2));
      expect(api.saves.first, api.saves.last);
      expect(api.actual, 1);
      final parts = (api.saves.first['parts'] as List)
          .cast<Map<String, dynamic>>();
      expect(parts.single['amountOriginal'], '90071992547409.123456');
      expect(parts.single['amountLocal'], '630503947831863.864192');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'definite conservation rejection retains both assignment amounts and editable evidence',
    (tester) async {
      final api = _ClassificationApi()..reject = true;
      await _pump(tester, api);
      await tester.ensureVisible(
        find.widgetWithText(TextButton, '全部分配为货款').first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '全部分配为货款').first);
      await tester.pumpAndSettle();
      await tester.enterText(financeTextField('来源依据'), '原始依据');
      await tester.tap(find.text('确认分配'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(financeTextField('来源依据')).enabled,
        isTrue,
      );
      final hint = find.byWidgetPredicate(
        (w) =>
            w is UtenFieldHintIcon && (w.info?.contains('原币与本币须分别守恒') ?? false),
      );
      expect(hint, findsOneWidget);
      await tester.tap(hint);
      await tester.pumpAndSettle();
      expect(find.textContaining('原币与本币须分别守恒'), findsOneWidget);
      expect(api.actual, 0);
    },
  );
  testWidgets('narrow enlarged financial assignment fields remain reachable', (
    tester,
  ) async {
    final api = _ClassificationApi();
    await _pump(tester, api, width: 390, scale: 1.5);
    await tester.ensureVisible(
      find.widgetWithText(TextButton, '全部分配为货款').first,
    );
    await tester.ensureVisible(
      find.widgetWithText(TextButton, '全部分配为货款').first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '全部分配为货款').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(financeTextField('来源依据'));
    await tester.enterText(financeTextField('来源依据'), '原始依据');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'capture actual classification component with anonymous guide data',
    (tester) async {
      if (Platform.environment['FINANCE_CAPTURE_SCREENSHOTS'] != 'true') return;
      final noto = FontLoader('NotoSansSC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'));
      await noto.load();
      final iconsPath = Platform.environment['UTEN_MATERIAL_ICONS_FONT'];
      if (iconsPath != null) {
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            Future.value(
              ByteData.sublistView(File(iconsPath).readAsBytesSync()),
            ),
          );
        await icons.load();
      }
      final api = _ClassificationApi()..guide = true;
      final boundary = GlobalKey();
      await _pump(tester, api, boundary: boundary);
      await tester.ensureVisible(
        find.widgetWithText(TextButton, '全部分配为货款').first,
      );
      await tester.tap(find.widgetWithText(TextButton, '全部分配为货款').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        financeTextField('来源依据'),
        '匿名操作示例：按原单用途确认货款；原币与账面本币分别守恒。',
      );
      await tester.ensureVisible(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == '采购入库-演示001',
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final rendered =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final picture = await rendered.toImage();
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        final file = File('output/finance-party/screenshots/货款模具款分类-实际组件.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _ClassificationApi api, {
  double width = 1400,
  double scale = 1,
  GlobalKey? boundary,
  bool receipt = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.supplierSettlementConfirm,
          Perm.financePaymentApprove,
          Perm.financeReceiptApprove,
        }),
      ],
      child: RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: buildLightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => receipt
                    ? showFinanceReceiptClassificationDialog(
                        context,
                        receiptLineId: 'receipt-line-1',
                      )
                    : showFinanceOpenItemClassificationDialog(
                        context,
                        ledgerId: 'ledger-1',
                      ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

class _ClassificationApi extends ApiClient {
  _ClassificationApi() : super(Dio());
  bool loseFirst = false, reject = false, guide = false, receipt = false;
  int actual = 0;
  final saves = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => receipt
      ? {
          'receiptLineId': 'receipt-line-1',
          'ledgerId': 'ledger-1',
          'billNo': '匿名原收款001',
          'sourceClassificationId': 'source-class-1',
          'revision': -1,
          'sourceParts': [
            {'category': 'MATERIAL'},
          ],
          'parts': <Object>[],
          'amountOriginalExact': '90071992547409.123456789012345678901234',
          'writeOffOriginalExact': '0.000000000000000000000001',
          'cashLocalExact': '630503947831863.864197523086419752308638',
          'writeOffLocalExact': '0.000000000000000000000007',
          'bookLocalExact': '630503947831863.864197523086419752308645',
        }
      : {
          'ledgerId': 'ledger-1',
          'direction': 'AP',
          'billNo': '采购入库-演示001',
          'currencyId': 'currency-1',
          'currencyCode': 'USD',
          'currencyName': '美元',
          'sourceVerified': true,
          'effectiveFrom': '2026-09-05',
          'revision': -1,
          'amountOriginalExact': guide ? '100.0000' : '90071992547409.123456',
          'amountLocalExact': guide ? '700.0000' : '630503947831863.864192',
          'parts': <Object>[],
          'payments': <Object>[],
          'offsets': <Object>[],
        };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    saves.add(Map<String, dynamic>.from(body as Map));
    if (reject) {
      throw ApiException(
        'VALIDATION_FAILED',
        '原币与本币须分别守恒',
        httpStatus: 422,
        hasResponseCode: true,
      );
    }
    actual = 1;
    if (loseFirst && saves.length == 1) throw NetworkTimeoutException();
    return {'status': 'APPLIED', 'revision': 0};
  }
}
