package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.ProductionFinishedInboundReleasePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.StockGoodsSnapshot;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Builds the warehouse FINISHED_IN drafts for the exact FQC PASS decisions of one command.
 *
 * <p>ADR-148 实物交接批：同一报工、同一登记批次(同仓、同先入库口径)、同一生产计划的放行合成一张
 * 入库单，一份一行(行上仍是精确的报工切片、销售分摊、公共/超产来源)，计划关联与待点收通知各一次；
 * 不同计划仍各一张(不跨计划合单)。</p>
 *
 * <p>The source report, plan line and execution segment are re-read under
 * locks. Mutable numbers or goods names never establish identity.</p>
 */
@Service
@RequiredArgsConstructor
public class ProductionFqcFinishedInboundService
        implements ProductionFinishedInboundReleasePort {

    private final EntityManager em;
    private final StockDocumentRepository documentRepository;
    private final StockDocumentItemRepository itemRepository;
    private final DocNumberService docNumberService;
    private final SecurityContextCurrentUser currentUser;
    private final ChainNoticeService chainNotice;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public Map<UUID, CreatedDraft> createReleasedDrafts(List<ReleaseRequest> requests) {
        if (requests == null || requests.isEmpty()) return Map.of();
        Map<UUID, ReleaseRequest> byDecision = new LinkedHashMap<>();
        for (ReleaseRequest request : requests) {
            if (request == null
                    || request.inspectionId() == null
                    || request.decisionEventId() == null
                    || request.sourceReportId() == null
                    || request.sourceReportItemId() == null) {
                throw validation("FQC 合格入库缺少来源 UUID");
            }
            BigDecimal quantity = request.quantity();
            if (quantity == null
                    || quantity.signum() <= 0
                    || quantity.scale() > 4) {
                throw validation("FQC 合格入库数量必须为最多 4 位小数的正数");
            }
            if (byDecision.putIfAbsent(request.decisionEventId(), request) != null) {
                throw validation("同一 FQC 合格决定不能重复放行");
            }
        }

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT report.id, report.status,
                               inspection.warehouse_id, report.bill_no,
                               report.worker_id, report.maker_id,
                               report_item.id, report_item.plan_item_id,
                               report_item.execution_segment_id,
                               report_item.execution_segment_sales_allocation_id,
                               report_item.goods_id, report_item.color_id,
                               report_item.unit_id,
                               COALESCE(report_item.unit_rate, 1),
                               plan_item.plan_id, plan.bill_no,
                               report_item.qty,
                               segment.status,
                               inspection.id,
                               decision.id,
                               registration_item.place_snapshot,
                               registration_item.weight,
                               COALESCE((
                                   SELECT SUM(prior.pass_qty)
                                   FROM production_fqc_decision_events prior
                                   WHERE prior.inspection_id = inspection.id
                                     AND (prior.decided_at < decision.decided_at
                                          OR (prior.decided_at = decision.decided_at
                                              AND prior.id < decision.id))
                               ), 0) AS prior_pass_qty,
                               decision.pass_qty,
                               registration_item.registration_id,
                               COALESCE(registration.stock_in_before_inspection, FALSE)
                                   AND COALESCE(fn_finished_arrival_count_is_proven(registration_item.id), FALSE)
                                   AS pre_stocked_auto_confirm,
                               report_item.line_no,
                               fn_daily_report_output_slice_rank(
                                   report_item.is_public_output, report_item.is_actual_surplus) AS slice_rank
                        FROM production_daily_reports report
                        JOIN production_daily_report_items report_item
                          ON report_item.report_id = report.id
                         AND report_item.is_deleted = FALSE
                        JOIN production_plan_items plan_item
                          ON plan_item.id = report_item.plan_item_id
                         AND plan_item.is_deleted = FALSE
                        JOIN production_plans plan
                          ON plan.id = plan_item.plan_id
                         AND plan.is_deleted = FALSE
                        JOIN production_execution_segments segment
                          ON segment.id = report_item.execution_segment_id
                         AND segment.is_deleted = FALSE
                        JOIN production_fqc_inspections inspection
                          ON inspection.source_report_id = report.id
                         AND inspection.source_report_item_id = report_item.id
                        JOIN production_fqc_decision_events decision
                          ON decision.inspection_id = inspection.id
                        LEFT JOIN production_finished_arrival_registration_items
                                  registration_item
                          ON registration_item.source_report_item_id = report_item.id
                         AND registration_item.reversal_id IS NULL
                        LEFT JOIN production_finished_arrival_registrations registration
                          ON registration.id = registration_item.registration_id
                        WHERE decision.id IN (:decisionIds)
                          AND report.status = 1
                          AND report.is_deleted = FALSE
                          AND inspection.warehouse_id IS NOT NULL
                          AND report.maker_id IS NOT NULL
                          AND plan.status = 1
                          AND plan.is_closed = FALSE
                          AND plan.is_canceled = FALSE
                          AND plan.is_stopped = FALSE
                          AND segment.status = 'IN_PROGRESS'
                        ORDER BY report.id, report_item.id
                        FOR UPDATE OF report, report_item, plan_item,
                                      plan, segment, inspection, decision
                        """)
                .setParameter("decisionIds", List.copyOf(byDecision.keySet()))
                .getResultList();
        if (rows.size() != byDecision.size()) {
            throw conflict(
                    "FQC 合格放行与报工、计划或执行段状态不一致，未生成入库任务");
        }
        // 同一实物交接(报工 + 登记批次 + 成品仓 + 计划 + 先入库口径)一张单；单内按报工行、归属顺序排行。
        Map<HandoffKey, List<Object[]>> handoffs = new LinkedHashMap<>();
        for (Object[] row : rows) {
            ReleaseRequest request = byDecision.get((UUID) row[19]);
            if (request == null
                    || !request.inspectionId().equals(row[18])
                    || !request.sourceReportId().equals(row[0])
                    || !request.sourceReportItemId().equals(row[6])
                    || ((BigDecimal) row[23]).compareTo(request.quantity()) != 0) {
                throw conflict(
                        "FQC 合格放行与报工、计划或执行段状态不一致，未生成入库任务");
            }
            if (((BigDecimal) row[13]).signum() <= 0) {
                throw conflict("报工单位换算率无效，禁止生成合格入库");
            }
            handoffs.computeIfAbsent(new HandoffKey(
                            (UUID) row[0], (UUID) row[24], (UUID) row[2], (UUID) row[14],
                            Boolean.TRUE.equals(row[25])),
                    ignored -> new ArrayList<>()).add(row);
        }
        Map<UUID, StockGoodsSnapshot> goodsSnapshots =
                StockGoodsSnapshot.fromMaster(
                        em,
                        rows.stream().map(row -> (UUID) row[10]).distinct().toList(),
                        StockGoodsSnapshot.MASTER_AT_SAVE);
        Map<UUID, CreatedDraft> result = new LinkedHashMap<>();
        UUID actorId = currentUser.requireId();
        for (Map.Entry<HandoffKey, List<Object[]>> handoff : handoffs.entrySet()) {
            List<Object[]> lines = new ArrayList<>(handoff.getValue());
            lines.sort(Comparator
                    .comparingInt((Object[] row) -> row[26] == null ? Integer.MAX_VALUE : ((Number) row[26]).intValue())
                    .thenComparingInt(row -> ((Number) row[27]).intValue())
                    .thenComparing(row -> row[6].toString()));
            Object[] head = lines.getFirst();
            StockDocument document = new StockDocument();
            document.setDocType("FINISHED_IN");
            document.setBillNo(docNumberService.nextNumber(
                    DocNumberPrefix.STOCK_FINISHED_IN));
            document.setBillDate(BusinessTime.today());
            document.setWarehouseId((UUID) head[2]);
            document.setPlanNo((String) head[15]);
            document.setSourceDailyReportId((UUID) head[0]);
            document.setSourceDocNo((String) head[3]);
            document.setRemark(
                    "FQC 合格放行 · 报工 " + head[3]);
            document.setWorkerId(
                    head[4] == null ? (UUID) head[5] : (UUID) head[4]);
            document.setMakerId((UUID) head[5]);
            document.setStatus((short) 0);
            documentRepository.saveAndFlush(document);

            int lineNo = 0;
            for (Object[] row : lines) {
                BigDecimal quantity = (BigDecimal) row[23];
                UUID goodsId = (UUID) row[10];
                BigDecimal unitRate = (BigDecimal) row[13];
                StockDocumentItem item = new StockDocumentItem();
                item.setDocId(document.getId());
                item.setBillType("FINISHED_IN");
                item.setBillNo(document.getBillNo());
                item.setBillDate(document.getBillDate());
                item.setLineNo(++lineNo);
                item.setGoodsId(goodsId);
                StockGoodsSnapshot.require(
                                goodsSnapshots, goodsId, "FQC 合格入库明细")
                        .applyTo(item, null);
                item.setColorId((UUID) row[11]);
                item.setUnitId((UUID) row[12]);
                item.setUnitRate(unitRate);
                item.setQty(quantity);
                item.setReportedQty(quantity);
                item.setBaseQty(quantity.multiply(unitRate));
                // 重量只认仓库登记时的实称(ADR-135 §3.2): 按本次放行在报工量里的累计区间分摊,
                // 没称的登记行草稿重量为空, 由库存账按均重/单重推算; 报工单自己的重量列不进库存账。
                item.setWeight(proratedActualWeight(
                        (BigDecimal) row[21], (BigDecimal) row[16],
                        (BigDecimal) row[22], quantity));
                item.setUpstreamItemId((UUID) row[7]);
                item.setExecutionSegmentId((UUID) row[8]);
                item.setExecutionSegmentSalesAllocationId((UUID) row[9]);
                item.setSourceDailyReportItemId((UUID) row[6]);
                item.setSourceDocNo((String) row[3]);
                item.setPlace((String) row[20]);
                itemRepository.saveAndFlush(item);
                result.put((UUID) row[19], new CreatedDraft(
                        document.getId(), item.getId(), handoff.getKey().preStockedAutoConfirm()));
            }

            em.createNativeQuery("""
                            INSERT INTO plan_draw_links(
                                plan_id, draw_id, created_by)
                            VALUES (:planId, :documentId, :actorId)
                            """)
                    .setParameter("planId", handoff.getKey().planId())
                    .setParameter("documentId", document.getId())
                    .setParameter("actorId", actorId)
                    .executeUpdate();
            chainNotice.notifyFinishedInboundPending(document.getId());
        }
        return result;
    }

    /** 一次实物交接 = 一张入库单的身份。 */
    private record HandoffKey(
            UUID reportId,
            UUID registrationId,
            UUID warehouseId,
            UUID planId,
            boolean preStockedAutoConfirm) {
    }

    static BigDecimal proratedActualWeight(
            BigDecimal totalWeight,
            BigDecimal reportedQty,
            BigDecimal priorPassQty,
            BigDecimal passQty) {
        if (totalWeight == null) return null;
        if (totalWeight.signum() < 0
                || reportedQty == null || reportedQty.signum() <= 0
                || priorPassQty == null || priorPassQty.signum() < 0
                || passQty == null || passQty.signum() <= 0
                || priorPassQty.add(passQty).compareTo(reportedQty) > 0) {
            throw conflict("登记实称重量或 FQC 放行比例无效");
        }
        BigDecimal previous = totalWeight.multiply(priorPassQty)
                .divide(reportedQty, 4, RoundingMode.HALF_UP);
        BigDecimal next = totalWeight.multiply(priorPassQty.add(passQty))
                .divide(reportedQty, 4, RoundingMode.HALF_UP);
        return next.subtract(previous);
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
