// Typed app composition: shared table widgets never import business features.
import 'package:flutter/foundation.dart';
import 'shared/platform_tables/platform_table_binding.dart';
import 'platform_table_display_facts.dart';
import 'features/basic_data/models/goods_node.dart';
import 'features/basic_data/models/client_node.dart';
import 'features/basic_data/models/supplier_node.dart';
import 'features/basic_data/models/mould_node.dart';
import 'features/basic_data/models/color_node.dart';
import 'features/basic_data/models/unit_node.dart';
import 'features/basic_data/models/currency_node.dart';
import 'features/basic_data/models/warehouse_node.dart';
import 'features/basic_data/models/account_node.dart';
import 'features/basic_data/models/settlement_method_admin.dart';
import 'features/sales/models/sales_doc.dart';
import 'features/sales/widgets/sales_grid_columns.dart';
import 'features/purchase/models/purchase_doc.dart';
import 'features/purchase/widgets/purchase_grid_columns.dart';
import 'features/subcontract/models/subcontract_doc.dart';
import 'features/subcontract/widgets/subcontract_grid_columns.dart';
import 'features/finance/models/finance_doc.dart';
import 'features/finance/models/finance_procurement_workflow.dart';
import 'features/finance/models/finance_asset_models.dart';
import 'features/finance/models/sales_quote_finance_review.dart';
import 'features/finance/models/sales_order_finance_confirmation.dart';
import 'features/finance/widgets/finance_grid_columns.dart';
import 'features/warehouse/models/stock_doc.dart';
import 'features/warehouse/widgets/stock_grid_columns.dart';
import 'features/stock/models/stock_query.dart';
import 'features/production/models/production_plan.dart';
import 'features/production/models/production_daily_report.dart';
import 'features/production/widgets/production_grid_columns.dart';
import 'features/production/widgets/production_daily_grid_columns.dart';
import 'features/expense/models/expense_claim.dart';
import 'features/expense/models/expense_item.dart';
import 'features/employee/models/employee_api_models.dart';
import 'features/payroll/models/payroll_slip.dart';
import 'features/profile/models/profile_change_request.dart';
import 'features/visitor/models/visitor_application.dart';
import 'features/suggestion/models/suggestion.dart';
import 'features/rd_task/models/rd_task.dart';

const _salesBase = [
  'goods',
  'nameEn',
  'goodsCode',
  'color',
  'qty',
  'unit',
  'price',
  'discount',
  'amount',
  'remark',
];
const _aliases = <String, String>{
  'goodsName': 'goods',
  'goodsNameEn': 'nameEn',
  'colorName': 'color',
  'unitName': 'unit',
  'listPrice': 'price',
  'amountOriginal': 'amount',
};

String _viewFamily(String key) {
  if (key.startsWith('master.') || key.contains('basic_data')) return 'master';
  if (key.contains('payroll')) return 'payroll';
  if (key.contains('employee') ||
      key.contains('department') ||
      key.contains('hr_') ||
      key.contains('.profile.')) {
    return 'employee';
  }
  if (key.contains('visitor') || key.contains('security')) return 'visitor';
  for (final family in [
    'sales',
    'purchase',
    'subcontract',
    'finance',
    'production',
    'warehouse',
    'expense',
    'quality',
    'admin',
  ]) {
    if (key.contains(family)) return family;
  }
  if (key.contains('stock')) return 'warehouse';
  return 'operations';
}

String? _documentScope(String key, String family) {
  if (!key.startsWith('$family.')) return null;
  final mode = key.split('.')[1];
  final normalized = switch (mode) {
    'returnDoc' => 'return',
    'otherIncome' => 'other_income',
    'bankTransfer' => 'bank_transfer',
    'otherShipment' => 'other_shipment',
    'customerShipment' => 'shipment',
    'materialIssue' => 'material_issue',
    'materialReturn' => 'material_return',
    _ => mode,
  };
  return '${family}_$normalized';
}

