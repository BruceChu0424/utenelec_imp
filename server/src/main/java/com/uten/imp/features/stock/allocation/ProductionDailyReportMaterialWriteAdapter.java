package com.uten.imp.features.stock.allocation;

import com.uten.imp.application.port.ProductionMaterialConsumptionWritePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.CanonicalFingerprint;
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
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产日报审核/红冲 → 材料结算与余料退仓的写侧适配器(V583；实盘收尾的账面可用见 ADR-129 §2.7)。
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
    private final ProductionMaterialTaskAccessPolicy taskAccess;

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

        settlements.postForDailyReport(planId, request, currentUser.requireId());
        stampDailyReport(planId, "POST", idempotencyKey, dailyReportId);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public Map<UUID, BigDecimal> bookAvailableByDemand(UUID planId, UUID executionSegmentId) {
        return settlements.bookAvailableByDemand(planId, executionSegmentId);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public MaterialReviewScope reviewForDailyReport(UUID planId, UUID executionSegmentId,
            List<ConsumptionLine> usages, boolean lockSources) {
        taskAccess.readable(planId, executionSegmentId);
        if (lockSources) {
            em.createNativeQuery("SELECT id FROM production_plans WHERE id=:id FOR UPDATE")
                    .setParameter("id", planId).getResultList();
            em.createNativeQuery("SELECT id FROM production_execution_segments WHERE id=:id FOR UPDATE")
                    .setParameter("id", executionSegmentId).getResultList();
            em.createNativeQuery("""
                    SELECT id FROM production_material_demands
                    WHERE plan_id=:plan AND execution_segment_id=:segment AND NOT is_deleted
                    ORDER BY id FOR UPDATE
                    """).setParameter("plan", planId).setParameter("segment", executionSegmentId).getResultList();
            em.createNativeQuery("""
                    SELECT issue.id FROM production_material_stock_postings issue
                    JOIN production_material_demands demand ON demand.id=issue.demand_id
                    WHERE demand.plan_id=:plan AND demand.execution_segment_id=:segment AND issue.posting_type='ISSUE'
                    ORDER BY issue.id FOR UPDATE OF issue
                    """).setParameter("plan", planId).setParameter("segment", executionSegmentId).getResultList();
            em.createNativeQuery("""
                    SELECT direct.id FROM production_workshop_direct_transfer_items direct
                    JOIN production_material_demands demand ON direct.to_demand_id IN(demand.id,demand.split_root_demand_id)
                    WHERE demand.plan_id=:plan AND demand.execution_segment_id=:segment
                    ORDER BY direct.id FOR UPDATE OF direct
                    """).setParameter("plan", planId).setParameter("segment", executionSegmentId).getResultList();
            em.createNativeQuery("""
                    SELECT allocation.id FROM production_workshop_direct_source_allocations allocation
                    JOIN production_workshop_direct_transfer_items direct ON direct.id=allocation.transfer_item_id
                    JOIN production_material_demands demand ON direct.to_demand_id IN(demand.id,demand.split_root_demand_id)
                    WHERE demand.plan_id=:plan AND demand.execution_segment_id=:segment
                    ORDER BY allocation.id FOR UPDATE OF allocation
                    """).setParameter("plan", planId).setParameter("segment", executionSegmentId).getResultList();
            em.createNativeQuery("""
                    SELECT held.id FROM stock_reservations held
                    JOIN production_workshop_direct_source_allocations allocation ON allocation.stock_reservation_id=held.id
                    JOIN production_workshop_direct_transfer_items direct ON direct.id=allocation.transfer_item_id
                    JOIN production_material_demands demand ON direct.to_demand_id IN(demand.id,demand.split_root_demand_id)
                    WHERE demand.plan_id=:plan AND demand.execution_segment_id=:segment
                    ORDER BY held.id FOR UPDATE OF held
                    """).setParameter("plan", planId).setParameter("segment", executionSegmentId).getResultList();
        }
        var capabilities = taskAccess.capabilities(planId, executionSegmentId);
        List<String> fingerprint = new ArrayList<>(List.of("DAILY-REPORT-MATERIAL-SOURCES-V3",
                "plan:" + planId, "segment:" + executionSegmentId,
                "canRequestReturn:" + capabilities.canRequestReturn()));
        Map<UUID, BigDecimal> registered = new LinkedHashMap<>();
        for (ConsumptionLine line : usages) registered.merge(line.demandId(), line.qtyBase(), BigDecimal::add);
        List<ProductionMaterialReturnRequest.Source> sources = returns.sources(planId, executionSegmentId);
        Map<UUID, ProductionMaterialReturnRequest.Source> issueReturns = new LinkedHashMap<>();
        Map<UUID, List<ProductionMaterialReturnRequest.Source>> directReturns = new LinkedHashMap<>();
        for (var source : sources) {
            fingerprint.add("return-source:" + source);
            if (source.issuePostingId() != null) issueReturns.put(source.issuePostingId(), source);
            else directReturns.computeIfAbsent(source.demandId(), ignored -> new ArrayList<>()).add(source);
        }
        // Total direct-returnable quantity alone cannot freeze ownership: free
        // stock can be swapped with a task reservation while the total stays equal.
        for (Object[] fact : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT direct.id,direct.xmin::text,allocation.id,allocation.stock_reservation_id,
                       allocation.effective_qty,allocation.net_issued_qty,
                       fn_workshop_allocation_pending_return_qty(allocation.id,NULL),
                       held.demand_id,held.qty,held.consumed_qty,held.released_qty,held.status,
                       held.is_deleted,held.xmin::text,lot.available_qty
                FROM production_material_demands demand
                JOIN v_workshop_direct_supply_lots lot ON lot.to_demand_id IN(demand.id,demand.split_root_demand_id)
                JOIN production_workshop_direct_transfer_items direct ON direct.id=lot.id
                LEFT JOIN v_workshop_direct_source_allocations allocation ON allocation.transfer_item_id=direct.id
                LEFT JOIN stock_reservations held ON held.id=allocation.stock_reservation_id
                WHERE demand.plan_id=:plan AND demand.execution_segment_id=:segment AND NOT demand.is_deleted
                ORDER BY direct.id,allocation.id,demand.id
                """).setParameter("plan", planId).setParameter("segment", executionSegmentId))) {
            fingerprint.add("direct-ownership:" + java.util.Arrays.toString(fact));
        }
        Map<UUID, List<IssueReviewSource>> issues = new LinkedHashMap<>();
        for (Object[] source : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT issue.id,issue.demand_id,fn_material_issue_available(issue.id,NULL),
                       issue.created_at,issue.xmin::text
                FROM production_material_stock_postings issue
                JOIN production_material_demands demand ON demand.id=issue.demand_id
                WHERE demand.plan_id=:plan AND demand.execution_segment_id=:segment
                  AND NOT demand.is_deleted AND demand.status NOT IN('RELEASED','REVERSED')
                  AND issue.posting_type='ISSUE'
                ORDER BY issue.demand_id,issue.created_at,issue.id
                """).setParameter("plan", planId).setParameter("segment", executionSegmentId))) {
            UUID issueId = (UUID) source[0];
            var returnSource = issueReturns.get(issueId);
            String blocked = returnSource == null ? "此原领料来源当前不能申请退仓"
                    : returnSource.returnBlockedReason();
            BigDecimal available = decimal(source[2]);
            issues.computeIfAbsent((UUID) source[1], ignored -> new ArrayList<>())
                    .add(new IssueReviewSource(issueId, available, blocked));
            fingerprint.add("issue:" + java.util.Arrays.toString(source) + ":blocked:" + blocked);
        }
        List<MaterialReviewRow> rows = new ArrayList<>();
        for (Object[] demand : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT demand.id,segment.segment_code,goods.code,goods.name,color.name,unit.name,
                       demand.xmin::text,segment.xmin::text,goods.xmin::text
                FROM production_material_demands demand
                JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id AND NOT segment.is_deleted
                JOIN goods ON goods.id=demand.goods_id
                LEFT JOIN colors color ON color.id=demand.color_id
                LEFT JOIN units unit ON unit.id=demand.unit_id
                WHERE demand.plan_id=:plan AND demand.execution_segment_id=:segment
                  AND NOT demand.is_deleted AND demand.status NOT IN('RELEASED','REVERSED')
                ORDER BY demand.id
                """).setParameter("plan", planId).setParameter("segment", executionSegmentId))) {
            UUID demandId = (UUID) demand[0];
            BigDecimal usage = registered.getOrDefault(demandId, BigDecimal.ZERO);
            IssueProjection projection = projectFifo(issues.getOrDefault(demandId, List.of()), usage);
            var direct = directReturns.getOrDefault(demandId, List.of());
            BigDecimal directQty = direct.stream().map(ProductionMaterialReturnRequest.Source::availableQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            if (!registered.containsKey(demandId) && projection.available().signum() == 0 && directQty.signum() == 0) continue;
            if (usage.compareTo(projection.available()) > 0) {
                throw new ApiException(ErrorCode.DAILY_REPORT_MATERIAL_REVIEW_CONFLICT,
                        "「" + demand[3] + "」本次实际用料超过当前账面可用，请返回日报核对用料");
            }
            BigDecimal remaining = projection.available().subtract(usage);
            BigDecimal returnIssued = capabilities.canRequestReturn() ? projection.returnable() : BigDecimal.ZERO;
            BigDecimal returnDirect = capabilities.canRequestReturn() ? directQty : BigDecimal.ZERO;
            boolean canReturn = returnIssued.add(returnDirect).signum() > 0;
            String blocked = null;
            if (!capabilities.canRequestReturn() && remaining.add(directQty).signum() > 0) blocked = "当前账号或任务状态不允许申请退仓";
            else if (remaining.compareTo(returnIssued) > 0) blocked = projection.blockedReason();
            else if (!canReturn) blocked = "本次用料后没有可退余料";
            rows.add(new MaterialReviewRow(demandId, (String) demand[1], (String) demand[2], (String) demand[3],
                    (String) demand[4], (String) demand[5], projection.available(), usage, remaining,
                    directQty, returnIssued, returnDirect, canReturn, blocked));
            fingerprint.add("demand:" + java.util.Arrays.toString(demand));
            fingerprint.add("usage:" + demandId + ":" + usage.stripTrailingZeros().toPlainString());
        }
        if (registered.keySet().stream().anyMatch(id -> rows.stream().noneMatch(row -> id.equals(row.demandId())))) {
            throw new ApiException(ErrorCode.DAILY_REPORT_MATERIAL_REVIEW_CONFLICT);
        }
        return new MaterialReviewScope(CanonicalFingerprint.sha256(fingerprint), List.copyOf(rows));
    }

    /** ISSUE order is exactly settlement's demand/created_at/id FIFO; blocked slices still fund consumption. */
    static IssueProjection projectFifo(List<IssueReviewSource> sources, BigDecimal usage) {
        BigDecimal available = BigDecimal.ZERO, returnable = BigDecimal.ZERO, toConsume = usage;
        String blocked = null;
        for (IssueReviewSource source : sources) {
            available = available.add(source.availableQty());
            BigDecimal used = source.availableQty().min(toConsume);
            toConsume = toConsume.subtract(used);
            BigDecimal after = source.availableQty().subtract(used);
            if (source.blockedReason() == null) returnable = returnable.add(after);
            else if (after.signum() > 0) blocked = source.blockedReason();
        }
        return new IssueProjection(available, returnable, blocked);
    }
    record IssueReviewSource(UUID id, BigDecimal availableQty, String blockedReason) { }
    record IssueProjection(BigDecimal available, BigDecimal returnable, String blockedReason) { }
    private static BigDecimal decimal(Object value) { return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString()); }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public int requestSelectedSurplusReturnForDailyReport(UUID planId, UUID executionSegmentId,
            UUID dailyReportId, String idempotencyKey, String reason, List<UUID> selectedDemandIds) {
        if (selectedDemandIds == null || selectedDemandIds.isEmpty()) return 0;
        List<ProductionMaterialReturnRequest.Item> items = returnableSources(planId, executionSegmentId).stream()
                .filter(source -> selectedDemandIds.contains(source.demandId()))
                .map(source -> new ProductionMaterialReturnRequest.Item(source.issuePostingId(),
                        source.availableQty(), source.directTransferItemId())).toList();
        if (items.isEmpty()) throw new ApiException(ErrorCode.DAILY_REPORT_MATERIAL_REVIEW_CONFLICT);
        // The public return command enforces a bounded batch; split exact sources deterministically.
        int count = 0;
        for (int start = 0; start < items.size(); start += 200) {
            List<ProductionMaterialReturnRequest.Item> chunk = items.subList(start, Math.min(start + 200, items.size()));
            count += returns.submit(planId, new ProductionMaterialReturnRequest.Submit(executionSegmentId,
                    idempotencyKey + "-" + (start / 200), reason, chunk)).size();
        }
        return count;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public int requestSurplusReturnForDailyReport(
            UUID planId,
            UUID executionSegmentId,
            UUID dailyReportId,
            String idempotencyKey,
            String reason) {
        List<ProductionMaterialReturnRequest.Item> items = returnableSources(planId, executionSegmentId).stream()
                .map(source -> new ProductionMaterialReturnRequest.Item(
                        source.issuePostingId(), source.availableQty(), source.directTransferItemId()))
                .toList();
        if (items.isEmpty()) return 0;
        return returns.submit(planId, new ProductionMaterialReturnRequest.Submit(
                executionSegmentId, idempotencyKey, reason, items)).size();
    }

    /**
     * 该执行段当前可退的余料来源(原领料过账或线边仓直送批次)。可退量与单位换算全部由服务端给：
     * clearance 是基本量，退料单走原领料单位(unit_rate 不为 1 时两者不等)，调用方不得自己换算差额。
     */
    private List<ProductionMaterialReturnRequest.Source> returnableSources(UUID planId, UUID executionSegmentId) {
        return returns.sources(planId, executionSegmentId).stream()
                .filter(source -> source.returnBlockedReason() == null)
                .filter(source -> source.availableQty() != null
                        && source.availableQty().signum() > 0)
                .toList();
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
            settlements.reverseForDailyReport(planId, request, currentUser.requireId());
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
