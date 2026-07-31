import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_log_page.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets('system management can inspect redacted before and after JSON', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [auditLogRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(home: AdminAuditLogPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('production_execution_segments'), findsOneWidget);
    await tester.tap(find.text('production_execution_segments'));
    await tester.pumpAndSettle();

    expect(find.text('审计详情 #42'), findsOneWidget);
    expect(find.textContaining('"status": "READY"'), findsOneWidget);
    expect(find.textContaining('"status": "DISPATCHED"'), findsOneWidget);
    expect(repository.detailCalls, 1);
  });
}

class _AuditRepository implements AuditLogRepository {
  int detailCalls = 0;

  @override
  Future<PagedResult<AuditLogEntry>> list({
    int page = 1,
    int size = 20,
    String? action,
    String? actorAccount,
    String? dateFrom,
    String? dateTo,
  }) async => const PagedResult(
    items: [
      AuditLogEntry(
        id: 42,
        actorAccount: 'planner',
        action: 'update',
        targetType: 'production_execution_segments',
        targetId: 'segment-1',
        result: 'success',
        createdAt: '2026-07-31T06:00:00+08:00',
      ),
    ],
    page: 1,
    size: 20,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<AuditLogDetail> detail(int id) async {
    detailCalls++;
    return const AuditLogDetail(
      id: 42,
      actorAccount: 'planner',
      action: 'update',
      targetType: 'production_execution_segments',
      targetId: 'segment-1',
      beforeJson: '{"status":"READY"}',
      afterJson: '{"status":"DISPATCHED"}',
      result: 'success',
      createdAt: '2026-07-31T06:00:00+08:00',
    );
  }
}
