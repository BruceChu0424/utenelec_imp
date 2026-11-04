import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/features/finance/widgets/finance_procurement_confirmation_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'finance_requirement_test_ui.dart';

void main() {
  testWidgets(
    'confirmation unknown upload keeps the exact original bytes and request until its real result is known',
    (tester) async {
      final api = _Api()..loseFirst = true;
      await _pump(tester, api);
      await tester.tap(find.text('RC-001').first);
      await tester.pumpAndSettle();
      await tapFinanceAction(tester, '提交对账确认');
      await tester.enterText(financeTextField('对方确认人'), '匿名实际确认人');
      await tester.enterText(financeTextField('来源依据'), '原件逐来源核对');
      await tester.tap(find.text('选择原确认件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交对账确认').last);
      await tester.pumpAndSettle();
      expect(api.uploads, hasLength(1));
      expect(
        tester.widget<TextField>(financeTextField('来源依据')).enabled,
        isFalse,
      );
      await tester.tap(find.text('核对并重试原请求'));
      await tester.pumpAndSettle();
      expect(api.uploads, hasLength(2));
      expect(api.uploads.first, api.uploads.last);
      expect((api.uploads.first['command'] as Map)['candidates'], [
        {
          'candidateId': 'candidate-1',
          'sourceFingerprint': 'original-fingerprint',
        },
      ]);
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow enlarged existing table keeps source selection and all input controls usable',
    (tester) async {
      final api = _Api();
      await _pump(tester, api, width: 390, scale: 1.5);
      await tester.tap(find.text('RC-001').first);
      await tester.pumpAndSettle();
      await tapFinanceAction(tester, '提交对账确认');
      await tester.ensureVisible(financeTextField('来源依据'));
      await tester.enterText(financeTextField('来源依据'), '原件尚待补齐');
      await tester.tap(find.text('提交对账确认').last);
      await tester.pumpAndSettle();
      expect(api.uploads, isEmpty);
      expect(
        tester.widget<TextField>(financeTextField('来源依据')).controller!.text,
        '原件尚待补齐',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'capture actual confirmation controls with anonymous source rows',
    (tester) async {
      if (Platform.environment['FINANCE_CAPTURE_SCREENSHOTS'] != 'true') return;
      final font = FontLoader('NotoSansSC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'));
      await font.load();
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
      final boundary = GlobalKey();
      await _pump(tester, _Api(), boundary: boundary);
      await _capture(tester, boundary, '首次应付对账确认-实际组件');
      await tester.tap(find.text('RC-001').first);
      await tester.pumpAndSettle();
      await tapFinanceAction(tester, '提交对账确认');
      await tester.enterText(financeTextField('对方确认人'), '匿名对方确认人');
      await tester.enterText(financeTextField('来源依据'), '按原对账确认件逐来源核对');
      await tester.tap(find.text('选择原确认件'));
      await tester.pumpAndSettle();
      await _capture(tester, boundary, '首次应付原确认件-实际组件');
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Api api, {
  double width = 1250,
  double scale = 1,
  GlobalKey? boundary,
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
          Perm.financePostExecute,
        }),
        financeConfirmationFilePickerProvider.overrideWithValue(
          () async => PlatformFile(
            name: 'actual-original.png',
            size: 4,
            bytes: Uint8List.fromList([1, 2, 3, 4]),
          ),
        ),
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
                onPressed: () => showFinanceProcurementConfirmationDialog(
                  context,
                  supplierId: 'supplier-1',
                  currencyId: 'currency-1',
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

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool loseFirst = false;
  int actual = 0;
  final uploads = <Map<String, Object?>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/candidates')) {
      return {
        'items': [
          {
            'id': 'candidate-1',
            'billNo': 'RC-001',
            'commercialDate': '2026-11-03',
            'accrualDate': '2026-11-03',
            'supplierName': '匿名供应商',
            'currencyName': '原币',
            'amountOriginal': '80.00000000000000000001',
            'amountLocal': '560.00000000000000000007',
            'sourceFingerprint': 'original-fingerprint',
          },
        ],
        'totalPages': 1,
      };
    }
    if (path == '/finance/procurement-payable-recognitions') {
      return {
        'items': [
          {
            'id': 'review-1',
            'effectiveDate': '2026-11-03',
            'status': 'DRAFT',
            'sourceReference': '原件逐来源核对',
            'fileName': 'actual-original.png',
          },
        ],
        'totalPages': 1,
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> postMultipartFile(
    String path,
    Uint8List bytes,
    String filename,
    String contentType, {
    Duration? receiveTimeout,
    Map<String, Object?> jsonParts = const {},
    Map<String, dynamic>? headers,
  }) async {
    uploads.add({
      'path': path,
      'bytes': bytes.toList(),
      'filename': filename,
      'type': contentType,
      ...jsonParts,
    });
    if (actual == 0) actual++;
    if (loseFirst && uploads.length == 1) throw NetworkTimeoutException();
    return {'id': 'review-1', 'status': 'DRAFT'};
  }
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/finance-party/screenshots/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
