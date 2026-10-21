import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/security/secure_storage.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/warehouse/warehouse_task_scope.dart';
import '../../../core/network/server_config.dart';
import '../config/warehouse_document_history_config.dart';
import '../models/stock_doc.dart';
import '../models/warehouse_task_center_record.dart';
import '../models/production_finished_inbound_task.dart';
import '../pages/production_finished_batch_stock_in_page.dart';
import '../pages/warehouse_stock_batch_outbound_page.dart';
import '../repositories/procurement_inbound_repository.dart';
import 'warehouse_task_physical_detail_dialog.dart';

const _openActions = {
  'ARRIVAL_REGISTER',
  'ARRIVAL_CONTINUE',
  'ARRIVAL_EXCEPTION',
  'QUALITY_RESULT',
  'FINISHED_REGISTER',
  'FINISHED_COUNT',
  'FINISHED_ARRIVAL_DETAIL',
  'STOCK_EDIT',
  'STOCK_DETAIL',
  'HISTORY_DETAIL',
  'RETURN_RECEIVE',
  'SALES_OUTBOUND',
  'SUBCONTRACT_OUTBOUND',
  'PRODUCTION_DRAW',
  'MATERIAL_DISCOVERY',
  'FORM_DRAFT',
};

bool warehouseTaskRecordCanOpen(WarehouseTaskCenterRecord row) =>
    _openActions.contains(row.action) && (row.targetId ?? row.id).isNotEmpty;

/// Lists select physical items; the existing review pages still own document commands.
/// Continue-inspection keeps all item payloads until receipt IDs are unioned.
List<WarehouseTaskCenterRecord> warehouseTaskCommandTargets(
  Iterable<WarehouseTaskCenterRecord> rows,
) => {
  for (final row in rows)
    '${row.sourceType}:${row.action}:${switch (row.action) {
          'FINISHED_REGISTER' => row.dataId('lotId') ?? row.rowKey,
          'FINISHED_COUNT' => row.dataId('taskId') ?? row.targetId ?? row.id,
          'ARRIVAL_CONTINUE' => row.rowKey,
          _ => row.targetId ?? row.id,
        }}':
        row,
}.values.toList(growable: false);

String? warehouseTaskRecordBatchFamily(WarehouseTaskCenterRecord row) {
  if (!row.canHandle || !warehouseTaskRecordCanOpen(row)) return null;
  return switch (row.action) {
    'ARRIVAL_REGISTER' ||
    'FINISHED_REGISTER' ||
    'SALES_OUTBOUND' ||
    'SUBCONTRACT_OUTBOUND' ||
    'RETURN_RECEIVE' => row.action,
    'ARRIVAL_CONTINUE' when row.dataIds('draftReceiptIds').isNotEmpty =>
      row.action,
    'ARRIVAL_EXCEPTION' when (row.expectedVersion ?? 0) > 0 => row.action,
    'FINISHED_COUNT'
        when row.actionData['pendingQty'] is num &&
            (row.actionData['pendingQty'] as num) > 0 =>
      row.action,
    'PRODUCTION_DRAW' => 'DRAW',
    'MATERIAL_DISCOVERY' when row.actionData['materialsDefined'] == true =>
      'DRAW',
    'STOCK_EDIT'
        when {'OTHER_OUT', 'FINISHED_OUT'}.contains(row.dataId('docType')) =>
      'STOCK:${row.dataId('docType')}',
    // Final count input is read again from the original document detail.
    // A missing physical quantity never becomes a synthetic batch target.
    _ => null,
  };
}

String warehouseTaskRecordBatchLabel(String? family) => switch (family) {
  'ARRIVAL_EXCEPTION' => '按批准量处理',
  'ARRIVAL_CONTINUE' => '继续送检',
  'SALES_OUTBOUND' || 'SUBCONTRACT_OUTBOUND' || 'DRAW' => '核对出库',
  'RETURN_RECEIVE' => '确认收料',
  'FINISHED_COUNT' => '核对最终点收',
  final String value when value.startsWith('STOCK:') => '核对出库',
  _ => '办理所选',
};

Future<void> _openFinishedArrivalRegistration(
  BuildContext context,
  List<String> reportIds, {
  List<String>? lotIds,
  bool? preStock,
}) async {
  if (!context.mounted) return;
  final router = GoRouter.maybeOf(context);
  if (router == null) {
    context.appWarning('请返回仓库任务中心后重试');
    return;
  }
  // A dialog or Navigator page has no declarative route identity. Read its
  // host router configuration without subscribing across that route boundary.
  // This captures navigation only; the destination keeps its permission gate.
  final source = goRouterPageStateOrNull(context)?.uri ?? router.state.uri;
  await router.push<void>(
    RoutePath.warehouseProductionFinishedArrivalRegistration(
      reportIds,
      lotIds: lotIds,
      stockInBeforeInspection: preStock,
      returnTo: source.toString(),
    ),
  );
}

