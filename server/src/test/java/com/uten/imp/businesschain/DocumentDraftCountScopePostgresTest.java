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

import org.springframework.test.util.ReflectionTestUtils;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
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
    @Autowired
    com.uten.imp.features.documents.DocumentStatusCountQueryService statusCounts;
    @Autowired
    com.uten.imp.features.sales.shipment.SalesShipmentService shipmentService;
    @Autowired
    com.uten.imp.features.common.taskclaim.TaskClaimService reviewClaims;

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

        // 本类不带 @Transactional，和同容器的其它用例共用一个库；而归属谓词是
        // 「owner IS NULL OR owner IN (:owners)」——无归属单据对所有人可见（全平台读口径，
        // 见 DocumentAccessPolicy.nativeReadScope）。别的用例留下的无主草稿会被合法地数进来，
        // 所以这里断言**增量**而不是绝对值：增量才是「本人归属收敛」这条不变量本身。
        fixture.loginAs(sellerA);
        DraftCountsResponse baseA = drafts.counts();
        fixture.loginAs(sellerB);
        DraftCountsResponse baseB = drafts.counts();

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
        assertEquals(2, forA.salesOrder() - baseA.salesOrder(),
                "只数本人待自审草稿：财务驳回单已在 REJECTED 桶计数，已审单不是草稿；"
                        + "B 的那张也不能落到 A 头上");
        assertEquals(1, forA.purchaseOrder() - baseA.purchaseOrder(), "maker_id 归属列同样按本人收敛");
        assertEquals(0, forA.stockDocument(), "没有 stock_doc:view 权限时固定为 0（与库里有多少无关）");
        assertEquals(0, forA.financeReceipt(), "没有 finance_receipt:view 权限时固定为 0");

        fixture.loginAs(sellerB);
        DraftCountsResponse forB = drafts.counts();
        assertEquals(1, forB.salesOrder() - baseB.salesOrder(), "B 看不到 A 的 3 张草稿");
        assertEquals(0, forB.purchaseOrder(), "B 没有 purchase_order:view，权限自卫直接 0 不查库");
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

        // 同上：共用库 + 无主单据全员可见，故切片计数也只断言增量。
        fixture.loginAs(keeper);
        DraftCountsResponse base = drafts.counts();

        // 本人：2 张调拨草稿 + 1 张盘点草稿 + 1 张已审调拨（不是草稿）。
        insertStockDocument("TRANSFER", docNo("CB", seq + 1), keeperEmployee, (short) 0);
        insertStockDocument("TRANSFER", docNo("CB", seq + 2), keeperEmployee, (short) 0);
        insertStockDocument("CHECK", docNo("PQ", seq + 3), keeperEmployee, (short) 0);
        insertStockDocument("TRANSFER", docNo("CB", seq + 4), keeperEmployee, (short) 1);

        fixture.loginAs(keeper);
        DraftCountsResponse counts = drafts.counts();

        assertEquals(2, counts.stockTransfer() - base.stockTransfer(),
                "调拨切片只数 doc_type=TRANSFER 的草稿");
        assertEquals(1, counts.stockCheck() - base.stockCheck(),
                "盘点切片只数 doc_type=CHECK 的草稿");
        assertTrue(counts.stockDocument() >= counts.stockTransfer() + counts.stockCheck(),
                "两个切片之和不得超过整表合计（切片必须是合计的子集）");
    }

    /**
     * 采购订货财务退回件(最新 case=REJECTED)不再算草稿(2026-09-21 用户口径: 财务退回件有自己的
     * 红徽章分段, 不能放在草稿里); 分段计数把它归到 FINANCE_REJECTED 桶, 退回后又有更新一条 case
     * 覆盖(这里用 CANCELED 代表撤回重做)的单按最新 case 归回草稿, 与草稿计数同一口径.
     * PENDING/APPROVED case 受商业快照守卫(V518)约束须带完整明细与金额, 不在本用例直插.
     */
    @Test
    void financeRejectedProcurementOrdersLeaveTheDraftBucketAndGetTheirOwnCount() {
        String tag = "DRAFTREJ" + UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        int seq = 100000 + new java.util.Random().nextInt(800000);
        var world = fixture.seedWorld(tag);
        UUID buyer = fixture.createUserWithPerms(world, "pb-" + tag, "purchase_order:view");
        UUID buyerEmployee = employeeOf(buyer);
        fixture.loginAs(buyer);
        DraftCountsResponse base = drafts.counts();
        java.util.Map<String, Long> baseCounts = statusCounts.counts("purchaseOrder", null, null);
        long baseRejected = statusCounts.financeRejectedCounts().get("purchaseOrder");
        UUID plainDraft = insertPurchaseOrderReturningId(docNo("CD", seq + 1), buyerEmployee);
        UUID rejected = insertPurchaseOrderReturningId(docNo("CD", seq + 2), buyerEmployee);
        UUID superseded = insertPurchaseOrderReturningId(docNo("CD", seq + 3), buyerEmployee);
        assertNotNull(plainDraft);
        insertApprovalCase(rejected, 1, "REJECTED", buyer, buyerEmployee);
        insertApprovalCase(superseded, 1, "REJECTED", buyer, buyerEmployee);
        insertApprovalCase(superseded, 2, "CANCELED", buyer, buyerEmployee);
        fixture.loginAs(buyer);
        assertEquals(2, drafts.counts().purchaseOrder() - base.purchaseOrder(),
                "没交过财务的 + 退回后已被更新 case 覆盖的算草稿; 最新 case 仍是 REJECTED 的不算");
        java.util.Map<String, Long> counts = statusCounts.counts("purchaseOrder", null, null);
        assertEquals(2, counts.get("DRAFT") - baseCounts.get("DRAFT"));
        assertEquals(0, counts.get("PENDING_FINANCE") - baseCounts.get("PENDING_FINANCE"));
        assertEquals(1, counts.get("FINANCE_REJECTED") - baseCounts.get("FINANCE_REJECTED"),
                "只有最新 case 仍是 REJECTED 的那张算财务已退回");
        assertEquals(1, statusCounts.financeRejectedCounts().get("purchaseOrder") - baseRejected,
                "hub 卡「草稿 + 财务已退回」用的退回数与分桶同源");
    }

    /**
     * 销售出货草稿只数「销售尚未确认」的两审草稿: 提交财审后不再是草稿(PENDING_FINANCE 桶),
     * 财务退回后归 FINANCE_REJECTED 桶并计入「财务已退回」张数——用户原话「财务退回...会放在草稿里面」
     * 就是此前 status=0 裸口径把这两档都算成草稿. 走真实服务链(创建 → 销售确认 → 财务退回).
     */
    @Test
    void salesShipmentDraftsStopAtSalesConfirmationAndFinanceRejectionGetsItsOwnBucket() {
        String tag = "DRAFTSHP" + UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        var world = fixture.seedWorld(tag);
        fixture.loginAs(world.superAdminUserId());
        UUID seller = fixture.createUserWithPerms(world, "ss-" + tag,
                "sales_shipment:view", "sales_other_shipment:view", "sales_other_shipment:create",
                "sales_other_shipment:edit", "sales_other_shipment:approve", "sales_other_shipment:delete",
                "sales_order:price:view", "client:view", "notice:read");
        UUID finance = fixture.createUserWithPerms(world, "sf-" + tag, "sales_shipment_finance:view", "sales_shipment_finance:approve", "sales_shipment_finance:reject", "sales_shipment_finance:reverse", "notice:read");
        db.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='DEPT_SALES' AND NOT is_deleted) WHERE id=?",
                employeeOf(seller));
        db.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='DEPT_FIN' AND NOT is_deleted) WHERE id=?",
                employeeOf(finance));
        db.update("UPDATE clients SET owner_employee_id=? WHERE id=?", employeeOf(seller), world.clientId());

        fixture.loginAs(seller);
        long baseDrafts = drafts.counts().salesShipment();
        java.util.Map<String, Long> baseCounts = statusCounts.counts("salesShipment", null, null);
        long baseRejected = statusCounts.financeRejectedCounts().get("salesShipment");
        long baseDirectRejected = statusCounts.counts("salesShipment", "DIRECT_CUSTOMER", null).get("FINANCE_REJECTED");
        com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest request =
                ReflectionTestUtils.invokeMethod(fixture, "directCustomerShipmentRequest", world, "FREE", "1");
        assertNotNull(request);
        UUID id = shipmentService.create(request).getId();
        assertEquals(1, drafts.counts().salesShipment() - baseDrafts, "销售未确认: 是草稿");
        assertEquals(1, statusCounts.counts("salesShipment", null, null).get("DRAFT") - baseCounts.get("DRAFT"));

        shipmentService.confirmSales(id, 0L);
        assertEquals(0, drafts.counts().salesShipment() - baseDrafts, "已提交财审: 不再是草稿");
        java.util.Map<String, Long> pending = statusCounts.counts("salesShipment", null, null);
        assertEquals(0, pending.get("DRAFT") - baseCounts.get("DRAFT"));
        assertEquals(1, pending.get("PENDING_FINANCE") - baseCounts.get("PENDING_FINANCE"));

        fixture.loginAs(finance);
        var claim = reviewClaims.claim("SALES_SHIPMENT_FINANCE_AUDIT", id.toString());
        var info = shipmentService.financeAuditInfo(id);
        shipmentService.financeAuditReject(id, new com.uten.imp.features.sales.shipment.dto.ShipmentFinanceDecisionRequest(
                0L, info.get("contentHash").toString(), claim.claimId(), "请补充准确收货地址"));

        fixture.loginAs(seller);
        assertEquals(0, drafts.counts().salesShipment() - baseDrafts, "财务退回件不是草稿, 有自己的段");
        java.util.Map<String, Long> rejected = statusCounts.counts("salesShipment", null, null);
        assertEquals(0, rejected.get("PENDING_FINANCE") - baseCounts.get("PENDING_FINANCE"));
        assertEquals(1, rejected.get("FINANCE_REJECTED") - baseCounts.get("FINANCE_REJECTED"));
        assertEquals(1, statusCounts.financeRejectedCounts().get("salesShipment") - baseRejected,
                "hub 卡「草稿 + 财务已退回」与销售待办用的退回数与分桶同源");
        // 客户零星发货列表的切片只数 DIRECT_CUSTOMER, 这张单正是该类型.
        assertEquals(1, statusCounts.counts("salesShipment", "DIRECT_CUSTOMER", null).get("FINANCE_REJECTED")
                - baseDirectRejected, "DIRECT_CUSTOMER 切片包含本单");
    }

    private UUID insertPurchaseOrderReturningId(String billNo, UUID makerId) {
        insertPurchaseOrder(billNo, makerId, (short) 0);
        return db.queryForObject("select id from purchase_orders where bill_no = ?", UUID.class, billNo);
    }

    /** 财务审批 case: REJECTED 必须带原因与决定人/时间(表 CHECK), PENDING 三者皆空. */
    private void insertApprovalCase(UUID orderId, int attempt, String status, UUID userId, UUID employeeId) {
        boolean decided = "REJECTED".equals(status) || "APPROVED".equals(status);
        // V691 起提交快照必须带明细(与真实提交同构), 用共用夹具按订单当前内容生成。
        String submission = db.execute((org.springframework.jdbc.core.ConnectionCallback<String>) connection ->
                com.uten.imp.support.ProcurementApprovalFixtureSupport.submittedSnapshot(
                        connection, "PURCHASE", orderId));
        db.update("""
                insert into procurement_order_approval_cases(
                    id, order_type, order_id, attempt, bill_no_snapshot, submission_snapshot, snapshot_hash,
                    submitted_by_user_id, submitted_by_employee_id, status, rejection_reason,
                    decided_at, decided_by_user_id, decided_by_employee_id)
                values (gen_random_uuid(), 'PURCHASE', ?, ?, 'CD-SNAPSHOT', CAST(? AS jsonb), 'snapshot-hash',
                        ?, ?, ?, ?, ?, ?, ?)
                """, orderId, attempt, submission, userId, employeeId, status,
                "REJECTED".equals(status) ? "test rejection" : null,
                decided ? java.time.OffsetDateTime.now() : null,
                decided ? userId : null,
                decided ? employeeId : null);
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
