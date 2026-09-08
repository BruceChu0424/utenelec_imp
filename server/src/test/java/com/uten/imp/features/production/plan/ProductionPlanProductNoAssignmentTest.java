package com.uten.imp.features.production.plan;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.features.production.mrp.ProductionPlanningDraftService;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionPlanProductNoAssignmentTest {

    @Test
    void keepsExplicitBusinessNumberAndAllocatesOnlyTheBlankLine() throws Exception {
        ProductionPlanItemRepository itemRepo = mock(ProductionPlanItemRepository.class);
        ProductionProductNoAllocator allocator = mock(ProductionProductNoAllocator.class);
        ProductionPlanService service = new ProductionPlanService(
                mock(ProductionPlanRepository.class), itemRepo,
                mock(PlanOrderItemLinkRepository.class), mock(MrpService.class),
                mock(ProductionPlanningDraftService.class), mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class), mock(EmployeeNameResolver.class),
                mock(EntityManager.class), mock(DocNumberService.class), allocator,
                 mock(ChainNoticeService.class), mock(ProductionDocumentAccessPolicy.class),
                 mock(MaterialAnalysisService.class), mock(ProductionPlanMutationFootprintService.class));
        ProductionPlan plan = new ProductionPlan();
        plan.setBillNo("SJ20260814000001");
        plan.setBillDate(LocalDate.of(2026, 8, 14));
        PlanItemLine explicit = line(" custom-7 ");
        PlanItemLine automatic = line("  ");
        when(allocator.allocate(plan.getId(), Set.of("CUSTOM-7")))
                .thenReturn("SJ20260814000001-001");

        Method saveItems = ProductionPlanService.class.getDeclaredMethod(
                "saveItems", ProductionPlan.class, List.class);
        saveItems.setAccessible(true);
        saveItems.invoke(service, plan, List.of(explicit, automatic));

        ArgumentCaptor<ProductionPlanItem> saved =
                ArgumentCaptor.forClass(ProductionPlanItem.class);
        verify(itemRepo, times(2)).save(saved.capture());
        assertThat(saved.getAllValues())
                .extracting(ProductionPlanItem::getProductNo)
                .containsExactly("custom-7", "SJ20260814000001-001");
        verify(allocator).allocate(plan.getId(), Set.of("CUSTOM-7"));
    }

    private static PlanItemLine line(String productNo) {
        PlanItemLine line = new PlanItemLine();
        line.setProductNo(productNo);
        line.setGoodsId(UUID.randomUUID());
        line.setQty(BigDecimal.ONE);
        return line;
    }
}
