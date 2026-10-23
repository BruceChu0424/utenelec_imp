import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';

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
import '../models/arrival_registration_selection.dart';
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
  'STOCK_REVIEW',
  'STOCK_DETAIL',
  'HISTORY_DETAIL',
  'RETURN_RECEIVE',
  'SALES_OUTBOUND',
  'SUBCONTRACT_OUTBOUND',
  'PRODUCTION_DRAW',
  'MATERIAL_DISCOVERY',
  'FORM_DRAFT',
  'WORKSHOP_REQUISITION',
};

bool warehouseTaskRecordCanOpen(WarehouseTaskCenterRecord row) =>
    _openActions.contains(row.action) && (row.targetId ?? row.id).isNotEmpty;

/// Registration keeps physical items until the destination reads those exact rows.
/// Document commands deduplicate only after all selected item identities are retained.
List<WarehouseTaskCenterRecord> warehouseTaskCommandTargets(
  Iterable<WarehouseTaskCenterRecord> rows,
) => {
  for (final row in rows)
    '${row.sourceType}:${row.action}:${switch (row.action) {
          'FINISHED_REGISTER' => row.dataId('lotId') ?? row.rowKey,
          'FINISHED_COUNT' => row.line?.itemId ?? row.dataId('taskId') ?? row.targetId ?? row.id,
          'ARRIVAL_CONTINUE' => row.rowKey,
          'ARRIVAL_REGISTER' => row.dataId('expectationItemId') ?? row.line?.itemId ?? row.rowKey,
          'MATERIAL_DISCOVERY' => row.rowKey,
          _ => row.line?.itemId ?? row.targetId ?? row.id,
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
    'WORKSHOP_REQUISITION' => row.action,
    'QUALITY_RESULT' when row.dataIds('inspectionItemIds').isNotEmpty =>
      row.action,
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
    'STOCK_EDIT' || 'STOCK_REVIEW'
        when {
          'OTHER_OUT',
          'FINISHED_OUT',
          'OTHER_IN',
        }.contains(row.dataId('docType')) =>
      'STOCK:${row.dataId('docType')}',
    // Final count input is read again from the original document detail.
    // A missing physical quantity never becomes a synthetic batch target.
    _ => null,
  };
}

