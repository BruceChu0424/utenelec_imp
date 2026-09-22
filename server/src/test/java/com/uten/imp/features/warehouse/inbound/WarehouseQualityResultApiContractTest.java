package com.uten.imp.features.warehouse.inbound;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.lang.reflect.RecordComponent;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 品质部检查结果合并页（原 IQC 合格待入库 + IQC 不合格实物退回）的 API 契约：
 * 任一仓库视图权限可读、动作权限不放宽、响应无商业字段、预计到货不再展示等待品质行。
 */
class WarehouseQualityResultApiContractTest {

    private static final Set<String> COMMERCIAL_TOKENS = Set.of(
            "price", "amount", "cost", "currency", "exchange", "tax",
            "payable", "settlement", "credit");

    @Test
    void qualityResultContractsExposeNoCommercialField() {
        List<Class<?>> responseTypes = List.of(
                WarehouseQualityResultContracts.TaskSummary.class,
                WarehouseQualityResultContracts.TaskDetail.class,
                WarehouseQualityResultContracts.InspectionLineItem.class,
                WarehouseQualityResultContracts.RejectionCaseItem.class,
                ProcurementIqcStockInContracts.BatchConfirmEntryResult.class,
                ProcurementIqcStockInContracts.BatchConfirmResult.class);

        List<String> componentNames = responseTypes.stream()
                .flatMap(type -> Arrays.stream(type.getRecordComponents()))
                .map(RecordComponent::getName)
                .map(name -> name.toLowerCase(Locale.ROOT))
                .toList();
        assertThat(componentNames).noneMatch(this::containsCommercialToken);
    }

    @Test
    void qualityResultEndpointsAcceptEitherWarehouseViewAndKeepActionsExact()
            throws Exception {
        // ADR-017：仓库侧不 import finance——退回权限字面量内联，必须与权威定义一致。
        assertThat(WarehouseQualityResultPermissions.RETURN_VIEW)
                .isEqualTo(com.uten.imp.features.finance.payables.warehouse
                        .WarehouseIqcReturnPermissions.VIEW);
        assertThat(WarehouseQualityResultPermissions.RECORD_RETURN)
                .isEqualTo(com.uten.imp.features.finance.payables.warehouse
                        .WarehouseIqcReturnPermissions.RECORD_RETURN);

        RequestMapping mapping = WarehouseQualityResultController.class
                .getAnnotation(RequestMapping.class);
        assertThat(mapping.value()).containsExactly("/api/warehouse/quality-results");

        String anyView = WarehouseQualityResultController.class
                .getAnnotation(PreAuthorize.class).value();
        assertThat(anyView)
                .contains("warehouse_iqc_stock_in:view")
                .contains("warehouse_iqc_return:view")
                .contains(" or ");

        Method list = WarehouseQualityResultController.class.getDeclaredMethod(
                "list", String.class, String.class, String.class, LocalDate.class, LocalDate.class, int.class, int.class);
        Method detail = WarehouseQualityResultController.class.getDeclaredMethod(
                "detail", String.class, UUID.class);
        // 读接口只吃类级任一视图权限，方法级不得再叠加更严的口径。
        assertThat(list.getAnnotation(PreAuthorize.class)).isNull();
        assertThat(detail.getAnnotation(PreAuthorize.class)).isNull();

        // 批量入库仍走 IQC 待入库的 查看+确认 双权限，不因合并放宽。
        Method batchConfirm = ProcurementIqcStockInController.class.getDeclaredMethod(
                "batchConfirm",
                ProcurementIqcStockInContracts.BatchConfirmRequest.class);
        assertThat(batchConfirm.getAnnotation(PreAuthorize.class).value())
                .contains("warehouse_iqc_stock_in:view")
                .contains("warehouse_iqc_stock_in:confirm")
                .doesNotContain("warehouse_iqc_return:view")
                .doesNotContain("procurement_inspection:handle");
    }

