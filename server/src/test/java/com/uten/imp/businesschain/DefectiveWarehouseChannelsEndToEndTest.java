package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.features.stock.StockReservationService;
import com.uten.imp.features.stock.dto.StockDefectiveMoveRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * ADR-146 不良品仓业务规则, 走真实服务与真实 PG(V799 守卫):
 * 正常入库进不了不良品仓; 「转不良品仓」后销售可预留量、按仓可用量、即时库存默认口径都不含这部分,
 * 货品所属仓库不会被学成不良品仓; 普通调拨不能把不良品搬回良品仓; 「不良复判转回」后恢复;
 * 两条通道各认自己的独立权限, 提交键回放原单, 换内容复用提交键被拒。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!",
        "uten.workshop-material.auto-close.enabled=false"})
class DefectiveWarehouseChannelsEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stockDocs;
    @Autowired StockReservationService reservations;
    @Autowired StockQueryService stockQuery;
    @Autowired PlatformTransactionManager transactions;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID defective;

    @BeforeEach void seed() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        world = fixture.seedWorld("defective-channel-" + UUID.randomUUID().toString().substring(0, 8));
        fixture.loginAs(world.superAdminUserId());
        defective = UUID.randomUUID();
        db.update("""
                INSERT INTO warehouses(id, code, name, status, is_accountable, is_defective)
                VALUES (?, ?, ?, '使用', TRUE, TRUE)
                """, defective, "DEF-" + defective.toString().substring(0, 8), "不良品仓-" + defective.toString().substring(0, 6));
        db.update("UPDATE goods SET min_qty = 0, owning_warehouse_id = ? WHERE id = ?", world.warehouseId(), world.goodsA());
    }

    @Test void goodStockNeverEntersOrCountsInADefectiveWarehouseAndOnlyTheChannelsMoveIt() {
        // 1. 正常入库(其它入库)进不了不良品仓。
        assertThatThrownBy(() -> otherIn(defective, "5"))
                .isInstanceOf(ApiException.class).hasMessageContaining("是不良品仓");
        otherIn(world.warehouseId(), "10");
        qty("10", saleable());

        // 2. 转不良品仓 4: 一次建单并过账, 可用量只剩 6, 所属仓库不变。
        String key = "e2e-to-def-" + UUID.randomUUID();
        var result = stockDocs.createDefectiveMove(move("TO_DEFECTIVE", world.warehouseId(), defective, "4", key));
        assertThat(result.warnings()).as("没有预留, 不用提醒").isEmpty();
        var moved = result.document();
        assertThat(moved.getStatus()).isEqualTo((short) 1);
        assertThat(moved.getTransferKind()).isEqualTo("TO_DEFECTIVE");
        assertThat(moved.getDefectReason()).isEqualTo("外观划伤, 判不良");
        qty("6", saleable());
        qty("6", db.queryForObject("SELECT sum(available_qty) FROM v_stock_usable WHERE goods_id=?",
                BigDecimal.class, world.goodsA()));
        qty("4", db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                BigDecimal.class, defective, world.goodsA()));
        assertThat(db.queryForObject("SELECT owning_warehouse_id FROM goods WHERE id=?", UUID.class, world.goodsA()))
                .as("所属仓库不会被学成不良品仓").isEqualTo(world.warehouseId());
        var hidden = stockQuery.instantInventory(null, null, false, goodsCode(), 1, 20, null, null).getItems();
        qty("6", hidden.getFirst().getQty());
        var shown = stockQuery.instantInventory(null, null, true, goodsCode(), 1, 20, null, null).getItems();
        qty("10", shown.getFirst().getQty());
        qty("4", shown.getFirst().getDefectiveQty());

        // 3. 同一提交键回放原单; 换内容(仓库、数量、原因任一不同)复用提交键被拒, 不把别的内容当成已办成。
        assertThat(stockDocs.createDefectiveMove(move("TO_DEFECTIVE", world.warehouseId(), defective, "4", key))
                .document().getId()).isEqualTo(moved.getId());
        assertThatThrownBy(() -> stockDocs.createDefectiveMove(move("TO_DEFECTIVE", world.warehouseId(), defective, "5", key)))
                .isInstanceOfSatisfying(ApiException.class, e -> assertThat(e.getCode()).isEqualTo(ErrorCode.CONFLICT));
        var otherReason = move("TO_DEFECTIVE", world.warehouseId(), defective, "4", key);
        assertThatThrownBy(() -> stockDocs.createDefectiveMove(new StockDefectiveMoveRequest(otherReason.kind(),
                otherReason.fromWarehouseId(), otherReason.toWarehouseId(), "尺寸超差", otherReason.billDate(),
                otherReason.requestKey(), otherReason.items())))
                .isInstanceOfSatisfying(ApiException.class, e -> assertThat(e.getCode()).isEqualTo(ErrorCode.CONFLICT));
        qty("4", db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                BigDecimal.class, defective, world.goodsA()));
        UUID otherGood = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id, code, name, status, is_accountable) VALUES (?, ?, ?, '使用', TRUE)",
                otherGood, "GOOD-" + otherGood.toString().substring(0, 8), "良品二仓-" + otherGood.toString().substring(0, 6));
        assertThatThrownBy(() -> stockDocs.createDefectiveMove(move("TO_DEFECTIVE", otherGood, defective, "4", key)))
                .isInstanceOfSatisfying(ApiException.class, e -> assertThat(e.getCode()).isEqualTo(ErrorCode.CONFLICT));

        // 4. 普通调拨不能把不良品搬回良品仓; 不良品仓上不能有任何预留。
        assertThatThrownBy(() -> transfer(defective, world.warehouseId(), "4"))
                .isInstanceOf(ApiException.class).hasMessageContaining("普通调拨的调出仓和调入仓必须同是良品仓或同是不良品仓");
        UUID orderItem = UUID.randomUUID();
        assertThatThrownBy(() -> db.update("""
                INSERT INTO stock_reservations(order_item_id,owner_type,owner_id,purpose,goods_id,warehouse_id,qty)
                VALUES (?,'SALES_ORDER_ITEM',?,'SALES_FULFILLMENT',?,?,1)
                """, orderItem, orderItem, world.goodsA(), defective))
                .hasStackTraceContaining("里面的货不能被任何订单、生产或委外预留");

        // 5. 不良复判转回 4 -> 可用量恢复 10。
        var released = stockDocs.createDefectiveMove(
                move("DEFECT_RELEASE", defective, world.warehouseId(), "4", "e2e-release-" + UUID.randomUUID()));
        assertThat(released.document().getTransferKind()).isEqualTo("DEFECT_RELEASE");
        qty("10", saleable());
        qty("0", db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                BigDecimal.class, defective, world.goodsA()));
    }

    /**
     * 判为不良的货已经不是良品: 「转不良品仓」记录事实, 不被本仓的预留与安全库存挡住(之前回 409「可动用库存不足」,
     * 不良品只能继续算作可用); 转走后已经没有实物的预留在结果里逐条提醒办理人。
     */
    @Test void quarantineIsNotBlockedByReservationsOrSafetyStockAndNamesTheUnbackedReservations() {
        otherIn(world.warehouseId(), "10");
        db.update("UPDATE goods SET min_qty = 8 WHERE id = ?", world.goodsA());
        UUID orderItem = UUID.randomUUID();
        replica("INSERT INTO stock_reservations(order_item_id,owner_type,owner_id,purpose,goods_id,warehouse_id,qty) "
                + "VALUES ('" + orderItem + "','SALES_ORDER_ITEM','" + orderItem + "','SALES_FULFILLMENT','"
                + world.goodsA() + "','" + world.warehouseId() + "',10)");
        try {
            var result = stockDocs.createDefectiveMove(move("TO_DEFECTIVE", world.warehouseId(), defective, "3",
                    "e2e-reserved-" + UUID.randomUUID()));
            assertThat(result.document().getStatus()).isEqualTo((short) 1);
            qty("7", db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                    BigDecimal.class, world.warehouseId(), world.goodsA()));
            qty("3", db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                    BigDecimal.class, defective, world.goodsA()));
            assertThat(result.warnings()).singleElement().asString()
                    .contains("还有 10 已被预留").contains("只剩 7").contains("有 3 的预留已经没有实物");
            // 非负底线照守: 不能把仓里没有的货转走。
            assertThatThrownBy(() -> stockDocs.createDefectiveMove(move("TO_DEFECTIVE", world.warehouseId(), defective,
                    "8", "e2e-over-" + UUID.randomUUID())))
                    .isInstanceOf(ApiException.class).hasMessageContaining("库存不足");
        } finally {
            replica("DELETE FROM stock_reservations WHERE order_item_id='" + orderItem + "'");
            db.update("UPDATE goods SET min_qty = 0 WHERE id = ?", world.goodsA());
        }
    }

    @Test void eachChannelOnlyHonoursItsOwnPermission() {
        otherIn(world.warehouseId(), "10");
        UUID warehouseKeeper = fixture.createUserWithPerms(world, "def-keeper-" + UUID.randomUUID().toString().substring(0, 6),
                "stock:defective_transfer", "stock_doc:view");
        UUID quality = fixture.createUserWithPerms(world, "def-quality-" + UUID.randomUUID().toString().substring(0, 6),
                "stock:defective_release", "stock_doc:view");
        UUID nobody = fixture.createUserWithPerms(world, "def-nobody-" + UUID.randomUUID().toString().substring(0, 6),
                "stock_doc:view", "stock_doc:create", "stock_doc:approve");

        fixture.loginAs(nobody);
        assertThat(stockDocs.defectiveMoveOptions().kinds()).isEmpty();
        assertThatThrownBy(() -> stockDocs.createDefectiveMove(
                move("TO_DEFECTIVE", world.warehouseId(), defective, "3", "e2e-nobody-" + UUID.randomUUID())))
                .isInstanceOf(AccessDeniedException.class);

        fixture.loginAs(warehouseKeeper);
        assertThat(stockDocs.defectiveMoveOptions().kinds()).containsExactly("TO_DEFECTIVE");
        stockDocs.createDefectiveMove(move("TO_DEFECTIVE", world.warehouseId(), defective, "3",
                "e2e-keeper-" + UUID.randomUUID()));
        assertThatThrownBy(() -> stockDocs.createDefectiveMove(
                move("DEFECT_RELEASE", defective, world.warehouseId(), "3", "e2e-keeper-rel-" + UUID.randomUUID())))
                .isInstanceOfSatisfying(ApiException.class, e -> assertThat(e.getCode()).isEqualTo(ErrorCode.FORBIDDEN));

        fixture.loginAs(quality);
        assertThat(stockDocs.defectiveMoveOptions().kinds()).containsExactly("DEFECT_RELEASE");
        stockDocs.createDefectiveMove(move("DEFECT_RELEASE", defective, world.warehouseId(), "3",
                "e2e-quality-" + UUID.randomUUID()));
        fixture.loginAs(world.superAdminUserId());
        qty("10", saleable());
    }

    // ------------------------------------------------------------------ fixture

    private StockDefectiveMoveRequest move(String kind, UUID from, UUID to, String qty, String key) {
        // 专门通道不带金额: 调拨按原出库成本估值, 也就不需要成本权限。
        var line = new StockDocItemLine();
        line.setGoodsId(world.goodsA());
        line.setUnitId(world.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        return new StockDefectiveMoveRequest(kind, from, to,
                "TO_DEFECTIVE".equals(kind) ? "外观划伤, 判不良" : "复判合格, 转回良品仓",
                BusinessTime.today(), key, List.of(line));
    }

    /** 复制模式写入(不经外键触发器), 造出订单预留这类夹具状态。 */
    private void replica(String sql) {
        db.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            try (var statement = connection.createStatement()) {
                statement.execute("SET session_replication_role = replica");
                try {
                    statement.execute(sql);
                } finally {
                    statement.execute("SET session_replication_role = origin");
                }
            }
            return null;
        });
    }

    /** 销售下单占用口径的全局可用量(服务端在事务里读)。 */
    private BigDecimal saleable() {
        return new TransactionTemplate(transactions).execute(
                status -> reservations.globalAvailableBase(world.goodsA(), null));
    }

    private void otherIn(UUID warehouse, String qty) {
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setBillDate(LocalDate.of(2026, 1, 1));
        request.setWarehouseId(warehouse);
        request.setItems(List.of(line(qty)));
        stockDocs.approve(stockDocs.create(request).getId());
    }

    private void transfer(UUID from, UUID to, String qty) {
        var request = new StockDocSaveRequest();
        request.setDocType("TRANSFER");
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(from);
        request.setToWarehouseId(to);
        request.setItems(List.of(line(qty)));
        stockDocs.approve(stockDocs.create(request).getId());
    }

    private StockDocItemLine line(String qty) {
        var line = new StockDocItemLine();
        line.setGoodsId(world.goodsA());
        line.setUnitId(world.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(BigDecimal.ONE);
        line.setAmountOriginal(line.getQty());
        line.setAmountLocal(line.getQty());
        return line;
    }

    private String goodsCode() {
        return db.queryForObject("SELECT code FROM goods WHERE id=?", String.class, world.goodsA());
    }

    private static void qty(String expected, BigDecimal actual) {
        assertThat(actual).as("quantity").isNotNull();
        assertThat(actual.compareTo(new BigDecimal(expected))).as("expected %s, actual %s", expected, actual).isZero();
    }
}
