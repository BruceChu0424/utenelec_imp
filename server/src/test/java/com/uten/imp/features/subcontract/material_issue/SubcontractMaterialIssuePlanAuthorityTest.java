package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertAll;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/** V304/V305 委外出仓计划行权威字段与独立 handle 撤权门禁。 */
class SubcontractMaterialIssuePlanAuthorityTest {

    private SubcontractMaterialIssueRepository issueRepo;
    private SubcontractMaterialIssueItemRepository itemRepo;
    private StockService stockService;
    private EntityManager em;
    private SubcontractDocumentAccessPolicy access;
    private SubcontractMaterialIssueService service;

    @BeforeEach
    void setUp() {
        issueRepo = mock(SubcontractMaterialIssueRepository.class);
        itemRepo = mock(SubcontractMaterialIssueItemRepository.class);
        stockService = mock(StockService.class);
        em = mock(EntityManager.class);
        access = mock(SubcontractDocumentAccessPolicy.class);
        service = new SubcontractMaterialIssueService(
                issueRepo,
                itemRepo,
                stockService,
                mock(TxSessionVars.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                access,
                mock(SubcontractMaterialPlanService.class));
    }

    @Test
    void planSnapshotOverridesClientInventoryAndReferenceFields() {
        UUID planItemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID parentGoodsId = UUID.randomUUID();
        UUID parentColorId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();

        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter("id", planItemId)).thenReturn(query);
        when(query.getResultList()).thenReturn(java.util.Arrays.<Object[]>asList(new Object[]{
                planId, orderItemId, parentGoodsId, parentColorId,
                goodsId, colorId, unitId, new BigDecimal("2.5"),
                new BigDecimal("100"), new BigDecimal("20"), "OPEN"
        }));

        MaterialIssueItemLine line = new MaterialIssueItemLine();
        line.setPlanItemId(planItemId);
        line.setGoodsId(UUID.randomUUID());
        line.setColorId(UUID.randomUUID());
        line.setUnitId(UUID.randomUUID());
        line.setUnitRate(BigDecimal.ONE);
        line.setOrderItemId(UUID.randomUUID());
        line.setParentGoodsId(UUID.randomUUID());
        line.setParentColorId(UUID.randomUUID());
        line.setQty(new BigDecimal("30"));

        service.canonicalizePlanLines(List.of(line), Set.of(planItemId), true);

        assertEquals(orderItemId, line.getOrderItemId());
        assertEquals(parentGoodsId, line.getParentGoodsId());
        assertEquals(parentColorId, line.getParentColorId());
        assertEquals(goodsId, line.getGoodsId());
        assertEquals(colorId, line.getColorId());
        assertEquals(unitId, line.getUnitId());
        assertEquals(new BigDecimal("2.5"), line.getUnitRate());
    }

    @Test
    void planGeneratedDraftCannotDropItsPlanBinding() {
        UUID planItemId = UUID.randomUUID();
        MaterialIssueItemLine unbound = new MaterialIssueItemLine();
        unbound.setGoodsId(UUID.randomUUID());
        unbound.setQty(BigDecimal.ONE);

        ApiException error = assertThrows(ApiException.class,
                () -> service.canonicalizePlanLines(List.of(unbound), Set.of(planItemId), true));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getMessage().contains("不可移除计划行绑定"));
        verifyNoInteractions(em);
    }

    @Test
    void planGeneratedDraftCannotReplaceItsPlanBinding() {
        UUID currentPlanItemId = UUID.randomUUID();
        MaterialIssueItemLine replaced = new MaterialIssueItemLine();
        replaced.setPlanItemId(UUID.randomUUID());
        replaced.setGoodsId(UUID.randomUUID());
        replaced.setQty(BigDecimal.ONE);

        ApiException error = assertThrows(ApiException.class,
                () -> service.canonicalizePlanLines(
                        List.of(replaced), Set.of(currentPlanItemId), true));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getMessage().contains("不可新增或替换"));
        verifyNoInteractions(em);
    }

    @Test
    void outboundHandleRevocationBlocksOldUpdateAndApproveEndpoints() {
        UUID issueId = UUID.randomUUID();
        SubcontractMaterialIssue document = new SubcontractMaterialIssue();
        document.setId(issueId);
        document.setStatus((short) 0);
        document.setMakerId(null);
        document.setWarehouseId(UUID.randomUUID());
        when(em.find(SubcontractMaterialIssue.class, issueId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(document);

        SubcontractMaterialIssueItem item = new SubcontractMaterialIssueItem();
        item.setIssueId(issueId);
        item.setPlanItemId(UUID.randomUUID());
        item.setOrderItemId(UUID.randomUUID());
        item.setGoodsId(UUID.randomUUID());
        item.setQty(BigDecimal.ONE);
        when(itemRepo.findByIssueIdOrderByLineNoAsc(issueId)).thenReturn(List.of(item));
        when(access.hasAuthority("subcontract_material_issue:edit")).thenReturn(true);
        when(access.hasAuthority("subcontract_outbound:handle")).thenReturn(false);

        ApiException updateError = assertThrows(ApiException.class,
                () -> service.update(issueId, mock(MaterialIssueSaveRequest.class)));
        ApiException approveError = assertThrows(ApiException.class,
                () -> service.approve(issueId));

        assertAll(
                () -> assertEquals(ErrorCode.FORBIDDEN, updateError.getCode()),
                () -> assertTrue(updateError.getMessage().contains("委外出仓执行权限")),
                () -> assertEquals(ErrorCode.FORBIDDEN, approveError.getCode()),
                () -> assertTrue(approveError.getMessage().contains("委外出仓执行权限")));
        verifyNoInteractions(stockService);
    }

    @Test
    void materialIssueEditRevocationAlsoBlocksPlanDraftUpdateAndApprove() {
        UUID issueId = UUID.randomUUID();
        SubcontractMaterialIssue document = new SubcontractMaterialIssue();
        document.setId(issueId);
        document.setStatus((short) 0);
        document.setMakerId(null);
        document.setWarehouseId(UUID.randomUUID());
        when(em.find(SubcontractMaterialIssue.class, issueId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(document);

        SubcontractMaterialIssueItem item = new SubcontractMaterialIssueItem();
        item.setIssueId(issueId);
        item.setPlanItemId(UUID.randomUUID());
        when(itemRepo.findByIssueIdOrderByLineNoAsc(issueId)).thenReturn(List.of(item));
        when(access.hasAuthority("subcontract_material_issue:edit")).thenReturn(false);
        when(access.hasAuthority("subcontract_outbound:handle")).thenReturn(true);

        ApiException updateError = assertThrows(ApiException.class,
                () -> service.update(issueId, mock(MaterialIssueSaveRequest.class)));
        ApiException approveError = assertThrows(ApiException.class,
                () -> service.approve(issueId));

        assertAll(
                () -> assertEquals(ErrorCode.FORBIDDEN, updateError.getCode()),
                () -> assertTrue(updateError.getMessage().contains("材料出仓单操作权限")),
                () -> assertEquals(ErrorCode.FORBIDDEN, approveError.getCode()),
                () -> assertTrue(approveError.getMessage().contains("材料出仓单操作权限")));
        verifyNoInteractions(stockService);
    }
}