Future<void> openWarehouseTaskRecord(
  BuildContext context,
  WidgetRef ref,
  WarehouseTaskCenterRecord row,
) async {
  if (!warehouseTaskRecordCanOpen(row)) return;
  final id = row.targetId ?? row.id;
  if (row.action == 'HISTORY_DETAIL' || row.actionData['retained'] == true) {
    await _openRetained(context, ref, row);
    return;
  }
  switch (row.action) {
    case 'ARRIVAL_REGISTER':
      await context.push<void>(RoutePath.warehouseArrivalRegistration([id]));
    case 'ARRIVAL_CONTINUE':
      final receiptIds = row.dataIds('draftReceiptIds');
      if (!row.canHandle || receiptIds.isEmpty || receiptIds.length > 100) {
        context.appWarning('当前到货任务暂不能继续送检，请刷新核对');
        return;
      }
      final actor = ref.read(authenticatedScopeProvider);
      final server = ref.read(apiBaseUrlProvider);
      final warehouse = ref.read(warehouseTaskScopeProvider);
      final permissions = ref.read(currentPermissionsProvider);
      final requestScope = await AuthenticatedRequestScope.capture(
        baseUrl: server,
        storage: ref.read(secureStorageProvider),
        isCurrent: () =>
            context.mounted &&
            actor == ref.read(authenticatedScopeProvider) &&
            server == ref.read(apiBaseUrlProvider) &&
            warehouse == ref.read(warehouseTaskScopeProvider) &&
            permissions == ref.read(currentPermissionsProvider),
      );
      if (!context.mounted || !requestScope.isCurrent) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => UtenAlertDialog(
          title: const Text('继续送检'),
          content: const Text('按原收货单和批准数量继续送品质部检验。超量仍先隔离审核，不代表已增加可用库存。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认送检'),
            ),
          ],
        ),
      );
      if (!context.mounted ||
          confirmed != true ||
          actor != ref.read(authenticatedScopeProvider) ||
          server != ref.read(apiBaseUrlProvider)) {
        return;
      }
      await requestScope.run(
        () => ref
            .read(procurementInboundRepositoryProvider)
            .batchCompleteArrivals(
              receiptIds: receiptIds,
              idempotencyKey: 'arrival-complete-${const Uuid().v4()}',
            ),
      );
    case 'FINISHED_REGISTER':
      if ((row.line != null || row.dataId('sourceReportItemId') != null) &&
          row.dataId('lotId') == null) {
        context.appWarning(
          AppLocalizations.of(context).warehouseTaskSelectionChanged,
        );
        return;
      }
      await _openFinishedArrivalRegistration(context, [
        row.dataId('reportId') ?? id,
      ], lotIds: row.dataId('lotId') == null ? null : [row.dataId('lotId')!]);
    case 'FINISHED_COUNT' ||
        'RETURN_RECEIVE' ||
        'PRODUCTION_DRAW' ||
        'STOCK_DETAIL':
      final type =
          row.dataId('docType') ??
          switch (row.action) {
            'FINISHED_COUNT' => 'FINISHED_IN',
            'RETURN_RECEIVE' => 'WDRAW',
            'PRODUCTION_DRAW' => 'DRAW',
            _ => null,
          };
      if (type == null) return;
      await context.push<void>(
        RoutePath.stockDocDetail(type, row.dataId('documentId') ?? id),
      );
    case 'STOCK_EDIT':
      final type = row.dataId('docType');
      if (type == null || !row.canHandle) return;
      // Detail owns reviewed save, warehouse selection and the original capability gates.
      await context.push<void>(
        RoutePath.stockDocDetail(type, row.dataId('documentId') ?? id),
      );
    case 'SALES_OUTBOUND':
      await context.push<void>(
        '/warehouse/sales-outbound/${Uri.encodeComponent(id)}',
      );
    case 'SUBCONTRACT_OUTBOUND':
      await context.push<void>(
        RouteName.warehouseSubcontractOutboundDetail(id),
      );
    case 'MATERIAL_DISCOVERY':
      if (row.actionData['materialsDefined'] == true && row.canHandle) {
        await context.push<void>(_drawPath([row]));
      } else {
        await context.push<void>(
          '/warehouse/material-discovery/${Uri.encodeComponent(row.dataId('requestId') ?? id)}',
        );
      }
    case 'QUALITY_RESULT':
      final type = row.dataId('receiptType') ?? row.sourceType;
      await context.push<void>(
        RouteName.warehouseQualityResultDetail(
          type,
          row.dataId('receiptId') ?? id,
        ),
      );
    case 'FINISHED_ARRIVAL_DETAIL':
      // The registration page reads all original batches and their immutable identities.
      await _openFinishedArrivalRegistration(context, [
        row.dataId('reportId') ?? id,
      ]);
    case 'HISTORY_DETAIL':
      if (row.actionData['retained'] == true) {
        await _openRetained(context, ref, row);
        return;
      }
      final segment =
          row.dataId('historyType') ??
          switch (row.recordType) {
            'PURCHASE_RECEIPT' => 'purchase-receipts',
            'SUBCONTRACT_RECEIPT' => 'subcontract-receipts',
            'SUBCONTRACT_MATERIAL_ISSUE' => 'subcontract-material-issues',
            _ => null,
          };
      final type = WarehouseDocumentHistoryType.values
          .where((type) => type.segment == segment)
          .firstOrNull;
      if (type == null) return;
      await context.push<void>(type.detailPath(id));
    case 'ARRIVAL_EXCEPTION':
      await _openRetained(context, ref, row);
  }
}