/// Empty tables use their reified row type; broad Object rows are never guessed.
PlatformTableBinding<T>? resolvePlatformTable<T>(
  PlatformTableDescriptor<T> table,
) {
  final key = table.tableKey;
  if (key == null) return null;
  if (key.startsWith('master.goods.cost.') ||
      key == 'finance.inventory_cost_posting') {
    return PlatformTableBinding<T>(
      tableKey: key,
      scope: 'view_goods_cost',
      recordIdOf: (_) => null,
      factValuesOf: (row) => _costDisplayFacts(row),
    );
  }
  if (T == AccountStatementRow) {
    return PlatformTableBinding<T>(
      tableKey: key,
      scope: 'view_account_statement',
      recordIdOf: (_) => null,
      factValuesOf: (row) => platformDisplayFacts(row),
    );
  }
  final displayScope = additionalPlatformDisplayScope(T);
  if (displayScope != null) {
    return PlatformTableBinding<T>(
      tableKey: key,
      scope: displayScope,
      recordIdOf: (_) => null,
      factValuesOf: (row) => platformDisplayFacts(row),
    );
  }
  PlatformTableBinding<T> record<R>(
    String scope,
    String? Function(R) id, {
    String? schema,
  }) => PlatformTableBinding<T>(
    tableKey: schema ?? key,
    scope: scope,
    recordIdOf: (row) => row is R ? id(row) : null,
    canEditValues: table.kind == 'editable' || !scope.endsWith('_item'),
    columnAliases: _aliases,
    factValuesOf: (row) => platformDisplayFacts(row),
    factListenablesOf: platformDisplayListenables,
  );
  if (T == GoodsListItem) {
    return record<GoodsListItem>(
      'master_goods',
      (r) => r.id,
      schema: 'master.goods',
    );
  }
  if (T == ClientListItem) {
    return record<ClientListItem>(
      'master_client',
      (r) => r.id,
      schema: 'master.client',
    );
  }
  if (T == SupplierListItem) {
    return record<SupplierListItem>(
      'master_supplier',
      (r) => r.id,
      schema: 'master.supplier',
    );
  }
  if (T == MouldListItem) {
    return record<MouldListItem>(
      'master_mould',
      (r) => r.id,
      schema: 'master.mould',
    );
  }
  if (T == ColorListItem) {
    return record<ColorListItem>(
      'master_color',
      (r) => r.id,
      schema: 'master.color',
    );
  }
  if (T == UnitListItem) {
    return record<UnitListItem>(
      'master_unit',
      (r) => r.id,
      schema: 'master.unit',
    );
  }
  if (T == CurrencyListItem) {
    return record<CurrencyListItem>(
      'master_currency',
      (r) => r.id,
      schema: 'master.currency',
    );
  }
  if (T == WarehouseListItem) {
    return record<WarehouseListItem>(
      'master_warehouse',
      (r) => r.id,
      schema: 'master.warehouse',
    );
  }
  if (T == AccountListItem) {
    return record<AccountListItem>(
      'master_account',
      (r) => r.id,
      schema: 'master.account',
    );
  }
  if (T == SettlementMethodAdminItem) {
    return record<SettlementMethodAdminItem>(
      'master_settlement_method',
      (r) => r.id,
      schema: 'master.settlement',
    );
  }
  if (T == FinanceAssetSummary) {
    final deferred = key.contains('deferredExpense');
    return PlatformTableBinding<T>(
      tableKey: key,
      scope: deferred ? 'finance_deferred_expense' : 'finance_asset',
      recordIdOf: (row) => row is FinanceAssetSummary ? row.id : null,
      columnAliases: {
        ..._aliases,
        'grossAmount': deferred ? 'totalAmount' : 'originalValue',
        'balance': deferred ? 'remainingAmount' : 'netBookValue',
      },
      factValuesOf: (row) => row is FinanceAssetSummary
          ? {
              'originalValue': row.originalValue,
              'totalAmount': row.totalAmount,
              'netBookValue': row.netBookValue,
              'remainingAmount': row.remainingAmount,
              'salvageRate': row.salvageRate,
              'usefulMonths': row.usefulMonths?.toString(),
            }
          : const {},
    );
  }
  if (T == StockDocListItem) {
    return record<StockDocListItem>('stock_doc', (r) => r.id);
  }
  if (T == StockDocItem) {
    return record<StockDocItem>('stock_doc_item', (r) => r.id);
  }
  if (T == StockGridRow) {
    return record<StockGridRow>(
      'stock_doc_item',
      (r) => r.platformFields.sourceRecordId,
    ).copyWith(
      columnAliases: {
        ..._aliases,
        'bookQty': 'qty',
        'checkQty': 'countQty',
        'surplus': 'surplusQty',
      },
    );
  }
  if (T == ProductionPlanListItem) {
    return record<ProductionPlanListItem>('production_plan', (r) => r.id);
  }
  if (T == ProductionPlanItem) {
    return record<ProductionPlanItem>(
      'production_plan_item',
      (r) => r.id,
      schema: 'production.plan.items',
    );
  }
  if (T == ProductionGridRow) {
    return record<ProductionGridRow>(
      'production_plan_item',
      (r) => r.platformFields.sourceRecordId,
      schema: 'production.plan.items',
    );
  }
  if (T == ProductionDailyReportListItem) {
    return record<ProductionDailyReportListItem>(
      'production_daily_report',
      (r) => r.id,
    );
  }
  if (T == ProductionDailyReportItem) {
    return record<ProductionDailyReportItem>(
      'production_daily_report_item',
      (r) => r.id,
      schema: 'production.daily.items',
    );
  }
  if (T == DailyGridRow) {
    return record<DailyGridRow>(
      'production_daily_report_item',
      (r) => r.platformFields.sourceRecordId,
      schema: 'production.daily.items',
    ).copyWith(canEditRow: (row) => row is DailyGridRow && !row.isSubRow);
  }
  if (T == ExpenseClaim) {
    return record<ExpenseClaim>(
      'expense_claim',
      (r) => r.id,
      schema: 'expense.claim',
    );
  }
  if (T == ExpenseItem) {
    return record<ExpenseItem>(
      'expense_claim_item',
      (r) => r.id,
      schema: 'expense.claim.items',
    );
  }
  if (T == EmployeeSummary) {
    return record<EmployeeSummary>(
      'employee',
      (r) => r.id,
      schema: 'employee.records',
    );
  }
  if (T == PayrollSlip) {
    return record<PayrollSlip>(
      'payroll_slip',
      (r) => r.id,
      schema: 'payroll.slips',
    );
  }
  if (T == HrProfileChangeListItem) {
    return record<HrProfileChangeListItem>(
      'profile_change',
      (r) => r.batchId,
      schema: 'profile.change.hr',
    );
  }
  if (T == MyProfileChangeListItem) {
    return record<MyProfileChangeListItem>(
      'profile_change_self',
      (r) => r.batchId,
      schema: 'profile.change.self',
    );
  }
  if (T == VisitorApplication) {
    return record<VisitorApplication>(
      'visitor_application',
      (r) => r.id,
      schema: 'visitor.applications',
    );
  }
  if (T == Suggestion) {
    return record<Suggestion>(
      'suggestion',
      (r) => r.id,
      schema: 'suggestion.records',
    );
  }
  if (T == RdTaskRow) {
    return record<RdTaskRow>('rd_task', (r) => r.id, schema: 'rd.tasks');
  }
  final finance = _documentScope(key, 'finance');
  if (finance != null) {
    if (T == FinanceDocListItem) {
      return record<FinanceDocListItem>(finance, (r) => r.id);
    }
    if (T == FinanceDocItem) {
      return record<FinanceDocItem>('${finance}_item', (r) => r.id).copyWith(
        columnAliases: {
          ..._aliases,
          if (finance == 'finance_expense' || finance == 'finance_other_income')
            'dept': 'department',
        },
      );
    }
    if (T == FinanceGridRow) {
      return record<FinanceGridRow>(
        '${finance}_item',
        (r) => r.platformFields.sourceRecordId,
      ).copyWith(
        columnAliases: {
          ..._aliases,
          if (finance == 'finance_expense' || finance == 'finance_other_income')
            'dept': 'department',
          'balanceOriginal': 'balanceBeforeOriginal',
          'balanceAfter': 'balanceAfterOriginal',
        },
      );
    }
  }
  final sale = _documentScope(key, 'sales');
  if (sale != null) {
    if (T == SalesDocListItem) {
      return record<SalesDocListItem>(sale, (r) => r.id);
    }
    if (!{'sales_order', 'sales_quote'}.contains(sale)) {
      if (T == SalesDocItem) {
        return record<SalesDocItem>('${sale}_item', (r) => r.id);
      }
      if (T == SalesGridRow) {
        return record<SalesGridRow>('${sale}_item', (r) => r.documentItemId);
      }
    }
  }
  final purchase = _documentScope(key, 'purchase');
  if (purchase != null) {
    if (T == PurchaseDocListItem) {
      return record<PurchaseDocListItem>(purchase, (r) => r.id);
    }
    if (purchase != 'purchase_order' && T == PurchaseDocItem) {
      return record<PurchaseDocItem>('${purchase}_item', (r) => r.id);
    }
    if (purchase != 'purchase_order' && T == PurchaseGridRow) {
      return record<PurchaseGridRow>(
        '${purchase}_item',
        (r) => r.platformFields.sourceRecordId,
      );
    }
  }
  final subcontract = _documentScope(key, 'subcontract');
  if (subcontract != null) {
    if (T == SubcontractDocListItem) {
      return record<SubcontractDocListItem>(subcontract, (r) => r.id);
    }
    if (subcontract != 'subcontract_order' && T == SubcontractDocItem) {
      return record<SubcontractDocItem>('${subcontract}_item', (r) => r.id);
    }
    if (subcontract != 'subcontract_order' && T == SubcontractGridRow) {
      return record<SubcontractGridRow>(
        '${subcontract}_item',
        (r) => r.platformFields.sourceRecordId,
      );
    }
  }
  final salesItems =
      (sale == 'sales_quote' || sale == 'sales_order') &&
      key.endsWith('.items');
  return PlatformTableBinding<T>(
    tableKey: key,
    scope: 'view_${_viewFamily(key)}',
    recordIdOf: (_) => null,
    factValuesOf: (row) => platformDisplayFacts(row),
    factListenablesOf: platformDisplayListenables,
    columnAliases: _aliases,
    defaultVisibleColumnKeys: salesItems ? _salesBase : null,
    defaultColumnOrder: salesItems ? _salesBase : null,
    revealPopulatedColumnKeys: salesItems
        ? const {'clientModel', 'clientGoodsName', 'clientPrice'}
        : const {},
  );
}

