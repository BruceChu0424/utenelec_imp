package com.uten.imp.features.production.directtransfer;

import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.production.dailyreport.ProductionDailyReport;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportItem;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionWorkshopDirectTransferServiceTest {
    @Test
    void reversalRefreshesOriginalAndSplitReceivingTasksFromCurrentState() {
        EntityManager em = mock(EntityManager.class);
        var currentUser = mock(SecurityContextCurrentUser.class);
        var notices = mock(ChainNoticeService.class);
        UUID report = UUID.randomUUID(), transfer = UUID.randomUUID();
        UUID original = UUID.randomUUID(), split = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            if (sql.contains("SELECT DISTINCT transfer.id")) {
                when(query.getResultList()).thenReturn(List.of(transfer));
            } else if (sql.contains("SELECT DISTINCT demand.execution_segment_id")) {
                when(query.getResultList()).thenReturn(List.of(original, split));
            }
            return query;
        });
        var service = new ProductionWorkshopDirectTransferService(em, currentUser,
                mock(ProductionWorkshopMembership.class), mock(ProductionFqcInspectionService.class),
                mock(ProductionExecutionReadinessService.class), mock(StockDocService.class),
                mock(LineSideWarehousePort.class), notices);
        service.reverseForReport(report, "报工更正");
        verify(notices).resolveProductionWorkshopTasks(List.of(original, split), "DIRECT_TRANSFER_REVERSED");
        verify(notices).notifyWorkshopMaterialArrival(eq(original), eq("DT-REVERSE-" + report),
                contains("已撤回"), eq("CURRENT_STATE"), eq(List.of()));
        verify(notices).notifyWorkshopMaterialArrival(eq(split), eq("DT-REVERSE-" + report),
                contains("已撤回"), eq("CURRENT_STATE"), eq(List.of()));
    }

    @Test
    void oneReportUsesEachReceivingStorageAndTopsUpInBaseUnits() {
        EntityManager em = mock(EntityManager.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = mock(AuthUser.class);
        when(user.isSuperAdmin()).thenReturn(true);
        when(currentUser.get()).thenReturn(Optional.of(user));
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        var membership = mock(ProductionWorkshopMembership.class);
        when(membership.isWorkshopMember(any(), any(), any())).thenReturn(true);
        var inspections = mock(ProductionFqcInspectionService.class);
        when(inspections.registerWorkshopSelfInspection(any(), any(), any())).thenReturn(UUID.randomUUID());
        when(inspections.passWorkshopSelfInspection(any(), any())).thenReturn(UUID.randomUUID());
        var readiness = mock(ProductionExecutionReadinessService.class);
        var stockDocs = mock(StockDocService.class);
        var locations = mock(LineSideWarehousePort.class);
        var notices = mock(ChainNoticeService.class);
        UUID workshop = UUID.randomUUID(), firstWarehouse = UUID.randomUUID(), secondWarehouse = UUID.randomUUID();
        UUID firstLocation = UUID.randomUUID(), secondLocation = UUID.randomUUID();
        UUID firstDemand = UUID.randomUUID(), secondDemand = UUID.randomUUID();
        UUID firstReceiver = UUID.randomUUID(), secondReceiver = UUID.randomUUID();
        var first = item("2", "5");
        var second = item("3", "4");
        when(locations.ensure(workshop, firstWarehouse)).thenReturn(firstLocation);
        when(locations.ensure(workshop, secondWarehouse)).thenReturn(secondLocation);
        List<Map<String, Object>> heads = new ArrayList<>();
        List<Map<String, Object>> lines = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = mock(Query.class);
            Map<String, Object> params = new HashMap<>();
            when(query.setParameter(anyString(), any())).thenAnswer(binding -> {
                params.put(binding.getArgument(0), binding.getArgument(1));
                return query;
            });
            when(query.getResultList()).thenAnswer(ignored -> {
                if (sql.contains("FROM production_daily_report_items report_item")) {
                    boolean isFirst = first.getId().equals(params.get("itemId"));
                    return java.util.Collections.singletonList(new Object[]{
                            isFirst ? firstDemand : secondDemand, isFirst ? firstReceiver : secondReceiver,
                            UUID.randomUUID(), workshop, workshop,
                            isFirst ? firstWarehouse : secondWarehouse,
                            isFirst ? firstWarehouse : secondWarehouse,
                            "IN_PROGRESS", true, "子件", isFirst?BigDecimal.TEN:new BigDecimal("12")});
                }
                return java.util.Collections.singletonList(new Object[]{workshop, UUID.randomUUID()});
            });
            when(query.executeUpdate()).thenAnswer(ignored -> {
                if (sql.contains("INSERT INTO production_workshop_direct_transfers(")) heads.add(Map.copyOf(params));
                if (sql.contains("INSERT INTO production_workshop_direct_transfer_items(")) lines.add(Map.copyOf(params));
                return 1;
            });
            return query;
        });
        var service = new ProductionWorkshopDirectTransferService(em, currentUser, membership,
                inspections, readiness, stockDocs, locations, notices);
        var report = new ProductionDailyReport();
        report.setId(UUID.randomUUID());
        service.executeForApprovedReport(report, List.of(first, second));

        assertThat(heads).hasSize(2);
        assertThat(heads).extracting(row -> row.get("warehouseId"))
                .containsExactly(firstLocation, secondLocation);
        assertThat(heads.get(0).get("key")).isNotEqualTo(heads.get(1).get("key"));
        assertThat(lines).extracting(row -> row.get("qty"))
                .containsExactly(new BigDecimal("2"), new BigDecimal("3"));
        verify(readiness).topUpDirectSupply(eq(firstReceiver), eq(firstDemand), eq(firstLocation),
                argThat(value -> value.compareTo(BigDecimal.TEN) == 0), anyString());
        verify(readiness).topUpDirectSupply(eq(secondReceiver), eq(secondDemand), eq(secondLocation),
                argThat(value -> value.compareTo(new BigDecimal("12")) == 0), anyString());
        verify(notices).notifyWorkshopMaterialArrival(eq(firstReceiver), eq("DT-" + first.getId()), contains("子件 10"),
                eq("DIRECT_REPORT"), eq(List.of(report.getId())));
        verify(notices).notifyWorkshopMaterialArrival(eq(secondReceiver), eq("DT-" + second.getId()), contains("子件 12"),
                eq("DIRECT_REPORT"), eq(List.of(report.getId())));
    }

    private static ProductionDailyReportItem item(String quantity, String rate) {
        var item = new ProductionDailyReportItem();
        item.setId(UUID.randomUUID());
        item.setExecutionSegmentId(UUID.randomUUID());
        item.setDestination("WORKSHOP");
        item.setQty(new BigDecimal(quantity));
        item.setUnitRate(new BigDecimal(rate));
        return item;
    }
}
