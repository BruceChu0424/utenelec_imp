package com.uten.imp.features.stock;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

import static com.uten.imp.common.time.BusinessTime.startOfDay;

/**
 * 读侧 Postgres 测试 (流水/库存分析) 的最小造数: 直接写主档、单据头、流水、重量调整、余额与称重记录。
 *
 * <p>只验证读侧 SQL, 不走过账服务: 造数连接开 session_replication_role = replica, 跳过写侧的守卫触发器
 * 与外键 (造数自己保证一致); 每次用随机编码, 可在同一个库里反复跑。用完调用 {@link #close()}。
 */
public final class StockReadSideSeed implements AutoCloseable {

    private final SingleConnectionDataSource single;
    private final JdbcTemplate db;
    private final String tag = UUID.randomUUID().toString().substring(0, 8);
    private int sequence;

    public StockReadSideSeed(DataSource dataSource) throws SQLException {
        Connection connection = dataSource.getConnection();
        connection.setAutoCommit(true);
        this.single = new SingleConnectionDataSource(connection, true);
        this.db = new JdbcTemplate(single);
        db.execute("SET session_replication_role = replica");
    }

    public JdbcTemplate jdbc() {
        return db;
    }

    /** 本次造数的随机标记 (名称/编码里都带着, 可用作关键字把本次数据筛出来)。 */
    public String tag() {
        return tag;
    }

    private String code(String prefix) {
        return prefix + "-" + tag + "-" + (++sequence);
    }