Iterable<Listenable> platformDisplayListenables(Object? row) => switch (row) {
  final SalesGridRow r => [r.qty, r.price, r.discount, r.amountExactNotifier],
  final PurchaseGridRow r => [r.qty, r.price, r.amountExactNotifier],
  final SubcontractGridRow r => [r.qty, r.price, r.amountExactNotifier],
  final FinanceGridRow r => [
    r.qty,
    r.price,
    r.amount,
    r.exchangeRate,
    r.writeOff,
    r.localAmountExactNotifier,
    r.balanceAfterExactNotifier,
  ],
  final StockGridRow r => [r.qty, r.bookQty, r.checkQty],
  final ProductionGridRow r => [r.qty, r.oqty],
  final DailyGridRow r => [r.qty, r.defectQty, r.materialUsed, r.allocationQty],
  _ => const [],
};

Map<String, String?> _costDisplayFacts(Object? row) {
  if (row is! Map) return const {};
  const keys = {
    'designQty',
    'actualQty',
    'adoptedQty',
    'batchQty',
    'perProductQty',
    'unitPrice',
    'amount',
    'materialAmount',
    'feeAmount',
    'unitContribution',
    'value',
    'quantity',
    'baseAmount',
    'unitAmount',
    'knownAmountLocal',
    'allocatedAmountLocal',
    'heldAmountLocal',
    'amountLocal',
    'netQtyBase',
    'grossQtyBase',
    'returnedQtyBase',
    'effectiveQtyBase',
    'originalQtyBase',
    'outputQtyBase',
    'actualUnitCostLocal',
    'knownTotal',
    'unitCost',
  };
  return {
    for (final key in keys)
      if (row[key] is String || row[key] is num) key: row[key].toString(),
  };
}