    @Test
    void workStatusDerivationCoversAllFiveStatesInOneExpression() {
        // Java 侧（详情直查）必须覆盖五种状态，且与 SQL STATUS_CASE 分支同序：
        // 放行>0 → 部分或全部合格；退回>0 → 部分或需退回；未出结果 → 等待；否则完结。
        assertThat(WarehouseQualityResultService.deriveWorkStatus(
                2, 0, 0, 3, 0)).isEqualTo(WarehouseQualityResultService.ALL_PASSED);
        assertThat(WarehouseQualityResultService.deriveWorkStatus(
                1, 1, 0, 2, 0)).isEqualTo(WarehouseQualityResultService.PARTIAL_PASSED);
        assertThat(WarehouseQualityResultService.deriveWorkStatus(
                1, 0, 1, 2, 0)).isEqualTo(WarehouseQualityResultService.PARTIAL_PASSED);
        assertThat(WarehouseQualityResultService.deriveWorkStatus(
                0, 2, 0, 1, 1)).isEqualTo(WarehouseQualityResultService.PARTIAL_PASSED);
        assertThat(WarehouseQualityResultService.deriveWorkStatus(
                0, 2, 0, 0, 1)).isEqualTo(WarehouseQualityResultService.RETURN_REQUIRED);
        assertThat(WarehouseQualityResultService.deriveWorkStatus(
                0, 0, 2, 0, 0)).isEqualTo(WarehouseQualityResultService.WAITING_INSPECTION);
        assertThat(WarehouseQualityResultService.deriveWorkStatus(
                0, 0, 0, 1, 0)).isEqualTo(WarehouseQualityResultService.COMPLETED);

        String source = readSource(
                "WarehouseQualityResultService.java");
        // 同一 STATUS_CASE 常量被 列表 / 计数 / 状态分组 复用，口径不漂移。
        assertThat(source.indexOf("STATUS_CASE = \"\"\"")).isGreaterThanOrEqualTo(0);
        assertThat(countOccurrences(source, "STATUS_CASE")).isGreaterThanOrEqualTo(7);
        for (String status : Set.of(
                WarehouseQualityResultService.WAITING_INSPECTION,
                WarehouseQualityResultService.ALL_PASSED,
                WarehouseQualityResultService.PARTIAL_PASSED,
                WarehouseQualityResultService.RETURN_REQUIRED,
                WarehouseQualityResultService.COMPLETED)) {
            assertThat(source).contains("'" + status + "'");
        }
    }

    @Test
    void readPathScalesWithScopeAndIndexes() {
        String source = readSource(
                "WarehouseQualityResultService.java");
        // 聚合 CTE 先 JOIN 类型收窄后的 receipt_scope：筛选即收窄扫描面。
        assertThat(source)
                .contains("AND (:type = 'ALL' OR 'PURCHASE'::text = :type)")
                .contains("AND (:type = 'ALL' OR 'SUBCONTRACT'::text = :type)")
                .contains("JOIN receipt_scope scope");
        // 角标与页内分段同口径：复用聚合管线按 (类型, 状态) 分组，
        // 红黄两支分流在 Java 侧做，不在 SQL 里另起一套状态白名单。
        assertThat(source)
                .contains("public TypeCounts typeCounts()")
                .doesNotContain("IN ('ALL_PASSED','PARTIAL_PASSED','RETURN_REQUIRED')");
        // 列表不再为展示列做整库 stocked 聚合（历史直接在详情按单读取）。
        assertThat(source).doesNotContain("stocked_stat");
        assertThat(source)
                .doesNotContain("WITH event_stocked AS (")
                .contains("inspection.passed_base_qty > inspection.warehouse_stocked_base_qty")
                .contains("WHERE item.pass_event_id = event.id");
        // V448 索引迁移与查询形状一一对应。
        String migration = readMigration();
        assertThat(migration)
                .contains("idx_procurement_inspection_items_quality_verdict")
                .contains("idx_procurement_inspection_events_pending_release")
                .contains("idx_procurement_iqc_stock_in_item_event_qty")
                .contains("idx_procurement_iqc_stock_in_item_batch")
                .contains("idx_procurement_iqc_rejection_pending_return");
    }

