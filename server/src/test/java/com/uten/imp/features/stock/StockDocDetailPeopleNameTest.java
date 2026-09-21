package com.uten.imp.features.stock;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 仓库单据详情随单返回人员姓名: 制单员(makerName)与领料/经办负责人(workerName)都由服务端
 * 按同一解析器落到详情, 仓库端不再为了显示「领料负责人」逐张调员工档案接口
 * (该接口要求 employee:view 且每次调用落人事查看审计, 仓库/车间账号通常没有)。
 */
class StockDocDetailPeopleNameTest {

    private final StockDocumentRepository documents = mock(StockDocumentRepository.class);
    private final StockBalanceAdjustmentCommandRepository balanceAdjustmentCommands =
            mock(StockBalanceAdjustmentCommandRepository.class);
    private final StockDocumentItemRepository items = mock(StockDocumentItemRepository.class);
    private final StockDocAccessPolicy access = mock(StockDocAccessPolicy.class);
    private final EmployeeNameResolver employeeNames = mock(EmployeeNameResolver.class);
    private final EntityManager entityManager = stubbedEntityManager();

    @Test
    void detailCarriesServerResolvedWorkerAndMakerNames() {
        StockDocument document = draw();
        UUID worker = UUID.randomUUID();
        UUID maker = UUID.randomUUID();
        document.setWorkerId(worker);
        document.setMakerId(maker);
        stubDocumentReads(document);
        when(employeeNames.nameOf(worker)).thenReturn("石磊");
        when(employeeNames.nameOf(maker)).thenReturn("朱振炜");

        var detail = service().detail(document.getId());

        assertEquals(worker, detail.getWorkerId());
        assertEquals("石磊", detail.getWorkerName());
        assertEquals("朱振炜", detail.getMakerName());
    }

    @Test
    void detailLeavesWorkerNameNullWhenDocumentHasNoWorker() {
        StockDocument document = draw();
        stubDocumentReads(document);

        var detail = service().detail(document.getId());

        assertNull(detail.getWorkerId());
        assertNull(detail.getWorkerName());
    }

    private void stubDocumentReads(StockDocument document) {
        when(documents.findById(document.getId())).thenReturn(Optional.of(document));
        when(items.findByDocIdOrderByLineNoAsc(document.getId())).thenReturn(List.of());
        when(balanceAdjustmentCommands.existsByStockDocumentId(document.getId())).thenReturn(false);
    }

    private StockDocService service() {
        when(access.hasAuthority(StockCostMasker.PERMISSION)).thenReturn(true);
        return new StockDocService(
                documents,
                balanceAdjustmentCommands,
                items,
                mock(StockBalanceRepository.class),
                mock(StockService.class),
                mock(StockReservationService.class),
                mock(TxSessionVars.class),
                mock(DocNumberService.class),
                entityManager,
                mock(SecurityContextCurrentUser.class),
                employeeNames,
                mock(ChainNoticeService.class),
                mock(com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService.class),
                mock(com.uten.imp.application.port.ProductionCompletionReversePort.class),
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                access,
                mock(ProductionStockTaskAccessPolicy.class),
                mock(com.uten.imp.application.port.PreplanAnalysisPegPort.class),
                mock(com.uten.imp.application.port.ProductionQualityInspectionPort.class),
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class),
                mock(com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService.class));
    }

    /** 其余原生查询一律返回 false/空; DRAW 详情门禁(车间已提交领料申请)放行。 */
    private static EntityManager stubbedEntityManager() {
        Query query = mock(Query.class);
        EntityManager entityManager = mock(EntityManager.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(false);
        when(query.getResultList()).thenReturn(List.of());
        Query drawRequested = mock(Query.class);
        when(drawRequested.setParameter(anyString(), any())).thenReturn(drawRequested);
        when(drawRequested.getSingleResult()).thenReturn(true);
        when(entityManager.createNativeQuery(contains("fn_production_draw_requested")))
                .thenReturn(drawRequested);
        return entityManager;
    }

    private static StockDocument draw() {
        StockDocument document = new StockDocument();
        document.setId(UUID.randomUUID());
        document.setDocType("DRAW");
        document.setBillNo("SL-TEST-001");
        document.setBillDate(LocalDate.of(2026, 9, 21));
        document.setWarehouseId(UUID.randomUUID());
        document.setStatus((short) 1);
        return document;
    }
}