/// Only unformatted model values are accepted. Hidden/masked values remain null.
Map<String, String?> platformDisplayFacts(Object? row) {
  final additional = additionalPlatformDisplayFacts(row);
  if (additional != null) return additional;
  if (row is InstantInventoryRow) {
    // Aggregated inventory has no writable row ID. Only quantities actually
    // shown in this table are calculation sources; cost and unit weight are not.
    return {
      'qty': row.qty?.toString(),
      'weight': row.weight?.toString(),
      'pendingQty': row.pendingQty?.toString(),
      'pendingStockInQty': row.pendingStockInQty?.toString(),
      'moreQty': row.moreQty?.toString(),
    };
  }
  if (row is AccountStatementRow) {
    // Preserve authorized decimal strings; never recover a masked/missing
    // amount from a legacy double or a formatted balance label.
    return {
      'inAmount': row.inAmountText,
      'outAmount': row.outAmountText,
      'balance': row.balanceText,
    };
  }
  if (row is SalesGridRow) {
    return {
      'qty': row.qty.text,
      'price': row.price.text,
      'discount': row.discount.text,
      'amount': row.amountExactNotifier.value,
    };
  }
  if (row is PurchaseGridRow) {
    return {
      'qty': row.qty.text,
      'price': row.price.text,
      'amount': row.amountExactNotifier.value,
    };
  }
  if (row is SubcontractGridRow) {
    return {
      'qty': row.qty.text,
      'price': row.price.text,
      'amount': row.amountExactNotifier.value,
    };
  }
  if (row is FinanceGridRow) {
    return {
      'qty': row.qty.text,
      'price': row.price.text,
      'amount': row.amount.text,
      'amountOriginal': row.amount.text,
      'amountLocal': row.localAmountExactNotifier.value,
      'exchangeRate': row.exchangeRate.text,
      'writeOffAmount': row.writeOff.text,
      'balanceAfter': row.balanceAfterExactNotifier.value,
      'receivableOriginal':
          row.receivableOriginalText ?? row.receivableOriginal?.toString(),
      'receivedOriginal':
          row.receivedOriginalText ?? row.receivedOriginal?.toString(),
      'writtenOffOriginal':
          row.writtenOffOriginalText ?? row.writtenOffOriginal?.toString(),
      'balanceOriginal':
          row.balanceOriginalText ?? row.balanceOriginal?.toString(),
      'prepaymentAppliedOriginal': row.prepaymentAppliedOriginal,
    };
  }
  if (row is StockGridRow) {
    return {
      'qty': row.isCheck ? row.bookQty.text : row.qty.text,
      'countQty': row.isCheck ? row.checkQty.text : null,
    };
  }
  if (row is ProductionGridRow) {
    return {'qty': row.qty.text, 'oqty': row.oqty.text};
  }
  if (row is DailyGridRow) {
    return {
      'qty': row.isSubRow ? null : row.qty.text,
      'defectQty': row.isSubRow ? null : row.defectQty.text,
    };
  }
  if (row is FinanceDocItem) {
    return {
      'qty': row.qtyText ?? row.qty?.toString(),
      'price': row.priceText ?? row.price?.toString(),
      'amount': row.amountOriginalText ?? row.amountOriginal?.toString(),
      'amountOriginal':
          row.amountOriginalText ?? row.amountOriginal?.toString(),
      'amountLocal': row.amountLocalText ?? row.amountLocal?.toString(),
      'exchangeRate': row.exchangeRateText ?? row.exchangeRate?.toString(),
      'writeOffAmount':
          row.writeOffAmountText ?? row.writeOffAmount?.toString(),
      'writeOffLocal': row.writeOffLocalText ?? row.writeOffLocal?.toString(),
      'appliedAmountLocal':
          row.appliedAmountLocalText ?? row.appliedAmountLocal?.toString(),
      'balanceBeforeOriginal':
          row.balanceBeforeOriginalText ??
          row.balanceBeforeOriginal?.toString(),
      'balanceAfterOriginal':
          row.balanceAfterOriginalText ?? row.balanceAfterOriginal?.toString(),
    };
  }
  if (row is SalesDocItem) {
    return {
      ...row.exactDecimals,
      'amount': row.exactDecimals['amountOriginal'],
    };
  }
  if (row is PurchaseDocItem) {
    return {
      'qty': row.qtyText,
      'price': row.priceText,
      'amount': row.amountOriginalText,
    };
  }
  if (row is SubcontractDocItem) {
    return {
      'qty': row.qtyText,
      'price': row.priceText,
      'amount': row.amountOriginalText,
    };
  }
  if (row is SalesQuoteFinanceLine) {
    return {
      'qty': row.qty,
      'price': row.storedPrice,
      'discount': row.discount,
      'amount': row.amount,
    };
  }
  if (row is SalesOrderFinanceReviewLine) {
    return {
      'qty': row.qty,
      'price': row.price,
      'discount': row.discount,
      'amount': row.amountOriginal,
    };
  }
  if (row is FinanceProcurementReviewLine) {
    return {
      'qty': row.qty,
      'price': row.price,
      'amount': row.amountOriginal,
      'amountLocal': row.amountLocal,
    };
  }
  if (row is Map) {
    return {
      for (final entry in row.entries)
        if (entry.key is String &&
            (entry.value is String || entry.value is num))
          entry.key as String: entry.value.toString(),
    };
  }
  return const {};
}
