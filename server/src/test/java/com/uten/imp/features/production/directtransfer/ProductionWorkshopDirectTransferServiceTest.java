package com.uten.imp.features.production.directtransfer;

import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.common.web.ApiException;
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
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
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

    /**
     * ADR-147: 一个车间只有一个开通的内料仓。一张报工里两行分别送给两个不同收料主仓的需求, 也都进这个车间
     * 开通的那一个内料仓(一张直送单头), 各自按基本单位补投。
     */
    @Test
    void oneReportUsesTheWorkshopsOpenedBinAndTopsUpInBaseUnits() {
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
        UUID bin = UUID.randomUUID();
        UUID firstDemand = UUID.randomUUID(), secondDemand = UUID.randomUUID();
        UUID firstReceiver = UUID.randomUUID(), secondReceiver = UUID.randomUUID();
        var first = item("2", "5");
        var second = item("3", "4");
        when(locations.openedBinOf(workshop)).thenReturn(Optional.of(bin));
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
                if (sql.contains("fn_workshop_direct_targets(")) {
                    boolean isFirst = first.getId().equals(params.get("itemId"));
                    // V736：审核逐行读库里唯一的单条判定(接收方信息 + 能不能送 + 原因)，带本次基本数量。
                    assertThat(params.get("baseQty")).isEqualTo(isFirst ? new BigDecimal("10.0000") : new BigDecimal("12.0000"));
                    return java.util.Collections.singletonList(new Object[]{
                            isFirst ? firstDemand : secondDemand, isFirst ? firstReceiver : secondReceiver,
                            UUID.randomUUID(), workshop,
                            isFirst ? firstWarehouse : secondWarehouse,
                            isFirst ? firstWarehouse : secondWarehouse,
                            "IN_PROGRESS", true, "子件", true, null});
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

        assertThat(heads).hasSize(1);
        assertThat(heads).extracting(row -> row.get("warehouseId")).containsExactly(bin);
        assertThat(lines).extracting(row -> row.get("qty"))
                .containsExactly(new BigDecimal("2"), new BigDecimal("3"));
        verify(readiness).topUpDirectSupply(eq(firstReceiver), eq(firstDemand), eq(bin),
                argThat(value -> value.compareTo(BigDecimal.TEN) == 0), anyString());
        verify(readiness).topUpDirectSupply(eq(secondReceiver), eq(secondDemand), eq(bin),
                argThat(value -> value.compareTo(new BigDecimal("12")) == 0), anyString());
        verify(locations, times(1)).openedBinOf(workshop);
        verify(notices).notifyWorkshopMaterialArrival(eq(firstReceiver), eq("DT-" + first.getId()), contains("子件 10"),
                eq("DIRECT_REPORT"), eq(List.of(report.getId())));
        verify(notices).notifyWorkshopMaterialArrival(eq(secondReceiver), eq("DT-" + second.getId()), contains("子件 12"),
                eq("DIRECT_REPORT"), eq(List.of(report.getId())));
    }

    /**
     * ADR-127 §8：一行报工分给三个上层工单(同一车间、同一收料主仓)。仍逐块办——每块自己的检验、
     * 入库确认与投料，一块办完才写下一块的直送明细；线边仓只确定一次。
     */
    @ParameterizedTest
    @CsvSource({"true,false","false,true","false,false"})
    void piecesToSeveralReceiversAreHandledOneByOneAndResolveTheLineSideOnce(
            boolean continuous, boolean lineSideIssueChecked) {
        EntityManager em = mock(EntityManager.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = mock(AuthUser.class);
        when(user.isSuperAdmin()).thenReturn(true);
        when(currentUser.get()).thenReturn(Optional.of(user));
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        var membership = mock(ProductionWorkshopMembership.class);
        when(membership.isWorkshopMember(any(), any(), any())).thenReturn(true);
        UUID workshop = UUID.randomUUID(), warehouse = UUID.randomUUID(), location = UUID.randomUUID();
        UUID producing = UUID.randomUUID();
        List<UUID> demands = List.of(UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID());
        List<UUID> receivers = List.of(UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID());
        List<ProductionDailyReportItem> pieces = new ArrayList<>();
        for (UUID demand : demands) {
            var piece = item("1", "1");
            piece.setExecutionSegmentId(producing);
            piece.setDirectTransferDemandId(demand);
            pieces.add(piece);
        }
        List<String> events = new ArrayList<>();
        java.util.function.Function<Object, Integer> index = id -> {
            for (int at = 0; at < pieces.size(); at++) if (pieces.get(at).getId().equals(id)) return at;
            throw new AssertionError("unknown piece");
        };
        var inspections = mock(ProductionFqcInspectionService.class);
        when(inspections.registerWorkshopSelfInspection(any(), any(), any())).thenAnswer(call -> {
            events.add("inspect:" + index.apply(call.getArgument(1)));
            return UUID.randomUUID();
        });
        when(inspections.passWorkshopSelfInspection(any(), any())).thenReturn(UUID.randomUUID());
        var readiness = mock(ProductionExecutionReadinessService.class);
        doAnswer(call -> events.add("handover:" + receivers.indexOf(call.<UUID>getArgument(0))))
                .when(readiness).topUpDirectSupply(any(), any(), any(), any(), anyString());
        when(readiness.promoteAfterWorkshopDirectTransfer(any(),any())).thenAnswer(call->{
            events.add("handover:"+receivers.indexOf(call.<UUID>getArgument(0)));return lineSideIssueChecked;
        });
        var stockDocs = mock(StockDocService.class);
        doAnswer(call -> events.add("confirm"))
                .when(stockDocs).confirmWorkshopDirectTransferInbound(any(), anyString());
        var locations = mock(LineSideWarehousePort.class);
        when(locations.openedBinOf(workshop)).thenReturn(Optional.of(location));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = mock(Query.class);
            Map<String, Object> params = new HashMap<>();
            when(query.setParameter(anyString(), any())).thenAnswer(binding -> {
                params.put(binding.getArgument(0), binding.getArgument(1));
                return query;
            });
            when(query.getResultList()).thenAnswer(ignored -> {
                if (sql.contains("fn_workshop_direct_targets(")) {
                    int at = index.apply(params.get("itemId"));
                    return java.util.Collections.singletonList(new Object[] {
                            demands.get(at), receivers.get(at), UUID.randomUUID(), workshop,
                            warehouse, warehouse, "IN_PROGRESS", continuous, "子件", true, null});
                }
                return java.util.Collections.singletonList(new Object[] {workshop, UUID.randomUUID()});
            });
            when(query.executeUpdate()).thenAnswer(ignored -> {
                if (sql.contains("INSERT INTO production_workshop_direct_transfer_items(")) {
                    events.add("transfer:" + index.apply(params.get("itemId")));
                }
                return 1;
            });
            return query;
        });
        var service = new ProductionWorkshopDirectTransferService(em, currentUser, membership,
                inspections, readiness, stockDocs, locations, mock(ChainNoticeService.class));
        var report = new ProductionDailyReport();
        report.setId(UUID.randomUUID());
        service.executeForApprovedReport(report, pieces);

        assertThat(events).containsExactly(
                "transfer:0", "inspect:0", "confirm", "handover:0",
                "transfer:1", "inspect:1", "confirm", "handover:1",
                "transfer:2", "inspect:2", "confirm", "handover:2");
        verify(locations, times(1)).openedBinOf(workshop);
        verify(stockDocs,times(!continuous&&!lineSideIssueChecked?3:0))
                .issueWorkshopDirectTransferDraws(any(),any(),anyString());
    }

    /**
     * ADR-147: 不再第一次直送时自动建仓。资格判定放行了但收料车间的内料仓刚被撤销(并发), 审核拒绝并说明,
     * 一笔直送都不写。
     */
    @Test
    void approvalRefusesWhenTheReceivingWorkshopHasNoOpenedBinAndWritesNothing() {
        EntityManager em = mock(EntityManager.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = mock(AuthUser.class);
        when(user.isSuperAdmin()).thenReturn(true);
        when(currentUser.get()).thenReturn(Optional.of(user));
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        var membership = mock(ProductionWorkshopMembership.class);
        when(membership.isWorkshopMember(any(), any(), any())).thenReturn(true);
        UUID workshop = UUID.randomUUID(), warehouse = UUID.randomUUID();
        var piece = item("1", "1");
        List<String> writes = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            when(query.getResultList()).thenAnswer(ignored -> {
                if (sql.contains("fn_workshop_direct_targets(")) {
                    return java.util.Collections.singletonList(new Object[] {
                            UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), workshop,
                            warehouse, warehouse, "IN_PROGRESS", true, "子件", true, null});
                }
                return java.util.Collections.singletonList(new Object[] {workshop, UUID.randomUUID()});
            });
            when(query.executeUpdate()).thenAnswer(ignored -> {
                writes.add(sql);
                return 1;
            });
            return query;
        });
        var locations = mock(LineSideWarehousePort.class);
        when(locations.openedBinOf(workshop)).thenReturn(Optional.empty());
        var service = new ProductionWorkshopDirectTransferService(em, currentUser, membership,
                mock(ProductionFqcInspectionService.class), mock(ProductionExecutionReadinessService.class),
                mock(StockDocService.class), locations, mock(ChainNoticeService.class));
        var report = new ProductionDailyReport();
        report.setId(UUID.randomUUID());

        assertThatThrownBy(() -> service.executeForApprovedReport(report, List.of(piece)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("还没开通内料仓")
                .hasMessageContaining("这次先送入仓库");
        assertThat(writes).isEmpty();
    }

    @Test
    void approvalRefusesAnIneligibleReceiverWithTheDatabaseReasonAndWritesNothing() {
        EntityManager em = mock(EntityManager.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        AuthUser user = mock(AuthUser.class);
        when(user.isSuperAdmin()).thenReturn(true);
        when(currentUser.get()).thenReturn(Optional.of(user));
        List<String> writes = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            when(query.getResultList()).thenAnswer(ignored -> sql.contains("fn_workshop_direct_targets(")
                    ? java.util.Collections.singletonList(new Object[]{
                            UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                            UUID.randomUUID(), UUID.randomUUID(), "READY", false, "子件", false,
                            "上层 HV5ZJ012 是委外件：本工单做的物料先送入仓库，由委外人员领料发给委外商"})
                    : List.of());
            when(query.executeUpdate()).thenAnswer(ignored -> { writes.add(sql); return 1; });
            return query;
        });
        var locations = mock(LineSideWarehousePort.class);
        var service = new ProductionWorkshopDirectTransferService(em, currentUser,
                mock(ProductionWorkshopMembership.class), mock(ProductionFqcInspectionService.class),
                mock(ProductionExecutionReadinessService.class), mock(StockDocService.class),
                locations, mock(ChainNoticeService.class));
        var report = new ProductionDailyReport();
        report.setId(UUID.randomUUID());
        assertThatThrownBy(() -> service.executeForApprovedReport(report, List.of(item("2", "1"))))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .hasMessage("无法转到下一道工序：上层 HV5ZJ012 是委外件：本工单做的物料先送入仓库，由委外人员领料发给委外商");
        assertThat(writes).isEmpty();
        verifyNoInteractions(locations);
    }

    @Test
    void candidatesReturnOnlyEligibleReceiversOrTheClosestReason() {
        UUID segment = UUID.randomUUID(), goods = UUID.randomUUID(), demand = UUID.randomUUID();
        Object[] eligible = targetRow(demand, goods, true, null, null, 0);
        Object[] crossWorkshop = targetRow(UUID.randomUUID(), goods, false, "DIFFERENT_WORKSHOP",
                "上层工单 ZX1 在二车间，跨车间必须送入仓库", 40);
        Object[] subcontract = targetRow(UUID.randomUUID(), goods, false, "SUBCONTRACT_ROUTE",
                "上层 子件 是委外件：本工单做的物料先送入仓库，由委外人员领料发给委外商", 50);
        var withReceiver = candidateService(List.of(subcontract, eligible, crossWorkshop))
                .candidates(segment, goods, null);
        assertThat(withReceiver.candidates()).extracting(ProductionWorkshopDirectTransferService.Candidate::demandId)
                .containsExactly(demand);
        assertThat(withReceiver.unavailableReason()).isNull();
        assertThat(withReceiver.unavailableReasonCode()).isNull();
        // V736 第二步：结构上的上层但现在不能收的工单同一次序列出(下拉里置灰写原因)；没有父子关系的库里就不列。
        assertThat(withReceiver.blockedTargets())
                .extracting(ProductionWorkshopDirectTransferService.BlockedTarget::reasonCode)
                .containsExactly("SUBCONTRACT_ROUTE", "DIFFERENT_WORKSHOP");
        assertThat(withReceiver.blockedTargets().getLast().reason())
                .isEqualTo("上层工单 ZX1 在二车间，跨车间必须送入仓库");
        assertThat(withReceiver.receiverLimit())
                .isEqualTo(com.uten.imp.common.validation.RequestLimits.DAILY_REPORT_DIRECT_RECEIVERS);

        var blocked = candidateService(List.of(subcontract, crossWorkshop)).candidates(segment, goods, null);
        assertThat(blocked.candidates()).isEmpty();
        assertThat(blocked.unavailableReasonCode()).isEqualTo("DIFFERENT_WORKSHOP");
        assertThat(blocked.unavailableReason()).isEqualTo("上层工单 ZX1 在二车间，跨车间必须送入仓库");

        Object[] sentinel = targetRow(null, null, false, "NOT_A_COMPONENT", "本工单做的是顶层产品，没有下一道工序，请送入仓库", 71);
        var top = candidateService(java.util.Collections.singletonList(sentinel)).candidates(segment, goods, null);
        assertThat(top.candidates()).isEmpty();
        assertThat(top.blockedTargets()).isEmpty();
        assertThat(top.unavailableReasonCode()).isEqualTo("NOT_A_COMPONENT");

        // 报工行货品与来源工单产品对不上：查询把每条都标成 GOODS_MISMATCH，它们不是这个货品的上层，不进置灰列表。
        Object[] mismatch = targetRow(UUID.randomUUID(), goods, false, "GOODS_MISMATCH", "所选上层工单需要的不是这个货品", 62);
        var wrongGoods = candidateService(List.<Object[]>of(mismatch)).candidates(segment, goods, null);
        assertThat(wrongGoods.blockedTargets()).isEmpty();
        assertThat(wrongGoods.unavailableReasonCode()).isEqualTo("GOODS_MISMATCH");

        // 报工行货品与来源工单产品是否一致也在库里判(同一份文案)，这里只把两者原样传过去。
        Map<String, Object> bound = new HashMap<>();
        candidateService(List.<Object[]>of(eligible), bound).candidates(segment, goods, null);
        assertThat(bound).containsEntry("segmentId", segment).containsEntry("goodsId", goods).containsKey("colorId");
    }

    private static Object[] targetRow(UUID demand, UUID goods, boolean eligible, String code, String text, int rank) {
        Object[] row = new Object[23];
        row[0] = demand;
        row[1] = demand == null ? null : UUID.randomUUID();
        row[2] = demand == null ? null : "ZX0001";
        row[3] = demand == null ? null : "READY";
        row[4] = false;
        row[7] = goods;
        row[12] = BigDecimal.TEN;
        row[13] = BigDecimal.ZERO;
        row[14] = eligible ? BigDecimal.TEN : BigDecimal.ZERO;
        row[18] = eligible;
        row[19] = code;
        row[20] = text;
        row[21] = rank;
        return row;
    }

    private static ProductionWorkshopDirectTransferService candidateService(List<Object[]> targets) {
        return candidateService(targets, new HashMap<>());
    }

    private static ProductionWorkshopDirectTransferService candidateService(
            List<Object[]> targets, Map<String, Object> bound) {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenAnswer(binding -> {
                if (sql.contains("fn_workshop_direct_targets(")) bound.put(binding.getArgument(0), binding.getArgument(1));
                return query;
            });
            when(query.getResultList()).thenAnswer(ignored -> {
                if (sql.contains("fn_workshop_direct_targets(")) return new ArrayList<>(targets);
                if (sql.contains("responsible_employee_id")) {
                    return java.util.Collections.singletonList(new Object[]{UUID.randomUUID(), UUID.randomUUID()});
                }
                return List.of();
            });
            return query;
        });
        var currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.employeeId()).thenReturn(Optional.empty());
        var membership = mock(ProductionWorkshopMembership.class);
        when(membership.isWorkshopMember(any(), any(), any())).thenReturn(true);
        return new ProductionWorkshopDirectTransferService(em, currentUser, membership,
                mock(ProductionFqcInspectionService.class), mock(ProductionExecutionReadinessService.class),
                mock(StockDocService.class), mock(LineSideWarehousePort.class), mock(ChainNoticeService.class));
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
