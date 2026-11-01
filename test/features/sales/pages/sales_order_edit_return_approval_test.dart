import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import '../../../support/native_detail_reader_overrides.dart';
import '../../../support/page_resume_test_bridge.dart';

class _Adapter implements HttpClientAdapter {
  int detailReads = 0, claims = 0, releases = 0, approvals = 0;
  bool edited = false, approved = false;
  Map<String, dynamic> get detail => {
    'id': 'order-return',
    'billNo': 'XD-RETURN',
    'status': approved ? 1 : 0,
    'writable': true,
    'remark': edited ? '销售已修改' : '原内容',
    'managerReview': {
      'state': approved ? 'PENDING' : 'REJECTED',
      'rejectReason': '请修改',
    },
    'items': <Object>[],
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    Object body = <String, dynamic>{};
    if (path == '/sales/orders/order-return') {
      if (options.method == 'PUT') {
        edited = true;
      } else {
        detailReads++;
      }
      body = detail;
    } else if (path == '/sales/orders/order-return/approve') {
      approvals++;
      approved = true;
      body = detail;
    } else if (path.startsWith('/task-claims/')) {
      if (options.method == 'DELETE') {
        releases++;
      } else {
        claims++;
        body = {
          'claimedByMe': true,
          'targetType': 'SALES_ORDER_APPROVE',
          'targetKey': 'order-return',
          'claimedBy': 'native-detail-reader',
          'claimedByName': '销售',
          'claimedAt': DateTime.now().toIso8601String(),
          'leaseUntil': DateTime.now()
              .add(const Duration(minutes: 30))
              .toIso8601String(),
        };
      }
    } else if (path.endsWith('/progress-timeline') ||
        path.contains('/dict') ||
        path.endsWith('/learning-receipts')) {
      body = <Object>[];
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets(
    'rejected order can be approved immediately after edit return without refreshing forever',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost'))
        ..httpClientAdapter = adapter;
      final api = ApiClient(dio);
      final container = ProviderContainer(
        overrides: [
          ...nativeDetailReaderOverrides(),
          apiClientProvider.overrideWithValue(api),
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
          currentPermissionsProvider.overrideWithValue({
            Perm.salesOrderView,
            Perm.salesOrderEdit,
            Perm.salesOrderApprove,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      dio.interceptors.add(
        DataWriteRevisionInterceptor(
          (_) => container.read(dataWriteRevisionProvider.notifier).state++,
        ),
      );
      final router = GoRouter(
        initialLocation: '/sales/orders/order-return',
        routes: [
          GoRoute(
            path: '/sales/orders/:id/edit',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  await api.put('/sales/orders/order-return', body: {});
                  if (context.mounted) context.pop();
                },
                child: const Text('保存修改'),
              ),
            ),
          ),
          GoRoute(
            path: '/sales/orders/:id',
            builder: (_, _) => const SalesDocDetailPage(
              docType: SalesDocType.order,
              id: 'order-return',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: PageResumeTestBridge(
            router: router,
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(adapter.claims, 1);
      await tester.tap(find.byKey(const ValueKey('sales-doc-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存修改'));
      // Bound frames make the old endless refresh fail with a finite assertion.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final settledReads = adapter.detailReads;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(adapter.detailReads, settledReads);
      expect(adapter.detailReads, 2);
      expect(adapter.claims, 2);
      expect(
        container.read(dataWriteRevisionProvider),
        1,
        reason: 'Only the actual order save changed business data.',
      );
      final approve = find.widgetWithText(UtenButton, '审核');
      expect(tester.widget<UtenButton>(approve).onPressed, isNotNull);
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(find.text('确认审核'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
      await tester.pumpAndSettle();
      expect(adapter.approvals, 1);
      await tester.tap(find.byKey(const ValueKey('detail-summary-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('待销售负责人审核'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
