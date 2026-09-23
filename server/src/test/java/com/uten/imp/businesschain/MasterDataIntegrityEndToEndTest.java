package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.GoodsBomPasteService;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.dto.BomPasteResult;
import com.uten.imp.features.master.lifecycle.MasterEntityKind;
import com.uten.imp.features.master.lifecycle.MasterLifecycleService;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchRequests;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchResult;
import com.uten.imp.features.master.materialcategory.MaterialCategoryService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.sales.order.SalesOrderService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 主档完整性(ADR-111)真库回归：2026-09-22 事故的每一个环节都在这里锁住。
 *
 * <ol>
 *   <li>被有效 BOM 引用的货品删不掉，报错点名父件；父件删除连带软删自己的 BOM 行；</li>
 *   <li>同批删父件+组件按不动点放行，父件被单据挡住时组件跟着挡住；</li>
 *   <li>绕过服务直接 UPDATE 被 V683 触发器拒绝(货品/颜色/单位)；</li>
 *   <li>物料分析 BOM 校验报错列出具体行；</li>
 *   <li>批量启停 100 条：一个事务、固定条数语句，逐条版本校验；</li>
 *   <li>组件粘贴整批原子：中途一行成环，全部不写；分类级联删除同样受保护。</li>
 * </ol>
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>，否则全部 SKIP。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@org.springframework.context.annotation.Import(ProductionJdbcMeasurement.Configuration.class)
class MasterDataIntegrityEndToEndTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired MasterLifecycleService lifecycle;
    @Autowired GoodsBomPasteService paste;
    @Autowired com.uten.imp.features.master.goods.GoodsBomService bomService;
    @Autowired GoodsService goodsService;
    @Autowired MaterialCategoryService categories;
    @Autowired MaterialAnalysisService analyses;
    @Autowired SalesOrderService salesOrders;
    private FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    // ---- 1) 事故本身：被 BOM 引用的组件删不掉，报错点名父件 ----------------------------

    @Test
    void deletingABomComponentIsRejectedAndNamesItsParent() {
        var w = world("del-comp");
        ApiException error = assertThrows(ApiException.class,
                () -> lifecycle.delete(MasterEntityKind.GOODS, w.goodsD()));
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage())
                .contains("不能删除")
                .contains("BOM 组件")
                .contains(code(w.goodsB()))
                .contains(name(w.goodsB()))
                .contains("请先在这些货品的 BOM 里移除它");
        assertFalse(deleted(w.goodsD()), "被引用的组件原样保留");
    }

    @Test
    void deletingAParentSoftDeletesItsOwnBomRowsInTheSameTransaction() {
        var w = world("del-parent");
        assertEquals(2, activeBomRows(w.goodsA()));
        lifecycle.delete(MasterEntityKind.GOODS, w.goodsA());
        assertTrue(deleted(w.goodsA()));
        assertEquals(0, activeBomRows(w.goodsA()), "父件自己的组装清单随之失效");
        // A 没了之后 E 不再被任何有效 BOM 引用，可以删。
        lifecycle.delete(MasterEntityKind.GOODS, w.goodsE());
        assertTrue(deleted(w.goodsE()));
    }

    // ---- 2) 同批删除的不动点 ---------------------------------------------------------

    @Test
    void batchDeletingParentAndComponentTogetherSucceedsButABlockedParentKeepsItsComponent() {
        var w = world("batch-fix");
        MasterBatchResult together = lifecycle.batchDelete(MasterEntityKind.GOODS,
                items(w.goodsA(), w.goodsB()));
        assertEquals(2, together.succeeded(), together.toString());
        assertTrue(deleted(w.goodsA()) && deleted(w.goodsB()));
        assertEquals(0, activeBomRows(w.goodsB()));

        var v = world("batch-open");
        UUID order = salesOrders.create(fixture.orderRequest(v, v.goodsA(), "3", "100")).getId();
        MasterBatchResult blocked = lifecycle.batchDelete(MasterEntityKind.GOODS,
                items(v.goodsA(), v.goodsB()));
        assertEquals(0, blocked.succeeded(), blocked.toString());
        MasterBatchResult.ItemResult parent = blocked.results().get(0);
        MasterBatchResult.ItemResult child = blocked.results().get(1);
        assertThat(parent.reason()).contains("未结案的销售订单")
                .contains(db.queryForObject("SELECT bill_no FROM sales_orders WHERE id=?", String.class, order));
        // 父件被订单挡住留下来，子件若被删就是事故形状：必须跟着挡住并点名父件。
        assertThat(child.reason()).contains("BOM 组件").contains(code(v.goodsA()));
        assertFalse(deleted(v.goodsA()) || deleted(v.goodsB()));
        assertEquals(2, activeBomRows(v.goodsA()), "挡住的父件 BOM 不动");
    }

    // ---- 3) 数据库兜底 ---------------------------------------------------------------

    @Test
    void bypassingTheServiceIsRejectedByTheDatabaseGuards() {
        var w = world("bypass");
        assertCheckViolation(() -> db.update("UPDATE goods SET is_deleted = TRUE WHERE id = ?", w.goodsD()));
        db.update("UPDATE goods SET color_id = ? WHERE id = ?", w.colorId(), w.goodsA());
        assertCheckViolation(() -> db.update("UPDATE colors SET is_deleted = TRUE WHERE id = ?", w.colorId()));
        assertCheckViolation(() -> db.update("UPDATE units SET is_deleted = TRUE WHERE id = ?", w.unitId()));
        // 没人用的颜色照样能删(触发器只拦「仍在用」)。
        UUID spare = UUID.randomUUID();
        db.update("INSERT INTO colors(id, code, name, status) VALUES (?, ?, ?, '使用')",
                spare, "CLR-SPARE-" + spare, "闲置色");
        assertEquals(1, db.update("UPDATE colors SET is_deleted = TRUE WHERE id = ?", spare));
    }

    @Test
    void colorBatchDeleteReportsEachRowAndDeletesOnlyTheFreeOnes() {
        var w = world("color-batch");
        db.update("UPDATE goods SET color_id = ? WHERE id = ?", w.colorId(), w.goodsC());
        UUID spare = UUID.randomUUID();
        db.update("INSERT INTO colors(id, code, name, status) VALUES (?, ?, ?, '使用')",
                spare, "CLR-FREE-" + spare, "闲置色");
        MasterBatchResult result = lifecycle.batchDelete(MasterEntityKind.COLOR, items(w.colorId(), spare));
        assertEquals(1, result.succeeded());
        assertFalse(result.results().get(0).ok());
        assertThat(result.results().get(0).reason()).contains("以下货品还在用它").contains(code(w.goodsC()));
        assertTrue(result.results().get(1).ok());
    }

    /** 七种主档的引用查询都在真库上跑一遍(整条 UNION 语句)，在用的逐条挡住并说明被谁用。 */
    @Test
    void everyMasterKindRejectsDeletingRecordsThatAreStillInUse() {
        var w = world("kinds");
        UUID mould = UUID.randomUUID();
        db.update("INSERT INTO moulds(id, code, name, status, code_sequence) VALUES (?, ?, ?, '使用', "
                + "(SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM moulds))", mould, "MJ-" + mould, "在用模具");
        db.update("UPDATE goods SET mould_id = ?, owning_warehouse_id = ?, default_supplier_id = ? WHERE id = ?",
                mould, w.warehouseId(), w.supplierId(), w.goodsD());
        salesOrders.create(fixture.orderRequest(w, w.goodsA(), "2", "100"));

        Map<MasterEntityKind, UUID> inUse = Map.of(
                MasterEntityKind.UNIT, w.unitId(),
                MasterEntityKind.WAREHOUSE, w.warehouseId(),
                MasterEntityKind.CLIENT, w.clientId(),
                MasterEntityKind.SUPPLIER, w.supplierId(),
                MasterEntityKind.MOULD, mould);
        Map<MasterEntityKind, String> expected = Map.of(
                MasterEntityKind.UNIT, "以下货品还在用它",
                MasterEntityKind.WAREHOUSE, "以下货品还在用它",
                MasterEntityKind.CLIENT, "未结案的销售订单",
                MasterEntityKind.SUPPLIER, "以下货品还在用它",
                MasterEntityKind.MOULD, "以下货品还在用它");
        for (var entry : inUse.entrySet()) {
            MasterBatchResult result = lifecycle.batchDelete(entry.getKey(),
                    List.of(new MasterBatchRequests.Item(entry.getValue(), null)));
            assertEquals(0, result.succeeded(), entry.getKey() + " " + result);
            assertThat(result.results().getFirst().reason())
                    .as(entry.getKey().name())
                    .contains("不能删除")
                    .contains(expected.get(entry.getKey()));
        }
        // 没人用的同类记录照常删除(引用查询零命中)。
        UUID spareUnit = UUID.randomUUID();
        db.update("INSERT INTO units(id, code, name, status) VALUES (?, ?, ?, '使用')",
                spareUnit, "U-SPARE-" + spareUnit, "闲置单位");
        lifecycle.delete(MasterEntityKind.UNIT, spareUnit);
        assertEquals(Boolean.TRUE, db.queryForObject(
                "SELECT is_deleted FROM units WHERE id = ?", Boolean.class, spareUnit));
    }

    // ---- 4) 物料分析 BOM 报错点名到行 --------------------------------------------------

    @Test
    void materialAnalysisBomErrorListsTheOffendingRowsAndHowToFixThem() {
        var w = world("bom-error");
        // 模拟 V683 之前留下的脏数据：组件已删、却还挂在有效 BOM 上(事故原样)。
        new TransactionTemplate(transactions).executeWithoutResult(status -> {
            db.execute("SET LOCAL session_replication_role = replica");
            db.update("UPDATE goods SET is_deleted = TRUE WHERE id = ?", w.goodsD());
        });
        db.update("UPDATE goods_bom_items SET color_id = NULL, color_legacy_id = 987654 "
                + "WHERE goods_id = ? AND component_goods_id = ?", w.goodsA(), w.goodsE());
        ApiException error = assertThrows(ApiException.class, () -> analyses.preview(new PreviewRequest(
                null, null, null, w.warehouseId(), "bom-error-" + w.goodsA(),
                List.of(new PreviewItem("OTHER", null, w.goodsA(), null, w.unitId(), "BOM-ERR-" + w.goodsA(),
                        "BOM 报错定位", BusinessTime.today().plusDays(7), new BigDecimal("10"))))));
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getMessage())
                .contains("2 处问题")
                .contains(code(w.goodsB())).contains(code(w.goodsD())).contains("组件货品已被删除")
                .contains(code(w.goodsE())).contains("老系统颜色")
                .contains("请在父件的 BOM 里移除或换掉这个组件")
                .doesNotContain("COMPONENT_DELETED");
    }

    // ---- 5) 批量启停：一次请求、固定语句数、逐条版本 ------------------------------------

    @Test
    void batchStatusOfOneHundredGoodsIsOneTransactionWithAFixedStatementCount() throws Exception {
        var w = world("status-100");
        List<UUID> ids = new ArrayList<>();
        for (int i = 0; i < 100; i++) {
            UUID id = UUID.randomUUID();
            fixture.insertGoods(id, "ST-" + i + "-" + id, "批量启停-" + i, "采购", w.unitId(), w.unitLegacy());
            ids.add(id);
        }
        List<MasterBatchRequests.Item> items = new ArrayList<>();
        for (UUID id : ids) items.add(new MasterBatchRequests.Item(id, version(id)));
        // 其中一条在列表加载后被别人改过：只有它失败，其余照常。
        db.update("UPDATE goods SET name = name || '*', version = version + 1 WHERE id = ?", ids.get(7));
        long auditBefore = auditRows(ids);

        ProductionJdbcMeasurement.Sample batch = ProductionJdbcMeasurement.begin();
        MasterBatchResult result;
        long started = System.nanoTime();
        try {
            result = lifecycle.batchStatus(MasterEntityKind.GOODS, "禁用", items);
        } finally {
            ProductionJdbcMeasurement.end();
        }
        double batchMillis = (System.nanoTime() - started) / 1_000_000.0;
        assertEquals(99, result.succeeded());
        assertThat(result.results().get(7).reason()).contains("已被他人修改");
        assertEquals(99, (long) db.queryForObject(
                "SELECT count(*) FROM goods WHERE status = '禁用' AND id = ANY(?::uuid[])", Long.class,
                (Object) ids.stream().map(UUID::toString).toArray(String[]::new)));
        // 绑定会话变量 + 锁行 + 一条 UPDATE；不随条数增长。
        assertThat(batch.logicalStatements).isLessThanOrEqualTo(4);
        long auditAfter = auditRows(ids);

        // 对照：改造前前端对每条先 GET 详情再 PATCH 状态(2N 次请求)，这里在同一真库上量同样 100 条。
        ProductionJdbcMeasurement.Sample legacy = ProductionJdbcMeasurement.begin();
        long legacyStarted = System.nanoTime();
        try {
            for (UUID id : ids) {
                var detail = goodsService.detail(id);
                goodsService.changeStatus(id, new com.uten.imp.features.master.dto.MasterStatusChangeRequest(
                        "使用", detail.getVersion()));
            }
        } finally {
            ProductionJdbcMeasurement.end();
        }
        double legacyMillis = (System.nanoTime() - legacyStarted) / 1_000_000.0;
        record(Map.of("case", "goods-batch-status-100",
                "batchRequests", 1, "batchStatements", batch.logicalStatements, "batchMillis", batchMillis,
                "legacyRequests", 200, "legacyStatements", legacy.logicalStatements, "legacyMillis", legacyMillis,
                "auditRowsWritten", auditAfter - auditBefore));
        assertThat(legacy.logicalStatements).isGreaterThan(batch.logicalStatements * 50);
    }

    // ---- 6) 组件粘贴整批原子 ----------------------------------------------------------

    @Test
    void bomPasteIsAtomicAndReportsTheOffendingLine() {
        var w = world("paste");
        List<UUID> fresh = new ArrayList<>();
        for (int i = 0; i < 4; i++) {
            UUID id = UUID.randomUUID();
            fixture.insertGoods(id, "PG-" + i + "-" + id, "粘贴件-" + i, "采购", w.unitId(), w.unitLegacy());
            fresh.add(id);
        }
        // 替换模式粘到 B(现有 {C, D})：第 5 行把 A 粘到 B 下面会成环(A→B→A)。
        List<BomItemSaveRequest> lines = new ArrayList<>();
        for (UUID id : fresh) lines.add(line(id, "2"));
        lines.add(line(w.goodsA(), "1"));
        List<UUID> original = activeBomItemIds(w.goodsB());
        ApiException error = assertThrows(ApiException.class, () -> paste.paste(new BomPasteRequest(
                BomPasteRequest.Mode.REPLACE, List.of(new BomPasteRequest.Target(w.goodsB(), original)), lines)));
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertThat(error.getFieldErrors()).hasSize(1);
        assertThat(error.getFieldErrors().getFirst().field()).startsWith("第 5 行").contains(code(w.goodsA()));
        assertThat(error.getFieldErrors().getFirst().message()).contains("环路");
        assertThat(activeBomItemIds(w.goodsB()))
                .as("一行不合格：原 BOM 一行不删，前 4 行也一条都不写")
                .containsExactlyInAnyOrderElementsOf(original);
        // 目标 C 在 A→B→C 下层，同理把 A 粘到 C 下也会成环，C 保持空。
        assertThrows(ApiException.class, () -> paste.paste(new BomPasteRequest(
                BomPasteRequest.Mode.APPEND, List.of(new BomPasteRequest.Target(w.goodsC(), List.of())), lines)));
        assertEquals(0, activeBomRows(w.goodsC()));

        // 版本校验：目标 B 现有 {C, D}；拿旧清单粘贴被拒。
        List<UUID> seen = activeBomItemIds(w.goodsB());
        db.update("UPDATE goods_bom_items SET qty = qty + 1 WHERE goods_id = ?", w.goodsB());
        insertExtraRow(w.goodsB(), fresh.get(0));
        ApiException stale = assertThrows(ApiException.class, () -> paste.paste(new BomPasteRequest(
                BomPasteRequest.Mode.REPLACE, List.of(new BomPasteRequest.Target(w.goodsB(), seen)),
                lines.subList(0, 4))));
        assertThat(stale.getFieldErrors().getFirst().message()).contains("已被他人修改");
        assertEquals(3, activeBomRows(w.goodsB()));

        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        BomPasteResult ok;
        try {
            ok = paste.paste(new BomPasteRequest(BomPasteRequest.Mode.REPLACE,
                    List.of(new BomPasteRequest.Target(w.goodsB(), activeBomItemIds(w.goodsB()))),
                    lines.subList(0, 4)));
        } finally {
            ProductionJdbcMeasurement.end();
        }
        assertEquals(4, ok.added());
        assertEquals(3, ok.removed());
        assertThat(activeBomComponents(w.goodsB())).containsExactlyInAnyOrderElementsOf(fresh);
        record(Map.of("case", "bom-paste-replace-4", "statements", sample.logicalStatements));
    }

    // ---- 7) 分类级联删除受同一保护 ----------------------------------------------------

    @Test
    void deletingACategoryWhoseGoodsAreStillReferencedDeletesNothing() {
        var w = world("cat");
        UUID category = UUID.randomUUID();
        db.update("INSERT INTO material_categories(id, code, name) VALUES (?, ?, ?)",
                category, "CAT-" + category.toString().substring(0, 8), "待删分类");
        db.update("UPDATE goods SET category_id = ? WHERE id IN (?, ?)", category, w.goodsC(), w.goodsD());
        ApiException error = assertThrows(ApiException.class, () -> categories.delete(category));
        assertThat(error.getMessage()).contains("分类「待删分类」不能删除").contains(code(w.goodsB()));
        assertFalse(deleted(w.goodsC()) || deleted(w.goodsD()));
        assertEquals(Boolean.FALSE, db.queryForObject(
                "SELECT is_deleted FROM material_categories WHERE id = ?", Boolean.class, category));
    }

    // ---- 8) 评审点名的在办业务(第二轮)：草稿退货、未收完的应收、草稿采购退货 --------------------

    /**
     * 第一轮只查了订单/出货/出入库等几类单据。这里逐一钉住评审给出的反例：它们现在由
     * MasterReferenceCatalog 登记，且 MasterReferenceCatalogCoverageTest 保证库里每个指向主档的列都已归类。
     */
    @Test
    void inFlightBusinessNamedByTheReviewBlocksDeletion() {
        var w = world("inflight");
        // (a) 草稿销售退货单上的货品：订单早已结案，退货还没审核——删掉货品，审核退货时就要给已删货品过账。
        UUID goods = UUID.randomUUID();
        fixture.insertGoods(goods, "RT-G-" + goods, "退货件", "采购", w.unitId(), w.unitLegacy());
        UUID salesReturn = UUID.randomUUID();
        String returnNo = documentNo("XT");
        db.update("INSERT INTO sales_returns(id, bill_no, bill_date, client_id, warehouse_id) "
                + "VALUES (?, ?, CURRENT_DATE, ?, ?)", salesReturn, returnNo, w.clientId(), w.warehouseId());
        db.update("INSERT INTO sales_return_items(id, bill_no, bill_date, return_id, goods_id, qty, "
                        + "goods_snapshot_source) VALUES (?, ?, CURRENT_DATE, ?, ?, 2, 'MASTER_AT_SAVE')",
                UUID.randomUUID(), returnNo, salesReturn, goods);
        ApiException returnBlocks = assertThrows(ApiException.class,
                () -> lifecycle.delete(MasterEntityKind.GOODS, goods));
        assertThat(returnBlocks.getMessage()).contains("还有未审核的退货单").contains(returnNo)
                .contains("请先处理完这些退货单");
        db.update("UPDATE sales_returns SET is_deleted = TRUE, deleted_at = now() WHERE id = ?", salesReturn);
        lifecycle.delete(MasterEntityKind.GOODS, goods);
        assertTrue(deleted(goods), "草稿退货撤掉之后照常可删");

        // (b) 客户还有没收完的应收：删了客户，这笔应收就再也挂不上新的收款单。
        UUID ledger = UUID.randomUUID();
        String arNo = ("AR-OPEN-" + ledger.toString().substring(0, 8)).toUpperCase();
        db.update("""
                INSERT INTO ar_ap_ledger(id, direction, source_doc_type, source_doc_id, source_doc_no, bill_no,
                    bill_date, client_id, currency_id, exchange_rate, amount_original, amount_original_local,
                    amount_settled, amount_balance, is_settled, business_type, open_item_kind,
                    amount_received_original, amount_write_off_original, amount_balance_original,
                    amount_offset_original, amount_offset_local)
                VALUES (?, 'AR', 'SALES_SHIPMENT', ?, ?, ?, CURRENT_DATE, ?, ?, 1, 100, 100,
                    0, 100, FALSE, 'SALES', 'RECEIVABLE', 0, 0, 100, 0, 0)
                """, ledger, UUID.randomUUID(), "SH-" + arNo, arNo, w.clientId(), w.currencyId());
        MasterBatchResult client = lifecycle.batchDelete(MasterEntityKind.CLIENT, items(w.clientId()));
        assertEquals(0, client.succeeded(), client.toString());
        assertThat(client.results().getFirst().reason()).contains("还有没收完的应收款").contains(arNo)
                .contains("请先收完或核销这些应收款");

        // (c) 仓库/供应商还挂在草稿采购退货单上。
        UUID purchaseReturn = UUID.randomUUID();
        String purchaseReturnNo = documentNo("CT");
        db.update("INSERT INTO purchase_returns(id, bill_no, bill_date, supplier_id, warehouse_id) "
                        + "VALUES (?, ?, CURRENT_DATE, ?, ?)",
                purchaseReturn, purchaseReturnNo, w.supplierId(), w.warehouseId());
        for (MasterEntityKind kind : List.of(MasterEntityKind.WAREHOUSE, MasterEntityKind.SUPPLIER)) {
            UUID id = kind == MasterEntityKind.WAREHOUSE ? w.warehouseId() : w.supplierId();
            MasterBatchResult result = lifecycle.batchDelete(kind, items(id));
            assertEquals(0, result.succeeded(), kind + " " + result);
            assertThat(result.results().getFirst().reason()).as(kind.name())
                    .contains("还有未审核的采购退货单").contains(purchaseReturnNo);
        }
    }

    // ---- 9) 不动点：一个组件被 10 个以上父件挡住也必须收敛(第二轮 blocker) -------------------

    @Test
    void componentBlockedByMoreThanTenParentsDoesNotHangTheBatch() throws Exception {
        var w = world("fixpoint");
        UUID component = UUID.randomUUID();
        fixture.insertGoods(component, "FP-C-" + component, "公共螺丝", "采购", w.unitId(), w.unitLegacy());
        for (int i = 0; i < 11; i++) {
            UUID parent = UUID.randomUUID();
            fixture.insertGoods(parent, "FP-EXT-" + i + "-" + parent, "外部父件-" + i, "自制", w.unitId(),
                    w.unitLegacy());
            fixture.insertBom(parent, component, "1");
        }
        // 同批父件 P 自己也是别的货品的组件(被挡住)，P→C 是内部边：C 必须跟着挡住。
        UUID parentInBatch = UUID.randomUUID();
        fixture.insertGoods(parentInBatch, "FP-P-" + parentInBatch, "同批父件", "自制", w.unitId(), w.unitLegacy());
        fixture.insertBom(parentInBatch, component, "2");
        fixture.insertBom(w.goodsA(), parentInBatch, "1");

        var security = org.springframework.security.core.context.SecurityContextHolder.getContext();
        ProductionJdbcMeasurement.Sample[] sample = new ProductionJdbcMeasurement.Sample[1];
        long started = System.nanoTime();
        MasterBatchResult result = org.junit.jupiter.api.Assertions.assertTimeoutPreemptively(
                java.time.Duration.ofSeconds(30), () -> {
                    org.springframework.security.core.context.SecurityContextHolder.setContext(security);
                    sample[0] = ProductionJdbcMeasurement.begin();
                    try {
                        return lifecycle.batchDelete(MasterEntityKind.GOODS, items(parentInBatch, component));
                    } finally {
                        ProductionJdbcMeasurement.end();
                        org.springframework.security.core.context.SecurityContextHolder.clearContext();
                    }
                });
        double millis = (System.nanoTime() - started) / 1_000_000.0;
        assertEquals(0, result.succeeded(), result.toString());
        assertThat(result.results().get(0).reason()).contains("BOM 组件").contains(code(w.goodsA()));
        assertThat(result.results().get(1).reason())
                .contains("它还是以下货品的 BOM 组件").contains("等共 12 处");
        assertFalse(deleted(parentInBatch) || deleted(component));
        record(Map.of("case", "goods-batch-delete-component-12-parents",
                "statements", sample[0].logicalStatements, "millis", millis));
        assertThat(sample[0].logicalStatements).isLessThanOrEqualTo(4);
    }

    // ---- 10) 分类删除与「往分类里挪货品」互斥(V684) -------------------------------------------

    @Test
    void movingGoodsIntoACategoryBeingDeletedWaitsAndIsRejected() throws Exception {
        var w = world("cat-race");
        UUID category = UUID.randomUUID();
        db.update("INSERT INTO material_categories(id, code, name) VALUES (?, ?, ?)",
                category, "CAT-" + category.toString().substring(0, 8), "并发待删分类");
        UUID goods = UUID.randomUUID();
        fixture.insertGoods(goods, "RACE-" + goods, "晚来的货品", "采购", w.unitId(), w.unitLegacy());

        var security = org.springframework.security.core.context.SecurityContextHolder.getContext();
        java.util.concurrent.CountDownLatch locked = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch release = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.ExecutorService pool = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            java.util.concurrent.Future<?> deleter = pool.submit(() -> {
                org.springframework.security.core.context.SecurityContextHolder.setContext(security);
                try {
                    new TransactionTemplate(transactions).executeWithoutResult(status -> {
                        categories.delete(category);
                        locked.countDown();
                        try {
                            assertTrue(release.await(30, java.util.concurrent.TimeUnit.SECONDS));
                        } catch (InterruptedException interrupted) {
                            Thread.currentThread().interrupt();
                            throw new IllegalStateException(interrupted);
                        }
                    });
                } finally {
                    org.springframework.security.core.context.SecurityContextHolder.clearContext();
                }
                return null;
            });
            assertTrue(locked.await(30, java.util.concurrent.TimeUnit.SECONDS), "删除事务已锁住分类、尚未提交");
            java.util.concurrent.Future<Integer> mover = pool.submit(
                    () -> db.update("UPDATE goods SET category_id = ? WHERE id = ?", category, goods));
            Thread.sleep(500);
            assertFalse(mover.isDone(), "挪进正在删除的分类必须等删除提交，不能读旧快照直接写进去");
            release.countDown();
            deleter.get(30, java.util.concurrent.TimeUnit.SECONDS);
            java.util.concurrent.ExecutionException rejected = assertThrows(
                    java.util.concurrent.ExecutionException.class,
                    () -> mover.get(30, java.util.concurrent.TimeUnit.SECONDS));
            assertCheckViolation(() -> {
                throw (RuntimeException) rejected.getCause();
            });
        } finally {
            release.countDown();
            pool.shutdownNow();
        }
        assertEquals(Boolean.TRUE, db.queryForObject(
                "SELECT is_deleted FROM material_categories WHERE id = ?", Boolean.class, category));
        assertEquals(null, db.queryForObject("SELECT category_id FROM goods WHERE id = ?", UUID.class, goods),
                "货品没有挂到已删除的分类下");
        // 删除之后：再往里建子分类、挪货品都被数据库直接拒绝。
        assertCheckViolation(() -> db.update("INSERT INTO material_categories(id, code, name, parent_id) "
                + "VALUES (?, ?, ?, ?)", UUID.randomUUID(), "CAT-C-" + UUID.randomUUID().toString().substring(0, 8),
                "已删分类下的子分类", category));
        assertCheckViolation(() -> db.update("UPDATE goods SET category_id = ? WHERE id = ?", category, goods));
    }

    // ---- 11) 组装行批量删除：语句数与勾选条数无关(第二轮 minor) ------------------------------

    @Test
    void bomBatchDeleteIsSetBasedWithAStatementCountIndependentOfTheSelection() {
        var w = world("bom-del");
        UUID parent = UUID.randomUUID();
        fixture.insertGoods(parent, "BD-P-" + parent, "批量删组件的父件", "自制", w.unitId(), w.unitLegacy());
        for (int i = 0; i < 60; i++) {
            UUID component = UUID.randomUUID();
            fixture.insertGoods(component, "BD-C-" + i + "-" + component, "待删组件-" + i, "采购",
                    w.unitId(), w.unitLegacy());
            fixture.insertBom(parent, component, "1");
        }
        List<UUID> rows = activeBomItemIds(parent);
        List<UUID> firstTen = rows.subList(0, 10);
        List<UUID> remaining = rows.subList(10, rows.size());

        ProductionJdbcMeasurement.Sample ten = ProductionJdbcMeasurement.begin();
        try {
            assertEquals(10, bomService.deleteAll(parent, firstTen));
        } finally {
            ProductionJdbcMeasurement.end();
        }
        ProductionJdbcMeasurement.Sample fifty = ProductionJdbcMeasurement.begin();
        try {
            assertEquals(50, bomService.deleteAll(parent, remaining));
        } finally {
            ProductionJdbcMeasurement.end();
        }
        assertEquals(0, activeBomRows(parent));
        record(Map.of("case", "bom-batch-delete", "statements10", ten.logicalStatements,
                "statements50", fifty.logicalStatements));
        // 逐行 findById + save 的老写法是 2N 条起步(再加重算材料合计按组件逐个懒加载)；
        // 这里删 50 条不比删 10 条多(删 10 条那次剩下 50 行要重算，反而多一条「有无下层」查询)。
        assertThat(fifty.logicalStatements).isLessThanOrEqualTo(ten.logicalStatements);
        assertThat(ten.logicalStatements).isLessThan(12);
    }

    // ---- 12) 组装信息页签每展开一层：语句数与组件个数无关 --------------------------------------

    /**
     * 组装信息页签每展开一层调一次 list：组件、组件单位/颜色、行颜色/默认供应商、可见性、
     * 「组件自己有没有下层」都要一次取齐，不能按组件逐个查(30 个组件 30 倍语句)。改一行 BOM
     * 之后的材料合计重算同理。
     */
    @Test
    void bomListAndRecalculationDoNotQueryPerComponent() {
        var w = world("bom-list");
        Map<Integer, Long> listStatements = new java.util.TreeMap<>();
        Map<Integer, Long> addStatements = new java.util.TreeMap<>();
        for (int size : List.of(5, 30)) {
            UUID parent = UUID.randomUUID();
            fixture.insertGoods(parent, "BL-P-" + size + "-" + parent, "展开测量父件", "自制", w.unitId(),
                    w.unitLegacy());
            for (int i = 0; i < size; i++) {
                UUID component = UUID.randomUUID();
                fixture.insertGoods(component, "BL-C-" + i + "-" + component, "展开组件-" + i, "采购",
                        w.unitId(), w.unitLegacy());
                db.update("UPDATE goods SET color_id = ? WHERE id = ?", w.colorId(), component);
                fixture.insertBom(parent, component, "1");
                if (i % 3 == 0) {
                    // 三分之一的组件自己还有下层(展开箭头)。
                    UUID grandChild = UUID.randomUUID();
                    fixture.insertGoods(grandChild, "BL-G-" + i + "-" + grandChild, "孙件-" + i, "采购",
                            w.unitId(), w.unitLegacy());
                    fixture.insertBom(component, grandChild, "1");
                }
            }
            ProductionJdbcMeasurement.Sample list = ProductionJdbcMeasurement.begin();
            List<com.uten.imp.features.master.goods.dto.BomItemView> views;
            try {
                views = new TransactionTemplate(transactions).execute(status -> bomService.list(parent));
            } finally {
                ProductionJdbcMeasurement.end();
            }
            assertEquals(size, views.size());
            assertEquals((size + 2) / 3, views.stream()
                    .filter(com.uten.imp.features.master.goods.dto.BomItemView::isHasChildren).count());
            assertTrue(views.stream().allMatch(view -> view.getComponentUnitName() != null
                    && view.getComponentColorName() != null), "单位与颜色名一并带出");
            listStatements.put(size, list.logicalStatements);

            UUID extra = UUID.randomUUID();
            fixture.insertGoods(extra, "BL-X-" + size + "-" + extra, "追加组件", "采购", w.unitId(), w.unitLegacy());
            ProductionJdbcMeasurement.Sample add = ProductionJdbcMeasurement.begin();
            try {
                paste.paste(new BomPasteRequest(BomPasteRequest.Mode.APPEND,
                        List.of(new BomPasteRequest.Target(parent, null)), List.of(line(extra, "1"))));
            } finally {
                ProductionJdbcMeasurement.end();
            }
            addStatements.put(size, add.logicalStatements);
        }
        record(Map.of("case", "bom-list-and-append", "list", listStatements, "append", addStatements));
        assertEquals(listStatements.get(5), listStatements.get(30), "展开一层的语句数不随组件个数增长");
        assertEquals(addStatements.get(5), addStatements.get(30), "追加后重算材料合计不随组件个数增长");
    }

    // ---- helpers -------------------------------------------------------------------

    private FullChainEndToEndTest.World world(String tag) {
        var w = fixture.seedWorld(tag + "-" + UUID.randomUUID().toString().substring(0, 6));
        fixture.loginAs(w.superAdminUserId());
        return w;
    }

    private static List<MasterBatchRequests.Item> items(UUID... ids) {
        List<MasterBatchRequests.Item> out = new ArrayList<>();
        for (UUID id : ids) out.add(new MasterBatchRequests.Item(id, null));
        return out;
    }

    private static BomItemSaveRequest line(UUID component, String qty) {
        BomItemSaveRequest request = new BomItemSaveRequest();
        request.setComponentGoodsId(component);
        request.setQty(new BigDecimal(qty));
        return request;
    }

    private void insertExtraRow(UUID parent, UUID component) {
        fixture.insertBom(parent, component, "1");
    }

    /** 单据号按登记格式(前缀 + 日期 + 6 位序号)；日期取 2020-01-01，不占今天的在线流水。 */
    private static String documentNo(String prefix) {
        return prefix + "20200101" + String.format("%06d",
                java.util.concurrent.ThreadLocalRandom.current().nextInt(1, 999_999));
    }

    private boolean deleted(UUID goods) {
        return Boolean.TRUE.equals(db.queryForObject("SELECT is_deleted FROM goods WHERE id = ?", Boolean.class, goods));
    }

    private long activeBomRows(UUID parent) {
        return db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id = ? AND NOT is_deleted",
                Long.class, parent);
    }

    private List<UUID> activeBomItemIds(UUID parent) {
        return db.queryForList("SELECT id FROM goods_bom_items WHERE goods_id = ? AND NOT is_deleted",
                UUID.class, parent);
    }

    private List<UUID> activeBomComponents(UUID parent) {
        return db.queryForList("SELECT component_goods_id FROM goods_bom_items WHERE goods_id = ? AND NOT is_deleted",
                UUID.class, parent);
    }

    private String code(UUID goods) {
        return db.queryForObject("SELECT code FROM goods WHERE id = ?", String.class, goods);
    }

    private String name(UUID goods) {
        return db.queryForObject("SELECT name FROM goods WHERE id = ?", String.class, goods);
    }

    private long version(UUID goods) {
        return db.queryForObject("SELECT version FROM goods WHERE id = ?", Long.class, goods);
    }

    private long auditRows(List<UUID> ids) {
        return db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type = 'goods' "
                        + "AND target_id = ANY(?::text[])", Long.class,
                (Object) ids.stream().map(UUID::toString).toArray(String[]::new));
    }

    private static void assertCheckViolation(Runnable write) {
        DataAccessException error = assertThrows(DataAccessException.class, write::run);
        Throwable root = error;
        while (root.getCause() != null) root = root.getCause();
        assertTrue(root instanceof SQLException sql && "23514".equals(sql.getSQLState()), root.toString());
    }

    private static void record(Map<String, Object> measurement) {
        try {
            Path output = Path.of(System.getProperty("uten.build.directory", "target"), "master-integrity.jsonl");
            Files.createDirectories(output.toAbsolutePath().getParent());
            Files.writeString(output, new com.fasterxml.jackson.databind.ObjectMapper()
                            .writeValueAsString(measurement) + System.lineSeparator(),
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (java.io.IOException error) {
            throw new AssertionError(error);
        }
    }
}
