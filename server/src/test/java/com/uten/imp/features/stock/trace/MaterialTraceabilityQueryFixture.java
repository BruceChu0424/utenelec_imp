package com.uten.imp.features.stock.trace;

import com.uten.imp.support.MigratedProjectionSchema;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/** Rollback-only reader facts over the real migrated column catalog. No command invariants are bypassed in production. */
final class MaterialTraceabilityQueryFixture implements AutoCloseable {
    static final LocalDate DAY = LocalDate.of(2026, 10, 15);
    final Connection connection;
    final NamedParameterJdbcTemplate db;
    final UUID owner, otherOwner, workshop, warehouse, otherWarehouse, materialUnit, productUnit, material, product;

    MaterialTraceabilityQueryFixture(Connection connection) throws SQLException {
        this.connection = connection;
        connection.setAutoCommit(false);
        try (var statement = connection.createStatement()) {
            statement.execute("CREATE SCHEMA material_trace_query");
            statement.execute("SET LOCAL search_path=material_trace_query,public");
        }
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                "goods", "units", "colors", "departments", "employees", "employee_secondary_departments", "users", "warehouses", "suppliers",
                "production_plans", "production_plan_items", "production_execution_segments", "production_planning_packages",
                "production_planning_package_documents", "plan_draw_links", "business_record_history",
                "production_material_demands", "production_material_supply_pegs", "stock_reservations",
                "stock_documents", "stock_document_items", "stock_movements",
                "production_material_stock_events", "production_material_stock_postings",
                "production_material_settlement_events", "production_material_settlement_postings",
                "production_daily_reports", "production_daily_report_items", "production_daily_report_material_usages",
                "production_daily_report_workers", "production_fqc_recovery_authorizations",
                "production_actual_output_supplement_proofs", "production_actual_output_supplement_reversals",
                "production_workshop_direct_transfers", "production_workshop_direct_transfer_items",
                "production_workshop_direct_source_allocations", "production_workshop_direct_source_events",
                "purchase_orders", "purchase_order_items", "purchase_receipts", "purchase_receipt_items",
                "production_material_receipt_allocations", "subcontract_orders", "subcontract_order_items",
                "subcontract_receipts", "subcontract_receipt_items", "subcontract_material_issues", "subcontract_material_issue_items",
                "subcontract_material_plan_items", "subcontract_receipt_material_consumptions",
                "production_material_subcontract_receipt_allocations", "production_material_make_receipt_allocations",
                "procurement_inspection_items", "procurement_inspection_events",
                "procurement_iqc_stock_in_batches", "procurement_iqc_stock_in_batch_items",
                "workshop_material_periods", "workshop_material_period_lines", "workshop_material_period_closes",
                "workshop_material_close_materials", "workshop_material_close_allocations", "workshop_material_close_theory_lines");
        db = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
        // PostgreSQL permits selecting header fields grouped by its primary key.
        // CTAS drops that functional dependency; preserve actual catalog PKs so
        // a valid production GROUP BY is not rejected by the query fixture.
        for (String ddl : db.queryForList("""
                SELECT format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s',target_namespace.nspname,
                              target.relname,source_key.conname,pg_get_constraintdef(source_key.oid))
                FROM pg_class target JOIN pg_namespace target_namespace ON target_namespace.oid=target.relnamespace
                JOIN pg_class source ON source.relname=target.relname
                JOIN pg_namespace source_namespace ON source_namespace.oid=source.relnamespace AND source_namespace.nspname='public'
                JOIN pg_constraint source_key ON source_key.conrelid=source.oid AND source_key.contype='p'
                WHERE target_namespace.nspname='material_trace_query' AND target.relkind='r'
                """, Map.of(), String.class)) db.getJdbcTemplate().execute(ddl);
        owner = insert("employees", "full_name", "Visible owner", "is_deleted", false);
        otherOwner = insert("employees", "full_name", "Hidden owner", "is_deleted", false);
        workshop = insert("departments", "name", "Injection workshop", "code", "TRACE_WORKSHOP", "is_deleted", false);
        warehouse = insert("warehouses", "name", "Authorized warehouse", "is_deleted", false);
        otherWarehouse = insert("warehouses", "name", "Hidden warehouse", "is_deleted", false);
        materialUnit = insert("units", "name", "千克", "status", "使用", "is_deleted", false);
        productUnit = insert("units", "name", "件", "status", "使用", "is_deleted", false);
        material = goods("RAW-TRACE", "Raw material", materialUnit);
        product = goods("PRODUCT-TRACE", "Finished product", productUnit);
    }

    UUID goods(String code, String name, UUID unit) {
        return insert("goods", "code", code, "name", name, "unit_id", unit,
                "status", "使用", "is_deleted", false, "auto_created", false);
    }

    record Segment(UUID plan, UUID segment, UUID demand, UUID reservation, UUID draw, UUID drawItem, UUID issue) { }

    Segment segment(String code, UUID maker, UUID location, UUID outputGoods, String issuedQty) {
        UUID plan = insert("production_plans", "bill_no", "PLAN-" + code, "bill_date", DAY,
                "maker_id", maker, "status", 1, "is_deleted", false, "is_canceled", false, "is_stopped", false, "is_closed", false);
        UUID pack = insert("production_planning_packages", "plan_id", plan, "warehouse_id", location,
                "status", "CONFIRMED", "is_deleted", false);
        UUID segment = insert("production_execution_segments", "plan_id", plan, "package_id", pack,
                "segment_code", code, "product_goods_id", outputGoods, "product_unit_id", productUnit,
                "product_unit_rate", BigDecimal.ONE, "workshop_department_id", workshop,
                "status", "IN_PROGRESS", "planned_qty", new BigDecimal("100"), "is_deleted", false);
        UUID demand = insert("production_material_demands", "plan_id", plan, "package_id", pack,
                "execution_segment_id", segment, "warehouse_id", location, "goods_id", material, "unit_id", materialUnit,
                "required_qty", new BigDecimal(issuedQty).max(new BigDecimal("100")), "released_qty", BigDecimal.ZERO, "supply_route", "BUY",
                "status", "ISSUED", "is_deleted", false);
        UUID reservation = insert("stock_reservations", "demand_id", demand, "owner_type", "PRODUCTION_MATERIAL_DEMAND",
                "owner_id", demand, "purpose", "PRODUCTION_MATERIAL", "goods_id", material, "warehouse_id", location,
                "qty", new BigDecimal(issuedQty), "consumed_qty", new BigDecimal(issuedQty), "released_qty", BigDecimal.ZERO,
                "status", 1, "is_deleted", false);
        UUID draw = insert("stock_documents", "bill_no", "DRAW-" + code, "bill_date", DAY,
                "doc_type", "DRAW", "warehouse_id", location, "maker_id", maker, "status", 1, "is_deleted", false);
        UUID item = insert("stock_document_items", "doc_id", draw, "execution_segment_id", segment, "goods_id", material, "unit_id", materialUnit,
                "unit_rate", BigDecimal.ONE, "qty", new BigDecimal(issuedQty), "is_deleted", false);
        UUID issue = stockPosting(demand, reservation, draw, item, "ISSUE", issuedQty, null);
        return new Segment(plan, segment, demand, reservation, draw, item, issue);
    }

    UUID stockPosting(UUID demand, UUID reservation, UUID document, UUID item, String type, String quantity, UUID original) {
        UUID event = insert("production_material_stock_events", "stock_document_id", document, "event_type", type);
        return insert("production_material_stock_postings", "event_id", event, "stock_document_item_id", item,
                "demand_id", demand, "reservation_id", reservation, "posting_type", type,
                "qty_base", new BigDecimal(quantity), "source_posting_id", original);
    }

    record Purchase(UUID order, UUID orderItem, UUID receipt, UUID receiptItem, UUID supplier) { }

    Purchase purchase(String code, UUID maker, UUID location, String quantity) {
        UUID supplier = insert("suppliers", "name", "Supplier " + code, "is_deleted", false);
        UUID order = insert("purchase_orders", "bill_no", code, "bill_date", DAY, "supplier_id", supplier,
                "warehouse_id", location, "maker_id", maker, "status", 1, "is_deleted", false);
        UUID orderItem = insert("purchase_order_items", "order_id", order, "goods_id", material,
                "unit_id", materialUnit, "unit_rate", BigDecimal.ONE, "qty", new BigDecimal(quantity), "is_deleted", false);
        UUID receipt = insert("purchase_receipts", "bill_no", "RECEIPT-" + code, "bill_date", DAY,
                "supplier_id", supplier, "warehouse_id", location, "maker_id", maker, "status", 1, "is_deleted", false);
        UUID receiptItem = insert("purchase_receipt_items", "receipt_id", receipt, "order_item_id", orderItem,
                "goods_id", material, "unit_id", materialUnit, "unit_rate", BigDecimal.ONE,
                "qty", new BigDecimal(quantity), "is_deleted", false);
        return new Purchase(order, orderItem, receipt, receiptItem, supplier);
    }

    UUID allocate(Purchase source, Segment target, String quantity) {
        return insert("production_material_receipt_allocations", "receipt_id", source.receipt(), "receipt_item_id", source.receiptItem(),
                "demand_id", target.demand(), "reservation_id", target.reservation(), "draw_id", target.draw(),
                "draw_item_id", target.drawItem(), "allocated_qty", new BigDecimal(quantity), "status", "EFFECTIVE");
    }

    record Report(UUID report, UUID item, UUID batch, UUID lot, UUID settlement) { }

    Report report(Segment target, String code, String outputQty, String consumedQty, boolean approved) {
        UUID report = insert("production_daily_reports", "bill_no", code, "bill_date", DAY, "maker_id", owner,
                "department_id", workshop, "warehouse_id", warehouse,
                "status", approved ? 1 : 0, "is_canceled", false, "is_deleted", false);
        UUID batch = UUID.randomUUID();
        UUID lot = db.queryForObject("SELECT fn_production_output_lot_id(:report,:batch,'WAREHOUSE',NULL)",
                Map.of("report", report, "batch", batch), UUID.class);
        UUID item = insert("production_daily_report_items", "report_id", report, "execution_segment_id", target.segment(),
                "goods_id", product, "unit_id", productUnit, "unit_rate", BigDecimal.ONE, "qty", new BigDecimal(outputQty),
                "output_batch_id", batch, "output_lot_id", lot, "destination", "WAREHOUSE", "is_deleted", false);
        insert("production_daily_report_workers", "report_id", report, "employee_id", owner, "sort_order", 1);
        insert("production_daily_report_material_usages", "report_id", report, "line_no", 1, "plan_id", target.plan(),
                "demand_id", target.demand(), "material_execution_segment_id", target.segment(), "qty_base", new BigDecimal(consumedQty));
        UUID settlement = null;
        if (approved && new BigDecimal(consumedQty).signum() > 0) {
            UUID event = insert("production_material_settlement_events", "plan_id", target.plan(),
                    "daily_report_id", report, "event_type", "POST");
            settlement = insert("production_material_settlement_postings", "event_id", event,
                    "demand_id", target.demand(), "issue_posting_id", target.issue(),
                    "settlement_type", "CONSUMED", "qty_base", new BigDecimal(consumedQty));
        }
        return new Report(report, item, batch, lot, settlement);
    }

    UUID insert(String table, Object... fields) {
        UUID id = UUID.randomUUID();
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("id", id);
        if (fields.length % 2 != 0) throw new IllegalArgumentException("Fixture fields must be pairs");
        for (int i = 0; i < fields.length; i += 2) values.put((String) fields[i], fields[i + 1]);
        if (!table.matches("[a-z_]+") || values.keySet().stream().anyMatch(name -> !name.matches("[a-z_]+")))
            throw new IllegalArgumentException("Only internal fixture identifiers are allowed");
        String names = String.join(",", values.keySet());
        String parameters = values.keySet().stream().map(name -> ":" + name).collect(java.util.stream.Collectors.joining(","));
        db.update("INSERT INTO " + table + "(" + names + ") VALUES(" + parameters + ")", new MapSqlParameterSource(values));
        return id;
    }

    @Override public void close() throws SQLException {
        try { connection.rollback(); } finally { connection.close(); }
    }
}
