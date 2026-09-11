package com.uten.imp.businesschain;

import com.uten.imp.features.documents.DocumentDraftCountQueryService;
import com.uten.imp.features.documents.DraftCountsResponse;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 草稿计数端点（{@code GET /api/documents/drafts/count}）的真实库口径验证：
 * 对象级归属隔离、{@code *:view} 权限自卫、财务驳回草稿不双计，以及 21 条 count SQL
 * 能在真实迁移后的 schema 上跑通（表名/列名打错会立刻炸）。
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>，否则本类 SKIP 且 surefire exit 0（假绿）。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class DocumentDraftCountScopePostgresTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired
    AutowireCapableBeanFactory beans;
    @Autowired
    JdbcTemplate db;
    @Autowired
    DocumentDraftCountQueryService drafts;

    private FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @Test
    void draftsAreCountedPerOwnerAndOnlyForDocumentTypesTheUserCanView() {
        String tag = "DRAFTCNT" + UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        int seq = 100000 + new java.util.Random().nextInt(800000);
        var world = fixture.seedWorld(tag);

        UUID sellerA = fixture.createUserWithPerms(world, "sa-" + tag,
                "sales_order:view", "purchase_order:view");
        UUID sellerB = fixture.createUserWithPerms(world, "sb-" + tag, "sales_order:view");
        UUID employeeA = employeeOf(sellerA);
        UUID employeeB = employeeOf(sellerB);

        // A：2 张自审草稿 + 1 张财务驳回草稿 + 1 张已审；B：1 张草稿。
        insertSalesOrder(docNo("XD", seq + 1), world.clientId(), employeeA, (short) 0, false);
        insertSalesOrder(docNo("XD", seq + 2), world.clientId(), employeeA, (short) 0, false);
        insertSalesOrder(docNo("XD", seq + 3), world.clientId(), employeeA, (short) 0, true);
        insertSalesOrder(docNo("XD", seq + 4), world.clientId(), employeeA, (short) 1, false);
        insertSalesOrder(docNo("XD", seq + 5), world.clientId(), employeeB, (short) 0, false);
        // 采购草稿归属 A（maker_id 归属列的另一种形状）。
        insertPurchaseOrder(docNo("CD", seq + 6), employeeA, (short) 0);

        fixture.loginAs(sellerA);
        DraftCountsResponse forA = drafts.counts();
        assertEquals(2, forA.salesOrder(),
                "只数本人待自审草稿：财务驳回单已在 REJECTED 桶计数，已审单不是草稿");
        assertEquals(1, forA.purchaseOrder(), "maker_id 归属列同样按本人收敛");
        assertEquals(0, forA.stockDocument(), "没有 stock_doc:view 权限时固定为 0");
        assertEquals(0, forA.financeReceipt(), "没有 finance_receipt:view 权限时固定为 0");

        fixture.loginAs(sellerB);
        DraftCountsResponse forB = drafts.counts();
        assertEquals(1, forB.salesOrder(), "B 看不到 A 的草稿");
        assertEquals(0, forB.purchaseOrder(), "B 没有 purchase_order:view");
    }

    /** 超管走 seeAll 分支（谓词 {@code 1=1}），一次把 21 条 count 都在真实 schema 上执行一遍。 */
    @Test
    void superAdminExecutesEveryDeclaredCountAgainstTheMigratedSchema() {
        String tag = "DRAFTALL" + UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        int seq = 100000 + new java.util.Random().nextInt(800000);
        var world = fixture.seedWorld(tag);
        insertSalesOrder(docNo("XD", seq + 7), world.clientId(), world.employeeId(), (short) 0, false);

        fixture.loginAs(world.superAdminUserId());
        DraftCountsResponse counts = drafts.counts();

        // 超管不受归属限制，至少数到刚插入的这张草稿；其余各条只要能跑通且非负。
        assertTrue(counts.salesOrder() >= 1, "超管应看到全量草稿");
        for (var component : DraftCountsResponse.class.getRecordComponents()) {
            assertTrue(readCount(counts, component.getName()) >= 0,
                    component.getName() + " 应返回非负计数");
        }
    }

    /**
     * 仓库调拨 / 盘点是同一张 {@code stock_documents} 的 doc_type 切片：
     * 两个切片互斥、之和 ≤ 整表合计。仓库 hub 两张卡各用一个切片，
     * 因此不能出现「一张单被两张卡各数一次」。
     */
    @Test
    void stockDocumentSlicesSplitTheAggregateWithoutDoubleCounting() {
        String tag = "DRAFTSTK" + UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        int seq = 100000 + new java.util.Random().nextInt(800000);
        var world = fixture.seedWorld(tag);

        UUID keeper = fixture.createUserWithPerms(world, "wk-" + tag, "stock_doc:view");
        UUID keeperEmployee = employeeOf(keeper);

        // 本人：2 张调拨草稿 + 1 张盘点草稿 + 1 张已审调拨（不是草稿）。
        insertStockDocument("TRANSFER", docNo("CB", seq + 1), keeperEmployee, (short) 0);
        insertStockDocument("TRANSFER", docNo("CB", seq + 2), keeperEmployee, (short) 0);
        insertStockDocument("CHECK", docNo("PQ", seq + 3), keeperEmployee, (short) 0);
        insertStockDocument("TRANSFER", docNo("CB", seq + 4), keeperEmployee, (short) 1);

        fixture.loginAs(keeper);
        DraftCountsResponse counts = drafts.counts();

        assertEquals(2, counts.stockTransfer(), "调拨切片只数 doc_type=TRANSFER 的草稿");
        assertEquals(1, counts.stockCheck(), "盘点切片只数 doc_type=CHECK 的草稿");
        assertTrue(counts.stockDocument() >= counts.stockTransfer() + counts.stockCheck(),
                "两个切片之和不得超过整表合计（切片必须是合计的子集）");
    }

    private static long readCount(DraftCountsResponse counts, String field) {
        try {
            return (long) DraftCountsResponse.class.getMethod(field).invoke(counts);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException(e);
        }
    }

    /** V279 单号注册表：DOCUMENT 单号必须是 前缀 + YYYYMMDD + 6 位序号，否则触发器拒绝。 */
    private String docNo(String prefix, int seq) {
        return "%s%s%06d".formatted(
                prefix,
                java.time.LocalDate.now().format(
                        java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd")),
                seq);
    }

    private UUID employeeOf(UUID userId) {
        return db.queryForObject(
                "select employee_id from users where id = ?", UUID.class, userId);
    }

    private void insertSalesOrder(String billNo, UUID clientId, UUID ownerEmployeeId,
                                  short status, boolean financeRejected) {
        db.update("""
                insert into sales_orders(id, bill_no, bill_date, client_id, owner_employee_id,
                                         maker_id, status, finance_rejected)
                values (gen_random_uuid(), ?, current_date, ?, ?, ?, ?, ?)
                """, billNo, clientId, ownerEmployeeId, ownerEmployeeId, status, financeRejected);
    }

    private void insertPurchaseOrder(String billNo, UUID makerId, short status) {
        db.update("""
                insert into purchase_orders(id, bill_no, bill_date, maker_id, status)
                values (gen_random_uuid(), ?, current_date, ?, ?)
                """, billNo, makerId, status);
    }

    /** 单号前缀按 V279 注册表：TRANSFER=CB、CHECK=PQ（写错前缀触发器会拒绝）。 */
    private void insertStockDocument(String docType, String billNo, UUID makerId, short status) {
        db.update("""
                insert into stock_documents(id, doc_type, bill_no, bill_date, maker_id, status)
                values (gen_random_uuid(), ?, ?, current_date, ?, ?)
                """, docType, billNo, makerId, status);
    }
}
