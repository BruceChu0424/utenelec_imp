package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackage;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackageRepository;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.features.production.plan.ProductionPlanRepository;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProductionWorkCardServiceTest {

    @Test
    void rejectsMissingOrNonConfirmedPackageBeforeReadingPrintRows() {
        UUID planId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        ProductionPlanningPackageRepository repository =
                mock(ProductionPlanningPackageRepository.class);
        ProductionPlanRepository planRepository =
                mock(ProductionPlanRepository.class);
        ProductionDocumentAccessPolicy access =
                mock(ProductionDocumentAccessPolicy.class);
        EntityManager em = mock(EntityManager.class);
        ProductionPlan plan = new ProductionPlan();
        plan.setId(planId);
        plan.setMakerId(makerId);
        plan.setStatus((short) 1);
        when(planRepository.lockForWorkCard(planId))
                .thenReturn(Optional.of(plan));
        when(repository.lockConfirmedExecutionPackage(planId, packageId))
                .thenReturn(Optional.empty());

        ProductionWorkCardService service =
                new ProductionWorkCardService(
                        repository, planRepository, access, em);

        assertThatThrownBy(() -> service.view(planId, packageId))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.NOT_FOUND));
        verify(access).requireReadable(
                makerId, "生产计划不存在", "production_plan:approve");
        verifyNoInteractions(em);
    }

    @Test
    void enforcesPlanObjectScopeBeforeReadingPrintRows() {
        UUID planId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        ProductionPlanningPackageRepository packageRepository =
                mock(ProductionPlanningPackageRepository.class);
        ProductionPlanRepository planRepository =
                mock(ProductionPlanRepository.class);
        ProductionDocumentAccessPolicy access =
                mock(ProductionDocumentAccessPolicy.class);
        EntityManager em = mock(EntityManager.class);
        ProductionPlan plan = new ProductionPlan();
        plan.setId(planId);
        plan.setMakerId(makerId);
        plan.setStatus((short) 1);
        when(planRepository.lockForWorkCard(planId))
                .thenReturn(Optional.of(plan));
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在"))
                .when(access)
                .requireReadable(
                        makerId,
                        "生产计划不存在",
                        "production_plan:approve");

        ProductionWorkCardService service =
                new ProductionWorkCardService(
                        packageRepository, planRepository, access, em);

        assertThatThrownBy(() -> service.view(planId, packageId))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.NOT_FOUND));
        verify(access).requireReadable(
                makerId, "生产计划不存在", "production_plan:approve");
        verifyNoInteractions(packageRepository, em);
    }

    @Test
    void rejectsNonApprovedStoppedOrCancelledPlansBeforeReadingPackage() {
        assertPlanLifecycleRejected((short) 0, false, false);
        assertPlanLifecycleRejected((short) -1, false, false);
        assertPlanLifecycleRejected((short) 1, true, false);
        assertPlanLifecycleRejected((short) 1, false, true);
    }

    private static void assertPlanLifecycleRejected(
            short status, boolean stopped, boolean cancelled) {
        UUID planId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        ProductionPlanningPackageRepository packageRepository =
                mock(ProductionPlanningPackageRepository.class);
        ProductionPlanRepository planRepository =
                mock(ProductionPlanRepository.class);
        ProductionDocumentAccessPolicy access =
                mock(ProductionDocumentAccessPolicy.class);
        EntityManager em = mock(EntityManager.class);
        ProductionPlan plan = new ProductionPlan();
        plan.setId(planId);
        plan.setMakerId(makerId);
        plan.setStatus(status);
        plan.setStopped(stopped);
        plan.setCanceled(cancelled);
        when(planRepository.lockForWorkCard(planId))
                .thenReturn(Optional.of(plan));

        ProductionWorkCardService service =
                new ProductionWorkCardService(
                        packageRepository, planRepository, access, em);

        assertThatThrownBy(() -> service.view(planId, packageId))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT));
        verify(access).requireReadable(
                makerId, "生产计划不存在", "production_plan:approve");
        verifyNoInteractions(packageRepository, em);
    }

    @Test
    void groupsPersistedMaterialsByExecutionSegmentAndMarksCurrentNamePolicy() {
        UUID planId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID segmentId = UUID.randomUUID();
        UUID sourcePlanItemId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        ProductionPlanningPackage planningPackage =
                new ProductionPlanningPackage();
        planningPackage.setId(packageId);
        planningPackage.setPlanId(planId);
        planningPackage.setStatus("CONFIRMED");
        planningPackage.setExecutionModelVersion((short) 1);
        planningPackage.setLockVersion(4L);

        Object[] first = row(
                warehouseId, segmentId, sourcePlanItemId, productId,
                UUID.randomUUID(), UUID.randomUUID(),
                "MAT-01", "Material one", new BigDecimal("2.500000"));
        Object[] second = row(
                warehouseId, segmentId, sourcePlanItemId, productId,
                UUID.randomUUID(), UUID.randomUUID(),
                "MAT-02", "Material two", new BigDecimal("1.000000"));
        Instant generatedAt = Instant.parse("2026-08-02T10:20:30Z");

        ProductionWorkCardView view = ProductionWorkCardService.assemble(
                planningPackage, List.of(first, second), generatedAt);

        assertThat(view.planId()).isEqualTo(planId);
        assertThat(view.packageId()).isEqualTo(packageId);
        assertThat(view.packageLockVersion()).isEqualTo(4L);
        assertThat(view.generatedAt()).isEqualTo(generatedAt);
        assertThat(view.namePolicy())
                .isEqualTo(ProductionWorkCardView.CURRENT_MASTER_DATA);
        assertThat(view.cards()).hasSize(1);
        ProductionWorkCardView.Card card = view.cards().getFirst();
        assertThat(card.segmentId()).isEqualTo(segmentId);
        assertThat(card.segmentCode()).isEqualTo("SEG-001");
        assertThat(card.productName()).isEqualTo("Product one");
        assertThat(card.autoPromoteWhenReady()).isTrue();
        assertThat(card.materialRequirementMode()).isEqualTo("DEMANDED");
        assertThat(card.zeroMaterialReason()).isNull();
        assertThat(card.materials()).extracting(
                        ProductionWorkCardView.Material::goodsCode)
                .containsExactly("MAT-01", "MAT-02");
        assertThat(card.materials().getFirst().perProductQty())
                .isEqualByComparingTo("2.500000");
        assertThat(card.materials().getFirst().requirementMode())
                .isEqualTo("EXACT_SNAPSHOT");
    }

    @Test
    void pessimisticPackageReadRunsInALockCapableTransaction()
            throws NoSuchMethodException {
        var method = ProductionWorkCardService.class.getMethod(
                "view", UUID.class, UUID.class);
        var transaction = method.getAnnotation(
                org.springframework.transaction.annotation.Transactional.class);

        assertThat(transaction).isNotNull();
        assertThat(transaction.readOnly()).isFalse();
    }

    @Test
    void projectsFrozenZeroMaterialReasonWithoutInventingDemandRows() {
        UUID planId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        ProductionPlanningPackage planningPackage =
                new ProductionPlanningPackage();
        planningPackage.setId(packageId);
        planningPackage.setPlanId(planId);
        planningPackage.setStatus("CONFIRMED");
        planningPackage.setExecutionModelVersion((short) 1);
        Object[] zero = row(
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                "IGNORED", "IGNORED", BigDecimal.ONE);
        for (int index = 31; index <= 43; index++) {
            zero[index] = null;
        }
        zero[45] = null;
        zero[46] = "ZERO_MATERIAL";
        zero[47] = "NO_PRODUCTION_HARD_GATE";

        ProductionWorkCardView view = ProductionWorkCardService.assemble(
                planningPackage, List.<Object[]>of(zero), Instant.now());

        ProductionWorkCardView.Card card = view.cards().getFirst();
        assertThat(card.materials()).isEmpty();
        assertThat(card.materialRequirementMode()).isEqualTo("ZERO_MATERIAL");
        assertThat(card.zeroMaterialReason())
                .isEqualTo("NO_PRODUCTION_HARD_GATE");
    }

    private static Object[] row(
            UUID warehouseId,
            UUID segmentId,
            UUID sourcePlanItemId,
            UUID productId,
            UUID demandId,
            UUID materialId,
            String materialCode,
            String materialName,
            BigDecimal perProductQty) {
        return new Object[]{
                "SJ26080001", LocalDate.of(2026, 8, 2),
                LocalDate.of(2026, 8, 8), "审核人",
                OffsetDateTime.parse("2026-08-02T08:00:00Z"),
                warehouseId, "WH-01", "原料仓",
                segmentId, "SEG-001", sourcePlanItemId, 1, "P-001",
                productId, "PRD-01", "Product one", "100x20", "M-1",
                "白色", "件", new BigDecimal("5.0000"), "READY",
                "注塑车间", "一班", "负责人",
                LocalDate.of(2026, 8, 3), LocalDate.of(2026, 8, 4),
                "SO-001", "注意表面", "计划备注", "DRAW-001",
                demandId, materialId, materialCode, materialName, "S-1",
                "本色", "个", perProductQty, new BigDecimal("12.5000"),
                new BigDecimal("12.5000"), BigDecimal.ZERO,
                "BUY", "ALLOCATED", true, "EXACT_SNAPSHOT",
                "DEMANDED", null
        };
    }
}
