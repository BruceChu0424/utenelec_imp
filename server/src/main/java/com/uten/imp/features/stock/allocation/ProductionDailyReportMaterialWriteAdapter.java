package com.uten.imp.features.stock.allocation;

import com.uten.imp.application.port.ProductionMaterialConsumptionWritePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 生产日报审核/红冲 → 材料结算与余料退仓的写侧适配器(V583)。
 *
 * <p>这里只做编排，记账规则全部留在 {@link ProductionMaterialSettlementService} 和
 * {@link ProductionMaterialReturnRequestService} 里：两者的权限、对象范围、幂等、FIFO 摊分和
 * 数据库守恒守卫一条都不绕过。
 *
 * <p>幂等键由日报 UUID 派生而不是随机生成：审核是可重试动作，同一张日报重试必须命中原事件，
 * 否则会把同一份料重复消耗掉。
 */
@Component
@RequiredArgsConstructor
public class ProductionDailyReportMaterialWriteAdapter
        implements ProductionMaterialConsumptionWritePort {

    private final EntityManager em;
    private final ProductionMaterialSettlementService settlements;
    private final ProductionMaterialReturnRequestService returns;
    private final SecurityContextCurrentUser currentUser;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void consumeForDailyReport(
            UUID planId,
            UUID executionSegmentId,
            UUID dailyReportId,
            String idempotencyKey,
            String reason,
            List<ConsumptionLine> lines) {
        List<ConsumptionLine> posting = lines == null ? List.of() : lines.stream()
                .filter(line -> line.qtyBase() != null && line.qtyBase().signum() > 0)
                .toList();
        if (posting.isEmpty()) return;

        ProductionMaterialSettlementRequest request =
                new ProductionMaterialSettlementRequest();
        request.setExecutionSegmentId(executionSegmentId);
        request.setIdempotencyKey(idempotencyKey);
        request.setReason(reason);
        request.setLines(posting.stream().map(line -> {
            ProductionMaterialSettlementRequest.Line out =
                    new ProductionMaterialSettlementRequest.Line();
            out.setDemandId(line.demandId());
            out.setSettlementType("CONSUMED");
            out.setQtyBase(line.qtyBase());
            return out;
        }).toList());

        settlements.post(planId, request, currentUser.requireId());
        stampDailyReport(planId, "POST", idempotencyKey, dailyReportId);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public int requestSurplusReturnForDailyReport(
            UUID planId,
            UUID executionSegmentId,
            UUID dailyReportId,
            String idempotencyKey,
            String reason) {
        // 可退量与单位换算全部由服务端给：clearance 是基本量，退料单走原领料单位
        // (unit_rate 不为 1 时两者不等)，前端和这里都不得自己换算差额。
        List<ProductionMaterialReturnRequest.Item> items = returns
                .sources(planId, executionSegmentId).stream()
                .filter(source -> source.returnBlockedReason() == null)
                .filter(source -> source.availableQty() != null
                        && source.availableQty().signum() > 0)
                .map(source -> new ProductionMaterialReturnRequest.Item(
                        source.issuePostingId(), source.availableQty()))
                .toList();
        if (items.isEmpty()) return 0;
        return returns.submit(planId, new ProductionMaterialReturnRequest.Submit(
                executionSegmentId, idempotencyKey, reason, items)).size();
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseDailyReportConsumption(
            UUID planId,
            UUID dailyReportId,
            String idempotencyKey,
            String reason) {
        // 只冲销「本单还没被冲销过」的剩余量：有人先在材料台账里手工冲销过一部分时，
        // 这里再按原额冲一次会把台账冲成负数，数据库守恒守卫会直接拒绝整笔红冲。
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT posting.id, posting.demand_id, posting.settlement_type,
                               posting.qty_base - COALESCE((
                                   SELECT SUM(back.qty_base)
                                   FROM production_material_settlement_postings back
                                   WHERE back.source_posting_id = posting.id), 0)
                        FROM production_material_settlement_postings posting
                        JOIN production_material_settlement_events event
                          ON event.id = posting.event_id
                        WHERE event.plan_id = :planId
                          AND event.event_type = 'POST'
                          AND event.daily_report_id = :reportId
                        ORDER BY posting.id
                        """)
                .setParameter("planId", planId)
                .setParameter("reportId", dailyReportId));
        List<ProductionMaterialSettlementRequest.Line> lines = new ArrayList<>();
        for (Object[] row : rows) {
            BigDecimal reversible = row[3] == null
                    ? BigDecimal.ZERO : new BigDecimal(row[3].toString());
            if (reversible.signum() <= 0) continue;
            ProductionMaterialSettlementRequest.Line line =
                    new ProductionMaterialSettlementRequest.Line();
            line.setDemandId((UUID) row[1]);
            line.setSettlementType((String) row[2]);
            line.setQtyBase(reversible);
            line.setSourcePostingId((UUID) row[0]);
            lines.add(line);
        }
        if (lines.isEmpty()) return;

        ProductionMaterialSettlementRequest request =
                new ProductionMaterialSettlementRequest();
        request.setIdempotencyKey(idempotencyKey);
        request.setReason(reason);
        request.setLines(lines);
        try {
            settlements.reverse(planId, request, currentUser.requireId());
        } catch (ApiException failure) {
            if (failure.getCode() == ErrorCode.FORBIDDEN) {
                throw new ApiException(
                        ErrorCode.FORBIDDEN,
                        "本单审核时登记过实际用料，红冲需要同时具备材料冲销权限");
            }
            throw failure;
        }
        stampDailyReport(planId, "REVERSE", idempotencyKey, dailyReportId);
    }

    /** 结算事件回填日报来源，供红冲反查与对账；事件行在同一事务内刚建好。 */
    private void stampDailyReport(
            UUID planId, String eventType, String idempotencyKey, UUID dailyReportId) {
        em.createNativeQuery("""
                        UPDATE production_material_settlement_events
                        SET daily_report_id = :reportId
                        WHERE plan_id = :planId
                          AND event_type = :eventType
                          AND idempotency_key = :key
                          AND daily_report_id IS NULL
                        """)
                .setParameter("reportId", dailyReportId)
                .setParameter("planId", planId)
                .setParameter("eventType", eventType)
                .setParameter("key", idempotencyKey.strip())
                .executeUpdate();
    }
}
