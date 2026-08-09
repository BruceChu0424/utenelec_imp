import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/production/pages/production_plan_edit_page.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  group('existing document editors fail closed when detail loading fails', () {
    testWidgets('sales editor keeps a retryable error and removes save', (
      tester,
    ) async {
      final api = _FailingDetailApi();
      await _pumpEditor(
        tester,
        api,
        const SalesDocEditPage(
          docType: SalesDocType.order,
          id: 'existing-sales',
        ),
      );

      expect(
        find.byKey(const ValueKey('sales-doc-edit-load-error')),
        findsOneWidget,
      );
      _expectFailClosedEditor();

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(api.detailCalls, 2);
      expect(
        find.byKey(const ValueKey('sales-doc-edit-load-error')),
        findsOneWidget,
      );
      expect(find.text('保存'), findsNothing);
    });

    testWidgets('malformed sales detail is also blocked from editing', (
      tester,
    ) async {
      await _pumpEditor(
        tester,
        _FailingDetailApi(returnMalformedDetail: true),
        const SalesDocEditPage(
          docType: SalesDocType.order,
          id: 'existing-sales',
        ),
      );

      expect(
        find.byKey(const ValueKey('sales-doc-edit-load-error')),
        findsOneWidget,
      );
      expect(find.textContaining('无法读取完整单据数据'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
    });

    testWidgets('sales prerequisite failure exits loading and blocks detail', (
      tester,
    ) async {
      final api = _FailingDetailApi();
      await _pumpEditor(
        tester,
        api,
        const SalesDocEditPage(
          docType: SalesDocType.order,
          id: 'existing-sales',
        ),
        salesNames: _FailingSalesMasterNameService(api),
      );

      expect(api.detailCalls, 0);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.byKey(const ValueKey('sales-doc-edit-load-error')),
        findsOneWidget,
      );
      expect(find.textContaining('主档初始化失败'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
    });

    testWidgets('finance editor keeps a retryable error and removes save', (
      tester,
    ) async {
      final api = _FailingDetailApi();
      await _pumpEditor(
        tester,
        api,
        const FinanceDocEditPage(
          docType: FinanceDocType.bankTransfer,
          id: 'existing-finance',
        ),
      );

      expect(
        find.byKey(const ValueKey('finance-doc-edit-load-error')),
        findsOneWidget,
      );
      _expectFailClosedEditor();
    });

    testWidgets('production editor keeps a retryable error and removes save', (
      tester,
    ) async {
      final api = _FailingDetailApi();
      await _pumpEditor(
        tester,
        api,
        const ProductionPlanEditPage(id: 'existing-production'),
      );

      expect(
        find.byKey(const ValueKey('production-plan-edit-load-error')),
        findsOneWidget,
      );
      _expectFailClosedEditor();
    });
  });

  group('new document editors still initialize an editable draft', () {
    testWidgets('sales editor keeps its save action', (tester) async {
      await _pumpEditor(
        tester,
        _FailingDetailApi(),
        const SalesDocEditPage(docType: SalesDocType.order),
      );

      expect(
        find.byKey(const ValueKey('sales-doc-edit-load-error')),
        findsNothing,
      );
      expect(find.text('保存'), findsOneWidget);
    });

    testWidgets('finance editor keeps its save action', (tester) async {
      await _pumpEditor(
        tester,
        _FailingDetailApi(),
        const FinanceDocEditPage(docType: FinanceDocType.bankTransfer),
      );

      expect(
        find.byKey(const ValueKey('finance-doc-edit-load-error')),
        findsNothing,
      );
      expect(find.text('保存'), findsOneWidget);
    });

    testWidgets('production editor keeps its analysis action', (tester) async {
      await _pumpEditor(
        tester,
        _FailingDetailApi(),
        const ProductionPlanEditPage(),
      );

      expect(
        find.byKey(const ValueKey('production-plan-edit-load-error')),
        findsNothing,
      );
      expect(find.text('进入物料分析'), findsOneWidget);
    });
  });
}

void _expectFailClosedEditor() {
  expect(find.textContaining('服务暂时不可用'), findsOneWidget);
  expect(find.text('重试'), findsOneWidget);
  expect(find.byType(UtenBackButton), findsOneWidget);
  expect(find.text('保存'), findsNothing);
  expect(find.text('取消'), findsNothing);
}

Future<void> _pumpEditor(
  WidgetTester tester,
  ApiClient api,
  Widget page, {
  SalesMasterNameService? salesNames,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
        if (salesNames != null)
          salesMasterNameServiceProvider.overrideWithValue(salesNames),
      ],
      child: MaterialApp(home: page),
    ),
  );
  await tester.pumpAndSettle();
}

class _FailingSalesMasterNameService extends SalesMasterNameService {
  _FailingSalesMasterNameService(super.api);

  @override
  Future<void> ensureLoaded() async {
    throw ApiException('TEST_MASTER_INIT_FAILED', '主档初始化失败');
  }
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _FailingDetailApi extends ApiClient {
  _FailingDetailApi({this.returnMalformedDetail = false}) : super(Dio());

  final bool returnMalformedDetail;
  int detailCalls = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/existing-sales') ||
        path.endsWith('/existing-finance') ||
        path.endsWith('/existing-production')) {
      detailCalls += 1;
      if (returnMalformedDetail) return const {'id': 42};
      throw ApiException('TEST_LOAD_FAILED', '服务暂时不可用');
    }
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
