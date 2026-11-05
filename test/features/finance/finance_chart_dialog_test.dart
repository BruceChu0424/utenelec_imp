import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/widgets/finance_chart_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

void main() {
  testWidgets(
    'creating an accounting target preserves both report choices when retrying a lost reply',
    (tester) async {
      final api = _ChartApi()
        ..actualImports = 1
        ..accountCode = '310410'
        ..accountName = '未分配利润'
        ..loseFirstTarget = true;
      await _pump(tester, api);
      await tester.tap(find.text('对应科目/报表'));
      await tester.pumpAndSettle();
      Future<void> choose(String label, String value) async {
        final field = find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == label,
        );
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text(value).last);
        await tester.pumpAndSettle();
      }

      await choose('补建核算类别', '权益');
      await choose('资产负债表项目', '未分配利润');
      await choose('利润表项目', '以前年度损益调整');
      expect(find.text('保存对应'), findsNothing);
      await tester.tap(find.text('补建并对应此科目'));
      await tester.pumpAndSettle();
      expect(api.targetRequests.single['balanceLineKey'], 'BS_51');
      expect(api.targetRequests.single['profitLineKey'], 'PL_PRIOR_ADJUSTMENT');
      await tester.tap(find.text('核对并重试原对应'));
      await tester.pumpAndSettle();
      expect(api.targetRequests, hasLength(2));
      expect(api.targetRequests.first, api.targetRequests.last);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rename preserves its original request after a lost reply and refreshes the directory',
    (tester) async {
      final api = _ChartApi()
        ..actualImports = 1
        ..loseFirstMetadata = true;
      await _pump(tester, api);
      await tester.tap(find.text('修改名称'));
      await tester.pumpAndSettle();
      Finder field(String label) => find.descendant(
        of: find.byWidgetPredicate((w) => w is UtenInput && w.label == label),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(field('科目名称'), '库存现金（人民币）');
      await tester.enterText(field('修改依据'), '财务核对名称，沿用原科目编码');
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();
      expect(api.metadataRequests, hasLength(1));
      expect(
        tester
            .widget<UtenInput>(
              find.byWidgetPredicate(
                (w) => w is UtenInput && w.label == '科目名称',
              ),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('重试原修改请求'));
      await tester.pumpAndSettle();
      expect(api.metadataRequests, hasLength(2));
      expect(api.metadataRequests[0], api.metadataRequests[1]);
      expect(api.metadataWrites, 1);
      expect(find.text('库存现金（人民币）'), findsOneWidget);
      expect(find.text('1001'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source reason preserves base currency and loss category can be selected by mouse',
    (tester) async {
      final api = _ChartApi();
      await _pump(tester, api, width: 1280, height: 720);
      await _tapTableAction(tester, '新增科目');
      Finder field(String label) => find.descendant(
        of: find.byWidgetPredicate((w) => w is UtenInput && w.label == label),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(field('科目编码'), '560301');
      await tester.enterText(field('科目名称'), '利息收入');
      await tester.enterText(field('新增依据'), '损益科目允许无余额；本期发生额保留用于利润计算。');
      await tester.pumpAndSettle();
      final currency = find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '核算币别',
      );
      expect(tester.widget<UtenDropdownField>(currency).value, 'currency-cny');
      final classification = find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '财务类别',
      );
      await tester.ensureVisible(classification);
      await tester.tap(classification);
      await tester.pumpAndSettle();
      await tester.tap(find.text('损益').last);
      await tester.pumpAndSettle();
      expect(tester.widget<UtenDropdownField>(classification).value, 'PROFIT');
      final category = find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '同时补建核算类别',
      );
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.pumpAndSettle();
      await tester.tap(find.text('收入').last);
      await tester.pumpAndSettle();
      expect(tester.widget<UtenDropdownField>(category).value, 'INCOME');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'lost apply reply retries only the original batch and closes no unknown work',
    (tester) async {
      final api = _ChartApi()..loseFirstApply = true;
      await _pump(tester, api);
      await _tapTableAction(tester, '导入科目目录');
      expect(find.textContaining('1条科目，0项错误'), findsOneWidget);
      await tester.tap(find.text('确认导入科目目录'));
      await tester.pumpAndSettle();
      expect(api.applies, ['batch-1']);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '关闭'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('核对并重试原批次'));
      await tester.pumpAndSettle();
      expect(api.applies, ['batch-1', 'batch-1']);
      expect(api.actualImports, 1);
      expect(api.uploads, 1);
      expect(find.text('1001'), findsOneWidget);
      expect(find.text('库存现金'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'definite validation rejection keeps the preview editable and does not trap the user',
    (tester) async {
      final api = _ChartApi()..rejectApply = true;
      await _pump(tester, api);
      await _tapTableAction(tester, '导入科目目录');
      await tester.tap(find.text('确认导入科目目录'));
      await tester.pumpAndSettle();
      expect(find.text('核对并重试原批次'), findsNothing);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '关闭'))
            .onPressed,
        isNotNull,
      );
      expect(find.textContaining('库存现金'), findsOneWidget);
      expect(api.actualImports, 0);
    },
  );

  testWidgets(
    'narrow enlarged text keeps financial directory controls and data reachable',
    (tester) async {
      final api = _ChartApi()..actualImports = 1;
      await _pump(tester, api, width: 390, scale: 1.5);
      expect(find.textContaining('库存现金'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _tapTableAction(WidgetTester tester, String label) async {
  if (find.text(label).evaluate().isEmpty) {
    await tester.tap(find.byTooltip('表格操作'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _ChartApi api, {
  double width = 1400,
  double height = 900,
  double scale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_Session.new),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(
            userId: 'chart-test-user',
            businessDatasetId: 'chart-test-dataset',
          ),
        ),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.paymentStyleEdit,
          Perm.paymentStyleCreate,
          Perm.financeReportView,
          Perm.financeViewAll,
        }),
        financeEntryFilePickerProvider.overrideWithValue(
          () async => PlatformFile(
            name: 'chart.xls',
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
        home: const FinanceChartDialog(canEdit: true),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ChartApi extends ApiClient {
  _ChartApi() : super(Dio());
  bool loseFirstApply = false, rejectApply = false;
  bool loseFirstMetadata = false;
  int metadataWrites = 0;
  String accountName = '库存现金';
  String accountCode = '1001';
  bool loseFirstTarget = false;
  final targetRequests = <Map<String, dynamic>>[];
  final metadataRequests = <Map<String, dynamic>>[];
  int uploads = 0, actualImports = 0;
  final applies = <String>[];
  final preview = <String, dynamic>{
    'importId': 'batch-1',
    'sourceName': 'chart.xls',
    'applied': false,
    'rows': [
      {'code': '1001', 'name': '库存现金', 'currencyName': ''},
    ],
    'issues': <Object>[],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.startsWith('/finance/chart/1001/metadata/operations/')) {
      if (metadataRequests.isEmpty || metadataWrites == 0) {
        return {'found': false};
      }
      return {
        'found': true,
        'requestId': metadataRequests.first['requestId'],
        'actorId': 'chart-test-user',
        'operation': 'CHART_METADATA_UPDATE',
        'outcome': 'SUCCEEDED',
        'result': {
          'status': 'UPDATED',
          'code': '1001',
          ...metadataRequests.first,
        },
      };
    }
    if (path == '/finance/chart/1001/metadata') {
      return {'code': '1001', 'name': accountName, 'version': metadataWrites};
    }
    if (path == '/finance/chart/imports') return {'items': <Object>[]};
    if (path == '/finance/chart/options') {
      return {
        'currencies': [
          {
            'id': 'currency-cny',
            'name': '人民币',
            'code': 'CNY',
            'baseCurrency': true,
          },
        ],
      };
    }
    if (path.startsWith('/finance/chart/imports/')) {
      return {...preview, 'applied': actualImports > 0};
    }
    if (path == '/finance/chart') {
      return {
        'items': [
          if (actualImports > 0)
            {
              'code': accountCode,
              'name': accountName,
              'classification': accountCode == '310410' ? 'EQUITY' : 'ASSET',
              'version': 0,
              'targets': <Object>[],
              'lineKeys': <Object>[],
            },
        ],
      };
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/reports/gl/line-bindings') {
      return [
        {
          'lineKey': 'BS_51',
          'label': '未分配利润',
          'bindingKind': 'STYLE',
          'sheet': 'BALANCE',
          'category': 'EQUITY',
        },
        {
          'lineKey': 'PL_PRIOR_ADJUSTMENT',
          'label': '以前年度损益调整',
          'bindingKind': 'STYLE',
          'sheet': 'PROFIT',
          'category': 'EQUITY',
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
  }) async {
    if (path == '/finance/chart/1001/metadata') {
      final request = Map<String, dynamic>.from(body! as Map);
      metadataRequests.add(request);
      if (metadataWrites == 0) {
        metadataWrites++;
        accountName = request['name'].toString();
      }
      if (loseFirstMetadata && metadataRequests.length == 1) {
        throw NetworkTimeoutException();
      }
      return {'status': 'UPDATED', 'code': '1001', ...request};
    }
    return {};
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
    return preview;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.startsWith('/finance/chart/1001/metadata/operations/') &&
        path.endsWith('/cancel')) {
      return {
        'found': true,
        'requestId': metadataRequests.first['requestId'],
        'actorId': 'chart-test-user',
        'operation': 'CHART_METADATA_UPDATE',
        'method': 'PUT',
        'path': '/finance/chart/1001/metadata',
        'requestBody': metadataRequests.first,
        'outcome': 'SUCCEEDED',
        'result': {
          'status': 'UPDATED',
          'code': '1001',
          ...metadataRequests.first,
        },
      };
    }
    if (path == '/finance/chart/310410/create-target') {
      targetRequests.add(Map<String, dynamic>.from(body! as Map));
      if (loseFirstTarget && targetRequests.length == 1) {
        throw NetworkTimeoutException();
      }
      return get('/finance/chart');
    }
    if (path == '/finance/chart/import-apply') {
      applies.add((body as Map)['importId'].toString());
      if (rejectApply) {
        throw ApiException(
          'VALIDATION_FAILED',
          '科目目录已变化，请重新预览',
          httpStatus: 422,
          hasResponseCode: true,
        );
      }
      actualImports = 1;
      if (loseFirstApply && applies.length == 1) {
        throw NetworkTimeoutException();
      }
      return {'status': 'APPLIED', 'imported': 1};
    }
    return {};
  }
}