String _drawPath(List<WarehouseTaskCenterRecord> rows) {
  final documents =
      rows
          .where((row) => row.action == 'PRODUCTION_DRAW')
          .map((row) => row.dataId('documentId') ?? row.targetId ?? row.id)
          .toSet()
          .toList()
        ..sort();
  final requests =
      rows
          .where((row) => row.action == 'MATERIAL_DISCOVERY')
          .map((row) => row.dataId('requestId') ?? row.targetId ?? row.id)
          .toSet()
          .toList()
        ..sort();
  return Uri(
    path: RouteName.warehouseProductionDrawBatchIssue,
    queryParameters: {
      if (documents.isNotEmpty) 'documentIds': documents.join(','),
      if (requests.isNotEmpty) 'discoveryRequestIds': requests.join(','),
    },
  ).toString();
}

Future<void> openWarehouseTaskRecordBatch(
  BuildContext context,
  WidgetRef ref,
  List<WarehouseTaskCenterRecord> rows, {
  bool? preStock,
}) async {
  if (rows.isEmpty) return;
  final families = rows.map(warehouseTaskRecordBatchFamily).toSet();
  if (families.length != 1 || families.contains(null)) {
    context.appWarning('不同办理方式的单据，请分别选择后处理');
    return;
  }
  final family = families.single!;
  rows = warehouseTaskCommandTargets(rows);
  final max = family == 'SUBCONTRACT_OUTBOUND' ? 50 : 100;
  if (rows.length > max) {
    context.appWarning('本次最多办理 $max 张单据，请分批办理');
    return;
  }
  final ids = rows.map((row) => row.targetId ?? row.id).toSet().toList()
    ..sort();
  switch (family) {
    case 'ARRIVAL_REGISTER':
      await context.push<void>(
        RoutePath.warehouseArrivalRegistration(
          ids,
          stockInBeforeInspection: preStock,
        ),
      );
    case 'FINISHED_REGISTER':
      final lots = rows.map((row) => row.dataId('lotId')).toList();
      if ((lots.any((id) => id != null) && lots.any((id) => id == null)) ||
          rows.any(
            (row) =>
                (row.line != null ||
                    row.dataId('sourceReportItemId') != null) &&
                row.dataId('lotId') == null,
          )) {
        context.appWarning(
          AppLocalizations.of(context).warehouseTaskSelectionChanged,
        );
        return;
      }
      final reports =
          rows
              .map((row) => row.dataId('reportId') ?? row.targetId ?? row.id)
              .toSet()
              .toList()
            ..sort();
      await _openFinishedArrivalRegistration(
        context,
        reports,
        lotIds: lots.every((id) => id != null) ? lots.cast<String>() : null,
        preStock: preStock,
      );
    case 'FINISHED_COUNT':
      final targets = rows
          .map(
            (row) => ProductionFinishedInboundTask.fromJson({
              ...row.actionData,
              'taskStage': 'FINAL_COUNT',
              'taskId': row.dataId('taskId') ?? row.targetId ?? row.id,
              'documentId': row.dataId('documentId') ?? row.targetId ?? row.id,
              'documentNo': row.billNo,
              'documentDate': row.businessDate,
              'lineCount': row.lineCount,
            }),
          )
          .toList(growable: false);
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ProductionFinishedBatchStockInPage(targets: targets),
        ),
      );
    case 'SALES_OUTBOUND':
      await context.push<void>(
        Uri(
          path: '/warehouse/sales-outbound/batch',
          queryParameters: {'shipmentIds': ids.join(',')},
        ).toString(),
      );
    case 'SUBCONTRACT_OUTBOUND':
      await context.push<void>(
        Uri(
          path: '/warehouse/subcontract-outbound/batch',
          queryParameters: {'issueIds': ids.join(',')},
        ).toString(),
      );
    case 'RETURN_RECEIVE':
      await context.push<void>(
        Uri(
          path: '/warehouse/material-returns/batch-receive',
          queryParameters: {'documentIds': ids.join(',')},
        ).toString(),
      );
    case 'DRAW':
      await context.push<void>(_drawPath(rows));
    default:
      if (!family.startsWith('STOCK:')) return;
      final type = StockDocType.values
          .where((type) => type.code == family.substring(6))
          .firstOrNull;
      if (type == null) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              WarehouseStockBatchOutboundPage(docType: type, documentIds: ids),
        ),
      );
  }
}

Future<void> _openRetained(
  BuildContext context,
  WidgetRef ref,
  WarehouseTaskCenterRecord row,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => WarehouseTaskPhysicalDetailDialog(
      row: row,
      warehouseScope: WarehouseListScope.of(context),
    ),
  );
}