    @Test
    void typeCountsSplitsOneAggregateIntoActionableAndInProgress() throws Exception {
        String source = readSource("WarehouseQualityResultService.java");
        // 红黄两支曾各走一个端点、各算各的：type-counts 刻意剔除「等待检查结果」，
        // 于是来源大类行上的黄徽章一进页面就蒸发。现在两支必须同出一次聚合。
        assertThat(source)
                .contains("public record TypeCounts(")
                .contains("public TypeCounts typeCounts()")
                .doesNotContain("pendingTypeCounts")
                .doesNotContain("countPending");
        assertThat(Arrays.stream(WarehouseQualityResultService.TypeCounts.class
                        .getRecordComponents())
                .map(RecordComponent::getName)
                .toList())
                .containsExactly("actionable", "inProgress");

        int signature = source.indexOf("public TypeCounts typeCounts()");
        String guards = source.substring(
                source.lastIndexOf("@Transactional", signature), signature);
        // 计数端点是只读聚合，且不得比列表/详情的任一视图权限更松。
        assertThat(guards)
                .contains("@Transactional(readOnly = true)")
                .contains("@PreAuthorize(");
        assertThat(WarehouseQualityResultService.class
                .getDeclaredMethod("typeCounts")
                .getAnnotation(PreAuthorize.class).value())
                .contains("warehouse_iqc_stock_in:view")
                .contains("warehouse_iqc_return:view");

        String body = source.substring(signature);
        body = body.substring(0, body.indexOf("\n    }"));
        // 只跑一次聚合、只读一次结果集：红黄同源是结构保证，不是两处写法碰巧一致。
        assertThat(countOccurrences(body, "aggregateQuery(")).isEqualTo(1);
        assertThat(countOccurrences(body, "getResultList()")).isEqualTo(1);
        // SELECT 与 GROUP BY 都用同一个 STATUS_CASE 常量，和页内分段同口径。
        assertThat(countOccurrences(body, "STATUS_CASE")).isEqualTo(2);
        // 分流口径：已完结两支都不数；等待检查结果只进黄色，其余三档只进红色。
        assertThat(body)
                .contains("if (COMPLETED.equals(workStatus)) {")
                .contains("continue;")
                .contains("WAITING_INSPECTION.equals(workStatus)")
                .contains("? inProgress : actionable")
                .doesNotContain("ALL_PASSED")
                .doesNotContain("PARTIAL_PASSED")
                .doesNotContain("RETURN_REQUIRED");
        // 两个 map 都预置全部来源键：缺键前端读出 null 而不是 0，分段会空着。
        assertThat(body)
                .contains("actionable.put(known, 0L)")
                .contains("inProgress.put(known, 0L)");

        // /count 已下线：红数字改由 actionable 之和派生，端点不再重复一份口径。
        assertThat(WarehouseQualityResultController.class.getDeclaredMethods())
                .noneMatch(method -> "count".equals(method.getName()));
        Method typeCounts = WarehouseQualityResultController.class
                .getDeclaredMethod("typeCounts");
        assertThat(typeCounts.getReturnType())
                .isEqualTo(WarehouseQualityResultService.TypeCounts.class);
        assertThat(typeCounts.getAnnotation(PreAuthorize.class)).isNull();
    }

    @Test
    void batchConfirmValidatesWholeSetBeforeExecutionAndRollsBackAtomically() {
        String source = readSource("ProcurementIqcStockInService.java");
        // 整批同事务：先全部规范化、按稳定顺序排序，任一冲突抛出即整批回滚。
        assertThat(source)
                .contains("public BatchConfirmResult batchConfirm(")
                .contains("批量入库必须包含 1 至 20 张收货单")
                .contains("批量入库明细总数必须在 1 至 300 条之间")
                .contains("批量入库中同一收货单只能出现一次")
                .contains("thenComparing(entry -> entry.receiptId().toString())");
        // 单张路径复用同一 confirmOne：幂等重放与职责分离校验不因批量绕过。
        assertThat(source).contains("private ConfirmResult confirmOne(");
        assertThat(source.indexOf("confirmOne(\n                    batch.type()"))
                .isGreaterThanOrEqualTo(0);
    }

    @Test
    void expectationsNoLongerListPurelyWaitingQualityTasks() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementArrivalControlService.java"),
                StandardCharsets.UTF_8);
        // 送检即移交品质：等待品质不再是本页可见理由，改由合并页跟踪。
        assertThat(source).doesNotContain("PENDING_INSPECTION_EXISTS = ");
        assertThat(source)
                .contains("private static String warehouseWorkRemaining()")
                .contains("draft_purchase_r.status = 0")
                .contains("draft_sub_r.status = 0")
                .contains("exc.status NOT IN ('CLOSED','CANCELED')");
        // 三个查询（列表 / 计数 / 类型计数）全部换用新口径。
        assertThat(countOccurrences(source, "warehouseWorkRemaining()"))
                .isGreaterThanOrEqualTo(4);
    }

    private static String readSource(String fileName) {
        try {
            // V607+ 重写后源码为 CRLF 行尾：统一行尾，多行锚点（confirmOne 调用形状）不受行尾差异影响。
            return Files.readString(Path.of(
                    "src/main/java/com/uten/imp/features/warehouse/inbound/"
                            + fileName),
                    StandardCharsets.UTF_8)
                    .replace("\r\n", "\n");
        } catch (Exception error) {
            throw new IllegalStateException(error);
        }
    }

    private static String readMigration() {
        try {
            return Files.readString(Path.of(
                    "src/main/resources/db/migration/"
                            + "V448__warehouse_quality_result_read_indexes.sql"),
                    StandardCharsets.UTF_8);
        } catch (Exception error) {
            throw new IllegalStateException(error);
        }
    }

    private static int countOccurrences(String haystack, String needle) {
        int count = 0;
        int index = 0;
        while ((index = haystack.indexOf(needle, index)) >= 0) {
            count++;
            index += needle.length();
        }
        return count;
    }

    private boolean containsCommercialToken(String fieldName) {
        return COMMERCIAL_TOKENS.stream().anyMatch(fieldName::contains);
    }
}
