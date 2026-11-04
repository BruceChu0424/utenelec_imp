import 'finance_requirement_test_ui.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/widgets/finance_auxiliary_import_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';

void main() {
  testWidgets('lost directory reply retries the original durable batch', (
    tester,
  ) async {
    final api = _ImportApi()..loseApply = true;
    await _pump(tester, api);
    await tester.enterText(financeTextField('来源账套'), '原账套');
    await tapFinanceAction(tester, '选择原明细文件');
    await tester.pumpAndSettle();
    await tapFinanceAction(tester, '导入辅助目录草稿');
    await tester.pumpAndSettle();
    expect(api.applyIds, ['batch-1']);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '关闭'))
          .onPressed,
      isNull,
    );
    await tapFinanceAction(tester, '核对并重试原批次');
    await tester.pumpAndSettle();
    expect(api.applyIds, ['batch-1', 'batch-1']);
    expect(api.actualDirectories, 1);
    expect(api.uploads, 1);
    await tapFinanceAction(tester, '与总账本币比对');
    await tester.pumpAndSettle();
    expect(find.textContaining('缺少总账依据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unknown upload preserves source book and the exact bytes', (
    tester,
  ) async {
    final api = _ImportApi()..loseUpload = true;
    await _pump(tester, api);
    await tester.enterText(financeTextField('来源账套'), '000账套');
    await tapFinanceAction(tester, '选择原明细文件');
    await tester.pumpAndSettle();
    expect(tester.widget<UtenInput>(financeInput('来源账套')).enabled, isFalse);
    await tapFinanceAction(tester, '核对并重试原上传');
    await tester.pumpAndSettle();
    expect(api.uploads, 2);
    expect(api.paths.first, api.paths.last);
    expect(api.uploadedBytes.first, api.uploadedBytes.last);
    expect(find.text('00099'), findsOneWidget);
    expect(find.text('原客户'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'narrow enlarged text keeps source import and comparison actions reachable',
    (tester) async {
      final api = _ImportApi();
      await _pump(tester, api, width: 390, scale: 1.5);
      await tester.enterText(financeTextField('来源账套'), '原账套');
      await tapFinanceAction(tester, '选择原明细文件');
      await tester.pumpAndSettle();
      await tapFinanceAction(tester, '导入辅助目录草稿');
      expect(api.actualDirectories, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _ImportApi api, {
  double width = 1400,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeReportView,
          Perm.financeViewAll,
          Perm.paymentStyleEdit,
        }),
        financeEntryFilePickerProvider.overrideWithValue(
          () async => PlatformFile(
            name: 'anonymous.xlsx',
            size: 3,
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFinanceAuxiliaryImportDialog(
                context,
                receivable: true,
                currencyId: 'currency-1',
                dateFrom: '2026-09-01',
                dateTo: '2026-09-30',
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

class _ImportApi extends ApiClient {
  _ImportApi() : super(Dio());
  bool loseApply = false, loseUpload = false;
  int uploads = 0, actualDirectories = 0;
  final applyIds = <String>[], paths = <String>[];
  final uploadedBytes = <List<int>>[];
  final preview = <String, dynamic>{
    'importId': 'batch-1',
    'receivable': true,
    'currencyId': 'currency-1',
    'sha256': sha256.convert([1, 2, 3]).toString(),
    'sourceName': 'anonymous.xlsx',
    'sourceSystem': '原账套',
    'dateFrom': '2026-09-01',
    'dateTo': '2026-09-30',
    'rows': [
      {
        'sourceRow': 4,
        'accountCode': '112201',
        'accountName': '原科目',
        'partyCode': '00099',
        'partyName': '原客户',
        'openingDirection': '借',
        'openingDebit': '100',
        'openingCredit': '0',
        'openingBalance': '100',
        'debit': '20',
        'credit': '7',
        'closingDebit': '113',
        'closingCredit': '0',
        'closingDirection': '借',
        'closingBalance': '113',
      },
    ],
    'issues': <Object>[],
    'directoryApplied': false,
    'columns': [
      for (final definition in const [
        ['accountCode', '科目编码', 'text'],
        ['accountName', '科目名称', 'text'],
        ['partyCode', '客户编号', 'text'],
        ['partyName', '客户名称', 'text'],
        ['openingDirection', '方向', 'text'],
        ['openingDebit', '期初借方余额', 'money'],
        ['openingCredit', '期初贷方余额', 'money'],
        ['openingBalance', '期初余额金额', 'money'],
        ['debit', '本期借方金额', 'money'],
        ['credit', '本期贷方金额', 'money'],
        ['closingDebit', '期末借方余额', 'money'],
        ['closingCredit', '期末贷方余额', 'money'],
        ['closingDirection', '方向20', 'text'],
        ['closingBalance', '期末余额金额', 'money'],
      ])
        {
          'key': definition[0],
          'label': definition[1],
          'type': definition[2],
          'width': 150,
        },
    ],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/operations/')) {
      return {
        'requestId': path.split('/').last,
        'preview': {...preview, 'directoryApplied': actualDirectories > 0},
      };
    }
    if (path.endsWith('/batch-1')) {
      return {...preview, 'directoryApplied': actualDirectories > 0};
    }
    if (path.endsWith('/comparison')) {
      return {
        'items': [
          {
            'sourceRow': 4,
            'accountCode': '112201',
            'partyCode': '00099',
            'status': 'LEDGER_EVIDENCE_MISSING',
            'differences': ['缺少受审GL依据'],
          },
        ],
      };
    }
    return {'items': <Object>[]};
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
    uploads++;
    paths.add(path);
    uploadedBytes.add(List<int>.from(bytes));
    final query = Uri.parse(path).queryParameters;
    preview['sourceSystem'] = query['sourceSystem'];
    preview['sha256'] = sha256.convert(bytes).toString();
    if (loseUpload && uploads == 1) throw NetworkTimeoutException();
    return preview;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    applyIds.add((body as Map)['importId'].toString());
    actualDirectories = 1;
    if (loseApply && applyIds.length == 1) throw NetworkTimeoutException();
    return {'status': 'DIRECTORY_DRAFTS_APPLIED'};
  }
}
