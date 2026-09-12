package com.uten.imp.features.production.quality;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.dailyreport.ProductionFqcFinishedInboundService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcPassAllTransactionContractTest {

    @Test
    void secondItemFailureCannotCommitTheFirstItemSideEffects()
            throws Exception {
        var batch = ProductionFqcInspectionService.class.getMethod(
                "passAll", PassAllBatchRequest.class);
        Transactional transaction = batch.getAnnotation(Transactional.class);
        assertThat(transaction).isNotNull();
        assertThat(transaction.propagation()).isEqualTo(Propagation.REQUIRED);
        assertThat(ApiException.class).isAssignableTo(RuntimeException.class);

        var release = ProductionFqcInspectionService.class.getMethod(
                "allocateReleasedQuantity",
                UUID.class, UUID.class, BigDecimal.class, String.class);
        assertThat(release.getAnnotation(Transactional.class).propagation())
                .isEqualTo(Propagation.MANDATORY);
        var draft = ProductionFqcFinishedInboundService.class.getMethod(
                "createReleasedDraft",
                com.uten.imp.application.port.ProductionFinishedInboundReleasePort
                        .ReleaseRequest.class);
        assertThat(draft.getAnnotation(Transactional.class).propagation())
                .isEqualTo(Propagation.MANDATORY);

        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcInspectionService.java"));
        String batchBody = source.substring(
                source.indexOf("public PassAllBatchResult passAll("),
                source.indexOf("private DecisionResult decideLocked("));
        assertThat(batchBody)
                .contains("lockPassAllDecisionDimensions(")
                .contains("requireActiveDecisionRow(locked.get(inspectionId))")
                .contains("DecisionWrite decision = recordDecisionLocked(")
                .contains("INSERT INTO production_fqc_pass_all_batch_items")
                .contains("detailViews(normalized.inspectionIds())")
                .doesNotContain("detailInternal(")
                .doesNotContain("catch (")
                .doesNotContain("REQUIRES_NEW");
        assertThat(batchBody.indexOf("requireActiveDecisionRow"))
                .isLessThan(batchBody.indexOf("DecisionWrite decision = recordDecisionLocked"));
        assertThat(batchBody.indexOf("INSERT INTO production_fqc_pass_all_batch_items"))
                .isLessThan(batchBody.indexOf("detailViews(normalized.inspectionIds())"));
        assertThat(batchBody.indexOf("mutationFootprint.beginInspections("))
                .isGreaterThan(0).isLessThan(batchBody.indexOf("findPassAllBatch("));
        assertThat(batchBody.indexOf("findPassAllBatch("))
                .isLessThan(batchBody.indexOf("lockPassAllDecisionDimensions("));
        assertThat(batchBody.indexOf("lockPassAllDecisionDimensions("))
                .isLessThan(batchBody.indexOf("sourceGuard.verifyUnchanged();"));
        assertThat(batchBody.indexOf("sourceGuard.verifyUnchanged();"))
                .isLessThan(batchBody.indexOf("claimPassAllBatch("));
    }

    @Test
    void afterCommonPrefixBatchLocksAllInspectionsThenSharedExecutionRowsInStableOrder()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcInspectionService.java"));
        String locks = source.substring(
                source.indexOf("private Map<UUID, Object[]> lockPassAllDecisionDimensions("),
                source.indexOf("private static void requireActiveDecisionRow("));
        assertThat(locks)
                .contains("ORDER BY id")
                .contains("FOR UPDATE")
                .contains(".sorted(UUID_ORDER)");
        assertThat(locks.indexOf("FOR UPDATE"))
                .isLessThan(locks.indexOf(
                        "lockOne(\"production_execution_segments\""));
        assertThat(locks.indexOf(
                "lockOne(\"production_execution_segments\""))
                .isLessThan(locks.indexOf(
                        "lockOne(\"production_plan_items\""));
    }
}
