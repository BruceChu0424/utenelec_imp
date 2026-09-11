package com.uten.imp.features.documents;

import com.uten.imp.features.documents.DocumentDraftCountQueryService.DraftSource;
import org.junit.jupiter.api.Test;

import java.lang.reflect.RecordComponent;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 草稿计数 SQL 形状契约：每类单据都必须是
 * {@code count(*) ... is_deleted = false AND status = 0 AND <归属谓词>}，
 * 且响应字段与查询顺序一一对应。
 */
class DocumentDraftCountSqlContractTest {

    @Test
    void everySourceCountsOnlyLiveDraftsWithinTheObjectScope() {
        for (DraftSource source : DocumentDraftCountQueryService.SOURCES) {
            String sql = DocumentDraftCountQueryService.countSql(source, "1=1");

            assertThat(sql)
                    .as("单据类型 %s 的草稿 SQL", source.table())
                    .startsWith("SELECT count(*) FROM " + source.table() + " o WHERE ")
                    .contains("o.is_deleted = false")
                    .contains("o.status = 0")
                    .endsWith("AND 1=1");
            // 红冲(-1)/已审(1) 不是草稿：等号口径不能退化成 <> 或 <=。
            assertThat(sql).doesNotContain("o.status <>").doesNotContain("o.status <=");
        }
    }

    @Test
    void ownerScopePredicateIsAppendedVerbatimWithBoundParameterOnly() {
        String sql = DocumentDraftCountQueryService.countSql(
                DocumentDraftCountQueryService.PURCHASE_ORDER,
                "(o.maker_id IS NULL OR o.maker_id IN (:draftOwners))");

        assertThat(sql).isEqualTo(
                "SELECT count(*) FROM purchase_orders o WHERE o.is_deleted = false"
                        + " AND o.status = 0"
                        + " AND (o.maker_id IS NULL OR o.maker_id IN (:draftOwners))");
        // 归属集合只能经具名参数进入 SQL，不得被拼成字面量。
        assertThat(sql).doesNotContain("'");
    }

    /**
     * 销售订货单去重：财务驳回单同样是 status=0，但已计入销售关注徽章的 REJECTED 桶。
     * 若草稿桶也数它就会双计，故这里必须排除（G5-flow 口径）。
     */
    @Test
    void salesOrderDraftsExcludeFinanceRejectedToAvoidDoubleCounting() {
        String sql = DocumentDraftCountQueryService.countSql(
                DocumentDraftCountQueryService.SALES_ORDER, "1=1");

        assertThat(sql).contains("o.finance_rejected = false");
        assertThat(DocumentDraftCountQueryService.SALES_ORDER.extraPredicate())
                .isEqualTo("o.finance_rejected = false");
    }

    /**
     * 附加谓词是白名单：只有销售订货单（去重）与仓库调拨/盘点（同表切片）才允许带，
     * 其余类型必须是裸口径，免得有人把业务过滤悄悄塞进草稿计数。
     */
    @Test
    void onlyDeclaredSourcesCarryAnExtraPredicate() {
        for (DraftSource source : DocumentDraftCountQueryService.SOURCES) {
            if (source == DocumentDraftCountQueryService.SALES_ORDER
                    || source == DocumentDraftCountQueryService.STOCK_TRANSFER
                    || source == DocumentDraftCountQueryService.STOCK_CHECK) {
                continue;
            }
            assertThat(source.extraPredicate())
                    .as("单据类型 %s 不应有附加谓词", source.table())
                    .isNull();
        }
    }

    /**
     * 仓库调拨/盘点是 {@code stock_documents} 的 doc_type 切片：两片互斥（不会把同一张
     * 单据数两遍），且都是 {@code stockDocument} 合计的子集——前端只能择一展示。
     */
    @Test
    void stockDocumentSlicesAreMutuallyExclusiveSubsetsOfTheAggregate() {
        assertThat(DocumentDraftCountQueryService.STOCK_TRANSFER.table())
                .isEqualTo(DocumentDraftCountQueryService.STOCK_DOCUMENT.table());
        assertThat(DocumentDraftCountQueryService.STOCK_CHECK.table())
                .isEqualTo(DocumentDraftCountQueryService.STOCK_DOCUMENT.table());
        assertThat(DocumentDraftCountQueryService.STOCK_TRANSFER.extraPredicate())
                .isEqualTo("o.doc_type = 'TRANSFER'");
        assertThat(DocumentDraftCountQueryService.STOCK_CHECK.extraPredicate())
                .isEqualTo("o.doc_type = 'CHECK'");
        // 切片与合计共用权限/归属口径，切片不得偷偷放宽可见性。
        assertThat(DocumentDraftCountQueryService.STOCK_TRANSFER.viewAuthority())
                .isEqualTo(DocumentDraftCountQueryService.STOCK_DOCUMENT.viewAuthority());
        assertThat(DocumentDraftCountQueryService.STOCK_CHECK.ownerColumn())
                .isEqualTo(DocumentDraftCountQueryService.STOCK_DOCUMENT.ownerColumn());
    }