    public UUID warehouse(String name, UUID parentId) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id, code, name, status, is_accountable, parent_id) VALUES (?, ?, ?, '使用', true, ?)",
                id, code("W"), name + tag, parentId);
        return id;
    }

    public UUID unit(String name, String massCode) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO units(id, code, name, status) VALUES (?, ?, ?, '使用')", id, code("U"), name);
        if (massCode != null) {
            db.update("""
                    INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
                    VALUES (?, 'MASS', ?, 'MANUAL_GOVERNANCE')""", id, massCode);
        }
        return id;
    }

    public UUID goods(String name, UUID unitId, UUID categoryId) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO goods(id, code, name, unit_id, category_id, code_sequence)
                VALUES (?, ?, ?, ?, ?, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))""",
                id, code("G"), name + tag, unitId, categoryId);
        return id;
    }

    public UUID supplier(String name) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO suppliers(id, code, name, category_id, code_sequence)
                VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM suppliers))""",
                id, code("S"), name, UUID.randomUUID());
        return id;
    }

    public UUID client(String name) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO clients(id, code, name, category_id, code_sequence)
                VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM clients))""",
                id, code("C"), name, UUID.randomUUID());
        return id;
    }

    /** 仓库单据头 (status: 0 草稿 / 1 已审)。 */
    public UUID stockDoc(String docType, String billNo, LocalDate billDate, UUID warehouseId, UUID supplierId,
                         UUID clientId, int status) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO stock_documents(id, doc_type, bill_no, bill_date, warehouse_id, supplier_id, client_id, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                id, docType, billNo + tag, billDate, warehouseId, supplierId, clientId, status);
        return id;
    }

    public UUID stockDocItem(UUID docId, String docType, LocalDate billDate, UUID goodsId, BigDecimal qty) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO stock_document_items(id, doc_id, bill_type, bill_no, bill_date, goods_id, qty,
                    goods_snapshot_source)
                VALUES (?, ?, ?, (SELECT bill_no FROM stock_documents WHERE id = ?), ?, ?, ?, 'MASTER_AT_SAVE')""",
                id, docId, docType, docId, billDate, goodsId, qty);
        return id;
    }

    /** 销售出货单头 (老口径 finance_gate_version = 1: 只要单号与客户, 不带明细与财务放行链)。 */
    public UUID salesShipment(String billNo, LocalDate billDate, UUID clientId) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO sales_shipments(id, bill_no, bill_date, client_id, finance_gate_version)
                VALUES (?, ?, ?, ?, 1)""", id, billNo + tag, billDate, clientId);
        return id;
    }

    /** 一笔流水 (weight 千克可空; 有重量时来历默认 MEASURED)。返回 id。 */
    public UUID movement(LocalDate day, int type, String sourceDocType, UUID sourceDocId, UUID sourceItemId,
                         UUID goodsId, UUID warehouseId, int direction, String qty, String weightKg,
                         String weightSource, String amount) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO stock_movements(id, transaction_date, movement_type, source_doc_type, source_doc_id,
                    source_item_id, goods_id, warehouse_id, direction, qty, unit_rate, amount_local, weight, weight_source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)""",
                id, at(day), (short) type, sourceDocType, sourceDocId, sourceItemId, goodsId, warehouseId,
                (short) direction, new BigDecimal(qty), amount == null ? BigDecimal.ZERO : new BigDecimal(amount),
                weightKg == null ? null : new BigDecimal(weightKg),
                weightKg == null ? null : (weightSource == null ? "MEASURED" : weightSource));
        return id;
    }

    /** 只改重量的调整行 (delta 按 before/after 自动算, 任一未知为 NULL)。 */
    public UUID adjustment(LocalDate day, String kind, UUID goodsId, UUID warehouseId, String beforeKg, String afterKg,
                           String sourceDocType, UUID sourceDocId, String reason) {
        UUID id = UUID.randomUUID();
        BigDecimal before = beforeKg == null ? null : new BigDecimal(beforeKg);
        BigDecimal after = afterKg == null ? null : new BigDecimal(afterKg);
        db.update("""
                INSERT INTO stock_weight_adjustments(id, transaction_date, warehouse_id, goods_id, kind, weight_before,
                    weight_after, delta_kg, source_doc_type, source_doc_id, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                id, at(day), warehouseId, goodsId, kind, before, after,
                before == null || after == null ? null : after.subtract(before), sourceDocType, sourceDocId, reason);
        return id;
    }

    public void balance(UUID warehouseId, UUID goodsId, String qty, String weightKg, boolean estimated, String amount,
                        LocalDate lastMovement) {
        db.update("""
                INSERT INTO stock_balances(warehouse_id, goods_id, qty, weight, weight_estimated, amount_local,
                    last_movement_date)
                VALUES (?, ?, ?, ?, ?, ?, ?)""",
                warehouseId, goodsId, new BigDecimal(qty), weightKg == null ? null : new BigDecimal(weightKg),
                estimated, amount == null ? BigDecimal.ZERO : new BigDecimal(amount),
                lastMovement == null ? null : at(lastMovement));
    }

    /** 称重记录 (带记录当时的预期与告警快照)。 */
    public UUID observation(LocalDate day, UUID goodsId, UUID warehouseId, String kind, UUID supplierId,
                            String counterpartKind, UUID counterpartId, String qtyBase, String weightKg,
                            String expectedUnitKg, String expectedKg, String deviationPct, String alertLevel,
                            String sourceDocType, UUID sourceDocId) {
        UUID id = UUID.randomUUID();
        String role = switch (kind) {
            case "SAMPLE", "COUNT", "RECEIPT", "FINISHED", "OTHER_IN" -> "REFERENCE";
            default -> "CHECK";
        };
        db.update("""
                INSERT INTO goods_weight_observations(id, goods_id, warehouse_id, supplier_id, counterpart_kind,
                    counterpart_id, source_kind, role, qty_base, weight_kg, observed_at, source_doc_type, source_doc_id,
                    capture_key, expected_unit_weight_kg, expected_weight_kg, deviation_pct, alert_level,
                    estimate_basis_used, estimate_tier_used, tolerance_pct_used)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'LEARNED', 'GREEN', 3.000)""",
                id, goodsId, warehouseId, supplierId, counterpartKind, counterpartId, kind, role,
                new BigDecimal(qtyBase), new BigDecimal(weightKg), at(day), sourceDocType, sourceDocId,
                kind + ":" + id, expectedUnitKg == null ? null : new BigDecimal(expectedUnitKg),
                expectedKg == null ? null : new BigDecimal(expectedKg),
                deviationPct == null ? null : new BigDecimal(deviationPct), alertLevel);
        return id;
    }

    /** 货品级学习结果行。 */
    public void estimate(UUID goodsId, String evidence, String unitWeightKg, String tier, OffsetDateTime regimeChangedAt) {
        db.update("""
                INSERT INTO goods_weight_estimates(id, goods_id, supplier_id, evidence, log_mean, unit_weight_kg, log_se,
                    tau_lot, n_obs, n_ref, n_inliers, n_eff, rel_half_width, tier, n_draw, regime_changed_at,
                    last_observed_at, as_of, suggested_sample_size, algorithm_version, computed_at)
                VALUES (gen_random_uuid(), ?, NULL, ?, ln(?), ?, 0.01, 0.02, 5, 5, 5, 5, 0.04, ?, 0, ?, now(), now(),
                    20, 1, now())""",
                goodsId, evidence, new BigDecimal(unitWeightKg), new BigDecimal(unitWeightKg), tier, regimeChangedAt);
    }

    /** 业务日上午 10 点 (上海)。 */
    public static OffsetDateTime at(LocalDate day) {
        return startOfDay(day).plusHours(10);
    }

    @Override
    public void close() {
        db.execute("SET session_replication_role = origin");
        single.destroy();
    }
}