String warehouseTaskRecordBatchLabel(
  String? family, {
  Iterable<WarehouseTaskCenterRecord> rows = const [],
}) => switch (family) {
  'ARRIVAL_EXCEPTION' => '按批准量处理',
  'ARRIVAL_CONTINUE' => '继续送检',
  'SALES_OUTBOUND' || 'SUBCONTRACT_OUTBOUND' || 'DRAW' => '批量出库',
  'RETURN_RECEIVE' => '批量收料',
  'WORKSHOP_REQUISITION'
      when rows.isNotEmpty &&
          rows.every((row) => row.dataId('kind') == 'RETURN') =>
    '批量入库',
  'WORKSHOP_REQUISITION'
      when rows.isNotEmpty &&
          rows.every((row) => row.dataId('kind') == 'ISSUE') =>
    '批量出库',
  'QUALITY_RESULT' || 'STOCK:OTHER_IN' => '批量入库',
  'FINISHED_COUNT' => '批量点收',
  'ARRIVAL_REGISTER' || 'FINISHED_REGISTER' => '批量登记',
  final String value when value.startsWith('STOCK:') => '批量出库',
  _ => '批量办理',
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
  if (row.line != null &&
      row.canHandle &&
      ({
            'PRODUCTION_DRAW',
            'SUBCONTRACT_OUTBOUND',
            'SALES_OUTBOUND',
            'RETURN_RECEIVE',
            'FINISHED_COUNT',
            'WORKSHOP_REQUISITION',
          }.contains(row.action) ||
          warehouseTaskRecordBatchFamily(row)?.startsWith('STOCK:') == true)) {
    await openWarehouseTaskRecordBatch(context, ref, [row]);
    return;
  }
  final id = row.targetId ?? row.id;
  if (row.action == 'HISTORY_DETAIL' || row.actionData['retained'] == true) {
    await _openRetained(context, ref, row);
    return;
  }
  switch (row.action) {
    case 'ARRIVAL_REGISTER':
      final itemId = row.dataId('expectationItemId') ?? row.line?.itemId;
      if (row.line != null && itemId == null) {
        context.appWarning(
          AppLocalizations.of(context).warehouseTaskSelectionChanged,
        );
        return;
      }
      await context.push<void>(
        RoutePath.warehouseArrivalRegistration([
          id,
        ], expectationItemIds: itemId == null ? null : [itemId]),
      );
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
    case 'STOCK_EDIT' || 'STOCK_REVIEW':
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
    case 'WORKSHOP_REQUISITION':
      await openWarehouseTaskRecordBatch(context, ref, [row]);
    case 'QUALITY_RESULT':
      final type = row.dataId('receiptType') ?? row.sourceType;
      final rawItems = row.actionData['inspectionItemIds'];
      final hasItemScope = row.actionData.containsKey('inspectionItemIds');
      if ((row.line != null && !hasItemScope) ||
          (hasItemScope &&
              (rawItems is! List ||
                  rawItems.isEmpty ||
                  rawItems.length > 100 ||
                  rawItems.any(
                    (item) => item is! String || item.trim().isEmpty,
                  )))) {
        context.appWarning(
          AppLocalizations.of(context).warehouseTaskSelectionChanged,
        );
        return;
      }
      // A receipt row's line.itemId is the receipt item, not an inspection UUID.
      // Only the server's exact inspection identities may scope these commands.
      final items = hasItemScope
          ? (rawItems as List).cast<String>().map((id) => id.trim()).toSet()
          : null;
      await context.push<void>(
        Uri(
          path: RouteName.warehouseQualityResultDetail(
            type,
            row.dataId('receiptId') ?? id,
          ),
          queryParameters: {
            if (items != null) 'inspectionItemIds': items.join(','),
          },
        ).toString(),
      );
    case 'FINISHED_ARRIVAL_DETAIL':
      // A registered arrival belongs to one registration, not every pending
      // output of its report. The original task view refreshes when it closes.
      await showWarehouseTaskPhysicalDetailDialog(
        context,
        row: row,
        warehouseScope: WarehouseListScope.of(context),
        allowFinishedRegistrationReversal: true,
      );
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
  final discoveryRows = rows
      .where((row) => row.action == 'MATERIAL_DISCOVERY')
      .toList();
  final discoverySelection = <String, Map<String, dynamic>>{};
  if (discoveryRows.any((row) => row.line != null)) {
    for (final row in discoveryRows) {
      final key = row.line?.key;
      final version = row.expectedVersion;
      if (key == null ||
          !RegExp(r'^suggestion-[1-9][0-9]*$').hasMatch(key) ||
          version == null) {
        throw const FormatException('所选材料建议明细已变化，请刷新后重新选择');
      }
      final request = row.dataId('requestId') ?? row.targetId ?? row.id;
      final selected = discoverySelection.putIfAbsent(
        request,
        () => {'expectedVersion': version, 'keys': <String>[]},
      );
      if (selected['expectedVersion'] != version) {
        throw const FormatException('材料申请版本已变化，请刷新后重新选择');
      }
      (selected['keys'] as List<String>).add(key);
    }
  }
  return Uri(
    path: RouteName.warehouseProductionDrawBatchIssue,
    queryParameters: {
      if (documents.isNotEmpty) 'documentIds': documents.join(','),
      if (requests.isNotEmpty) 'discoveryRequestIds': requests.join(','),
      if (discoverySelection.isNotEmpty)
        'discoverySelection': jsonEncode(discoverySelection),
      ..._itemScopeQuery(
        rows.where((row) => row.action == 'PRODUCTION_DRAW').toList(),
      ),
    },
  ).toString();
}

Map<String, String> _itemScopeQuery(List<WarehouseTaskCenterRecord> rows) {
  if (rows.every((row) => row.line == null)) return const {};
  if (rows.any((row) => row.line?.itemId?.trim().isNotEmpty != true)) {
    throw const FormatException('所选明细标识已变化，请刷新后重新选择');
  }
  return {
    'itemIds': (rows.map((row) => row.line!.itemId!).toSet().toList()..sort())
        .join(','),
  };
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
  final max = family == 'ARRIVAL_REGISTER'
      ? arrivalRegistrationMaxSources
      : family == 'SUBCONTRACT_OUTBOUND'
      ? 50
      : 100;
  final ids = rows.map((row) => row.targetId ?? row.id).toSet().toList()
    ..sort();
  final commandCount = ids.length;
  if (commandCount > max) {
    context.appWarning('本次最多办理 $max 张单据，请分批办理');
    return;
  }
  if (family == 'ARRIVAL_REGISTER' &&
      rows.length > arrivalRegistrationMaxItems) {
    context.appWarning('本次最多登记 $arrivalRegistrationMaxItems 行到货明细，请分批办理');
    return;
  }
  switch (family) {
    case 'QUALITY_RESULT':
      if (rows.any((row) {
        final items = row.actionData['inspectionItemIds'];
        return items is! List ||
            items.isEmpty ||
            items.any((item) => item is! String || item.trim().isEmpty);
      })) {
        throw const FormatException('所选品质放行明细已变化，请刷新后重新选择');
      }
      final receipts =
          rows
              .map(
                (row) =>
                    '${row.dataId('receiptType') ?? row.sourceType}:${row.dataId('receiptId') ?? row.targetId ?? row.id}',
              )
              .toSet()
              .toList()
            ..sort();
      final inspectionItems =
          rows
              .expand((row) => row.dataIds('inspectionItemIds'))
              .toSet()
              .toList()
            ..sort();
      if (inspectionItems.isEmpty || inspectionItems.length > 100) {
        throw const FormatException('所选品质放行明细无效或超过100项，请刷新后分批办理');
      }
      await context.push<void>(
        Uri(
          path: RouteName.warehouseQualityBatchStockIn,
          queryParameters: {
            'receipts': receipts.join(','),
            'inspectionItemIds': inspectionItems.join(','),
          },
        ).toString(),
      );
    case 'ARRIVAL_REGISTER':
      final items = rows
          .map((row) => row.dataId('expectationItemId') ?? row.line?.itemId)
          .toList();
      if ((items.any((id) => id != null) && items.any((id) => id == null)) ||
          rows.any(
            (row) =>
                row.line != null &&
                (row.dataId('expectationItemId') ?? row.line?.itemId) == null,
          )) {
        context.appWarning(
          AppLocalizations.of(context).warehouseTaskSelectionChanged,
        );
        return;
      }
      await context.push<void>(
        RoutePath.warehouseArrivalRegistration(
          ids,
          expectationItemIds: items.every((id) => id != null)
              ? items.cast<String>()
              : null,
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
      final grouped = <String, List<WarehouseTaskCenterRecord>>{};
      for (final row in rows) {
        grouped
            .putIfAbsent(
              row.dataId('documentId') ?? row.targetId ?? row.id,
              () => [],
            )
            .add(row);
      }
      final targets = grouped.values
          .map((members) {
            final row = members.first;
            return ProductionFinishedInboundTask.fromJson({
              ...row.actionData,
              'taskStage': 'FINAL_COUNT',
              'taskId': row.dataId('taskId') ?? row.targetId ?? row.id,
              'documentId': row.dataId('documentId') ?? row.targetId ?? row.id,
              'documentNo': row.billNo,
              'documentDate': row.businessDate,
              'lineCount': members.every((row) => row.line != null)
                  ? members.length
                  : row.lineCount,
              if (members.every((row) => row.line?.quantity != null))
                'pendingQty': members.fold<num>(
                  0,
                  (sum, row) => sum + row.line!.quantity!,
                ),
              if (row.line != null)
                'goodsSummary': members
                    .map((row) => row.line?.goodsName ?? '')
                    .where((name) => name.isNotEmpty)
                    .join('、'),
            });
          })
          .toList(growable: false);
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ProductionFinishedBatchStockInPage(
            targets: targets,
            selectedItemIds: _itemScopeQuery(rows).containsKey('itemIds')
                ? rows.map((row) => row.line!.itemId!).toList()
                : null,
            selectedItemDocuments: {
              for (final row in rows)
                if (row.line?.itemId != null)
                  row.line!.itemId!:
                      row.dataId('documentId') ?? row.targetId ?? row.id,
            },
          ),
        ),
      );
    case 'SALES_OUTBOUND':
      await context.push<void>(
        Uri(
          path: '/warehouse/sales-outbound/batch',
          queryParameters: {
            'shipmentIds': ids.join(','),
            ..._itemScopeQuery(rows),
          },
        ).toString(),
      );
    case 'SUBCONTRACT_OUTBOUND':
      await context.push<void>(
        Uri(
          path: '/warehouse/subcontract-outbound/batch',
          queryParameters: {
            'issueIds': ids.join(','),
            ..._itemScopeQuery(rows),
          },
        ).toString(),
      );
    case 'RETURN_RECEIVE':
      await context.push<void>(
        Uri(
          path: '/warehouse/material-returns/batch-receive',
          queryParameters: {
            'documentIds': ids.join(','),
            ..._itemScopeQuery(rows),
          },
        ).toString(),
      );
    case 'DRAW':
      await context.push<void>(_drawPath(rows));
    case 'WORKSHOP_REQUISITION':
      final selections = <String, List<String>>{};
      for (final row in rows) {
        final requisition =
            row.dataId('requisitionId') ?? row.targetId ?? row.id;
        final line = row.dataId('lineId') ?? row.line?.itemId;
        if (line == null) throw const FormatException('所选领料明细已变化，请刷新后重新选择');
        selections.putIfAbsent(requisition, () => []).add(line);
      }
      await context.push<void>(
        Uri(
          path: '/workshop-material/issue/batch',
          queryParameters: {'selections': jsonEncode(selections)},
        ).toString(),
      );
    default:
      if (!family.startsWith('STOCK:')) return;
      final type = StockDocType.values
          .where((type) => type.code == family.substring(6))
          .firstOrNull;
      if (type == null) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => WarehouseStockBatchOutboundPage(
            docType: type,
            documentIds: ids,
            selectedItemIds: _itemScopeQuery(rows).containsKey('itemIds')
                ? rows.map((row) => row.line!.itemId!).toList()
                : null,
          ),
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