    @Test
    void sourceOrderMatchesTheResponseRecordComponents() {
        List<String> sourceTables = DocumentDraftCountQueryService.SOURCES.stream()
                .map(DraftSource::table)
                .toList();
        List<String> responseFields = Arrays
                .stream(DraftCountsResponse.class.getRecordComponents())
                .map(RecordComponent::getName)
                .toList();

        assertThat(sourceTables).hasSize(21);
        assertThat(responseFields).containsExactly(
                "salesOrder", "salesShipment", "salesReturn", "salesQuote",
                "purchaseOrder", "subcontractOrder", "stockDocument",
                "productionPlan", "productionDailyReport",
                "financeReceipt", "financePayment", "financeExpense",
                "financeOtherIncome", "financeBankTransfer",
                "purchaseReceipt", "purchaseReturn",
                "subcontractReturn", "subcontractMaterialReturn", "subcontractWaste",
                "stockTransfer", "stockCheck");
        assertThat(sourceTables).containsExactly(
                "sales_orders", "sales_shipments", "sales_returns", "sales_quotes",
                "purchase_orders", "subcontract_orders", "stock_documents",
                "production_plans", "production_daily_reports",
                "finance_receipts", "finance_payments", "finance_expenses",
                "finance_other_incomes", "finance_bank_transfers",
                "purchase_receipts", "purchase_returns",
                "subcontract_returns", "subcontract_material_returns", "subcontract_wastes",
                "stock_documents", "stock_documents");
    }

    /** 每类单据都要声明 {@code *:view} 权限码与归属 scope，否则权限自卫会失效。 */
    @Test
    void everySourceDeclaresAViewAuthorityAndAnOwnerScope() {
        for (DraftSource source : DocumentDraftCountQueryService.SOURCES) {
            assertThat(source.viewAuthority()).endsWith(":view");
            assertThat(source.viewAllAuthority()).endsWith(":view:all");
            assertThat(source.scope()).isNotBlank();
            assertThat(source.ownerColumn()).startsWith("o.");
        }
        // 销售 4 类共用 sales 归属范围；生产计划与日报共用 production_plan（各自 :view 独立）。
        assertThat(DocumentDraftCountQueryService.SALES_QUOTE.ownerColumn()).isEqualTo("o.maker_id");
        assertThat(DocumentDraftCountQueryService.SALES_ORDER.ownerColumn())
                .isEqualTo("o.owner_employee_id");
        assertThat(DocumentDraftCountQueryService.PRODUCTION_DAILY_REPORT.scope())
                .isEqualTo(DocumentDraftCountQueryService.PRODUCTION_PLAN.scope());
        assertThat(DocumentDraftCountQueryService.PRODUCTION_DAILY_REPORT.viewAuthority())
                .isEqualTo("production_daily_report:view");
    }

    /**
     * 接口契约：只读 GET + 仅要求已登录（真正的可见性在服务里按 {@code *:view} + 归属范围收敛）。
     */
    @Test
    void controllerExposesAnAuthenticatedReadOnlyEndpoint() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/documents/"
                        + "DocumentDraftCountController.java"), StandardCharsets.UTF_8);

        assertThat(source).contains("@RequestMapping(\"/api/documents\")");
        assertThat(source).contains("@GetMapping(\"/drafts/count\")");
        assertThat(source).contains("@PreAuthorize(\"isAuthenticated()\")");
        assertThat(source).doesNotContain("@PostMapping").doesNotContain("@DeleteMapping");
    }

    /**
     * 归属范围适配器不得引入 documents → 业务 feature 的依赖边（ADR-017）：
     * 整个包只依赖 {@code com.uten.imp.security} 基座。
     */
    @Test
    void draftCountPackageDoesNotImportBusinessFeatures() throws Exception {
        for (String file : List.of(
                "DocumentDraftCountController.java",
                "DocumentDraftCountQueryService.java",
                "DraftScopeAccessPolicy.java",
                "DraftCountsResponse.java")) {
            String source = Files.readString(
                    Path.of("src/main/java/com/uten/imp/features/documents/" + file),
                    StandardCharsets.UTF_8);
            assertThat(source)
                    .as("%s 不得 import 其它 feature", file)
                    .doesNotContain("import com.uten.imp.features.");
        }
    }
}
