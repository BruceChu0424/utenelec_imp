package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class CrossAnalysisReallocationWorkflowContractTest {

    private static final Path REALLOCATION = Path.of(
            "src/main/java/com/uten/imp/features/production/analysis/"
                    + "MaterialStockReallocationService.java");
    private static final Path COMMAND = Path.of(
            "src/main/java/com/uten/imp/features/production/analysis/"
                    + "MaterialAnalysisCommandService.java");
    private static final Path ENTITLEMENT = Path.of(
            "src/main/java/com/uten/imp/features/production/analysis/"
                    + "PreplanStockEntitlementService.java");
    private static final Path PEGGING = Path.of(
            "src/main/java/com/uten/imp/features/production/analysis/"
                    + "PreplanAnalysisStockPegService.java");
    private static final Path PACKAGE_COMMAND = Path.of(
            "src/main/java/com/uten/imp/features/production/mrp/"
                    + "ProductionExecutionPackageCommandService.java");
    private static final Path FULFILLMENT = Path.of(
            "src/main/java/com/uten/imp/features/production/fulfillment/"
                    + "ProductionFulfillmentLedgerService.java");

    @Test
    void explicitReallocationLocksInventoryBeforeBothHeadersAndChecksDualCasScope()
            throws Exception {
        String source = compact(REALLOCATION);

        assertThat(source.indexOf("inventorylock.lock(new inventorykey"))
                .isPositive()
                .isLessThan(source.indexOf("map<uuid, materialanalysisservice.analysisheader> headers = lockheaders"));
        assertThat(occurrences(source, "access.requirewritable(headers.get(")).isGreaterThanOrEqualTo(2);
        assertThat(source).contains(
                "analysisservice.requirecurrent(headers.get(sourceanalysisid)");
        assertThat(source).contains(
                "analysisservice.requirecurrent(headers.get(request.targetanalysisid())");
        assertThat(source).contains("同一幂等键已用于不同让料请求");
        assertThat(source).contains("同仓库、同货品、同颜色和同基本单位");
    }

    @Test
    void manualSourceUsesOriginTerminalLineageAndPriorityNeverScansFirmPegs()
            throws Exception {
        String entitlement = compact(ENTITLEMENT);
        String reallocation = compact(REALLOCATION);

        assertThat(entitlement)
                .contains("with recursive entitlement_lineage as")
                .contains("current_positive.event_type in ( 'restore', 'make_delegate_in')")
                .contains("counter_negative.source_entitlement_event_id")
                .contains("positive.event_type in ('origin_iqc', 'origin_make')")
                .contains("lineage.event_type in ( 'reallocate_in', 'priority_in')");
        assertThat(reallocation).contains(
                "(from_analysis_id = :analysisid and from_analysis_material_id = :materialid)");
        assertThat(reallocation).contains(
                "(to_analysis_id = :analysisid and to_analysis_material_id = :materialid)");
        assertThat(reallocation).contains("order by created_at, id for update");
        assertThat(reallocation).doesNotContain(
                "from preplan_analysis_stock_exact_pegs where goods_id");
        assertThat(reallocation).contains("priority_out", "priority_in");
        assertThat(reallocation).contains("appendprioritysatisfiedinplace(");
    }

    @Test
    void onlyNewIqcOrMakeOriginInvokesPriorityHookInSameServiceTransaction()
            throws Exception {
        String pegging = compact(PEGGING);

        assertThat(pegging).contains("entitlement.appendoriginiqc(");
        assertThat(pegging).contains("entitlement.appendoriginmake(");
        assertThat(occurrences(pegging,
                "hook -> hook.applypriorityfororiginevent(origineventid)"))
                .isGreaterThanOrEqualTo(1);
        assertThat(pegging).contains("if (origin.inserted())");
        assertThat(occurrences(pegging, "applyoriginpriority(origin);"))
                .isGreaterThanOrEqualTo(2);
    }

    @Test
    void ReadyTransferIsPreparedBeforeAllocationThenFormalizedAndCancellationRestores()
            throws Exception {
        String command = compact(PACKAGE_COMMAND);
        String fulfillment = compact(FULFILLMENT);

        int prepare = command.indexOf("preplananalysispeg.transfertoplandemands(");
        int allocate = command.indexOf("readyallocation readyallocation = allocateready(");
        int formalize = command.indexOf("preplananalysispeg.formalizeplandemandtransfers(");
        assertThat(prepare).isPositive().isLessThan(allocate);
        assertThat(allocate).isLessThan(formalize);
        assertThat(fulfillment).contains("preplananalysispeg.restoreplandemandtransfers(");
        assertThat(fulfillment).contains("stockallocation.releasebydemands(");
    }

    @Test
    void wholeAnalysisCancellationPreservesDoneActionsAndPassesReleaseIdempotency()
            throws Exception {
        String command = compact(COMMAND);

        assertThat(command).contains(
                "where analysis_id = :id and status in ('open','created','in_progress')");
        assertThat(command).doesNotContain(
                "where analysis_id = :id and status <> 'cancelled' order by created_at desc");
        assertThat(command).contains(
                "analysispeg.releaseforanalysis( analysisid, request.reason(), request.idempotencykey())");
    }

    private static String compact(Path path) throws Exception {
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("//[^\\r\\n]*", " ")
                .replaceAll("/\\*.*?\\*/", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }

    private static int occurrences(String value, String needle) {
        int count = 0;
        int offset = 0;
        while ((offset = value.indexOf(needle, offset)) >= 0) {
            count++;
            offset += needle.length();
        }
        return count;
    }
}
