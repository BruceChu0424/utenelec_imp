package com.uten.imp.features.stock.allocation;

import com.uten.imp.application.port.InventoryMovementCostReference;
import com.uten.imp.application.port.InventoryMovementCostReference.WorkshopReturnKind;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Actual receiving moves physical stock and the exact original material rights together. */
@Service
@RequiredArgsConstructor
public class ProductionMaterialReturnReceiptService {
    private final EntityManager em;
    private final StockService stock;
    private final ProductionMaterialStockLedgerService ledger;
    private final SecurityContextCurrentUser user;
    private final TxSessionVars tx;

    /** The document service has acquired the merged source/destination footprint and document locks. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void apply(StockDocument document, List<StockDocumentItem> items, boolean reverse) {
        tx.bind();
        UUID actor = user.requireId();
        Map<UUID, Source> sources = sources(document, items);
        List<ProductionMaterialStockLedgerService.MaterialLine> issued = items.stream()
                .filter(item -> sources.get(item.getId()).issuePosting() != null)
                .map(item -> new ProductionMaterialStockLedgerService.MaterialLine(
                        document.getId(), item.getId(), item.getGoodsId(), item.getColorId(),
                        document.getWarehouseId(), item.getUpstreamItemId(), baseQty(item)))
                .toList();
        if (reverse) reverse(document, items, sources, issued, actor);
        else receive(document, items, sources, issued, actor);
        ledger.refreshReturnDemandStatuses(document.getId());
    }

    private void receive(StockDocument document, List<StockDocumentItem> items,
            Map<UUID, Source> sources, List<ProductionMaterialStockLedgerService.MaterialLine> issued, UUID actor) {
        Map<UUID, UUID> issueMovements = new LinkedHashMap<>();
        for (StockDocumentItem item : items) {
            Source source = sources.get(item.getId());
            if (source.issuePosting() != null) {
                issueMovements.put(item.getId(), move(document, item, source, document.getWarehouseId(),
                        (short) 6, StockService.DIR_IN, WorkshopReturnKind.RETURN_IN, null));
            } else {
                prepare(source.requestItem(), null, actor);
                UUID outgoing = move(document, item, source, source.warehouse(), (short) 8,
                        StockService.DIR_OUT, WorkshopReturnKind.DIRECT_OUT, null);
                UUID incoming = move(document, item, source, document.getWarehouseId(), (short) 7,
                        StockService.DIR_IN, WorkshopReturnKind.DIRECT_IN, outgoing);
                complete(source.requestItem(), null, incoming, outgoing, actor);
            }
        }
        if (issued.isEmpty()) return;
        var result = ledger.goodReturn(document.getId(), document.getWarehouseId(), issued, actor);
        requireNew(result);
        Map<UUID, List<UUID>> postings = returnPostings(result.eventId());
        for (StockDocumentItem item : items) {
            Source source = sources.get(item.getId());
            if (source.issuePosting() == null) continue;
            List<UUID> itemPostings = postings.get(item.getId());
            if (itemPostings == null || itemPostings.isEmpty()) throw conflict("实收缺少原领料退回事实");
            for (UUID posting : itemPostings) {
                prepare(source.requestItem(), posting, actor);
                complete(source.requestItem(), posting, issueMovements.get(item.getId()), null, actor);
            }
        }
        ledger.bindMovements(result.eventId(), issueMovements);
        stock.bindProductionMovements(result.eventId(), issueMovements);
    }

    private void reverse(StockDocument document, List<StockDocumentItem> items,
            Map<UUID, Source> sources, List<ProductionMaterialStockLedgerService.MaterialLine> issued, UUID actor) {
        requireOriginalWorkshopForReverse(document.getId());
        Map<UUID, OriginalMovement> originals = originalMovements(document.getId());
        ProductionMaterialStockLedgerService.PostingResult result = null;
        if (!issued.isEmpty()) {
            // The ledger first prepares the exact custody reversal and restores the
            // original reservation, then appends GOOD_RETURN_REVERSE. No fake ISSUE.
            result = ledger.reverseGoodReturn(document.getId(), document.getWarehouseId(), issued, actor);
            requireNew(result);
        }
        Map<UUID, UUID> issueMovements = new LinkedHashMap<>();
        for (StockDocumentItem item : items) {
            Source source = sources.get(item.getId());
            OriginalMovement original = originals.get(item.getId());
            if (original == null || !original.warehouse().equals(document.getWarehouseId())) {
                throw conflict("缺少原实际收仓流水，不能按来源位置猜测红冲仓库");
            }
            boolean wasIssued = source.issuePosting() != null;
            if (!wasIssued) {
                em.createNativeQuery("SELECT fn_prepare_reverse_workshop_return_custody(:request,NULL,:actor)")
                        .setParameter("request", source.requestItem()).setParameter("actor", actor).getSingleResult();
            }
            UUID incomingCounter = move(document, item, source, original.warehouse(),
                    (short) (wasIssued ? 6 : 7), StockService.DIR_OUT,
                    wasIssued ? WorkshopReturnKind.RETURN_REVERSE : WorkshopReturnKind.DIRECT_IN_REVERSE,
                    original.id());
            UUID outgoingCounter = wasIssued ? null : move(document, item, source, source.warehouse(),
                    (short) 8, StockService.DIR_IN, WorkshopReturnKind.DIRECT_OUT_REVERSE, incomingCounter);
            em.createNativeQuery("SELECT fn_reverse_workshop_return_custody(:request,:incoming,:outgoing,:event,:actor)")
                    .setParameter("request", source.requestItem()).setParameter("incoming", incomingCounter)
                    .setParameter("outgoing", outgoingCounter)
                    .setParameter("event", wasIssued ? result.eventId() : null)
                    .setParameter("actor", actor).getSingleResult();
            if (wasIssued) issueMovements.put(item.getId(), incomingCounter);
        }
        if (result != null) {
            ledger.bindMovements(result.eventId(), issueMovements);
            stock.bindProductionMovements(result.eventId(), issueMovements);
        }
    }

    private void requireOriginalWorkshopForReverse(UUID document) {
        boolean changed = Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS(SELECT 1 FROM production_material_return_requests request
                JOIN production_execution_segments segment ON segment.id=request.execution_segment_id
                JOIN production_material_return_request_items item ON item.request_id=request.id
                LEFT JOIN production_material_stock_postings issue ON issue.id=item.issue_posting_id
                LEFT JOIN stock_document_items issued_item ON issued_item.id=issue.stock_document_item_id
                LEFT JOIN stock_documents draw ON draw.id=issued_item.doc_id
                LEFT JOIN production_workshop_direct_transfer_items direct ON direct.id=item.direct_transfer_item_id
                LEFT JOIN production_workshop_direct_transfers transfer ON transfer.id=direct.transfer_id
                WHERE request.id=:document
                  AND CASE WHEN item.issue_posting_id IS NOT NULL THEN draw.department_id
                           ELSE transfer.workshop_department_id END IS NOT NULL
                  AND CASE WHEN item.issue_posting_id IS NOT NULL THEN draw.department_id
                           ELSE transfer.workshop_department_id END
                      IS DISTINCT FROM segment.workshop_department_id)
                """).setParameter("document", document).getSingleResult());
        if (changed) throw conflict("任务已改派车间，请先由车间负责人改回原物料所在车间，再撤回本次收仓");
    }

    private Map<UUID, Source> sources(StockDocument document, List<StockDocumentItem> items) {
        if (!"WDRAW".equals(document.getDocType()) || document.getWarehouseId() == null || items.isEmpty()) {
            throw conflict("余料收仓缺少真实收料仓库或明细");
        }
        Map<UUID, Source> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.stock_document_item_id,item.id,item.issue_posting_id,item.direct_transfer_item_id,
                    request.warehouse_id,item.qty_base
                FROM production_material_return_request_items item
                JOIN production_material_return_requests request ON request.id=item.request_id
                WHERE request.id=:document ORDER BY item.id
                """).setParameter("document", document.getId()))) {
            Source source = new Source((UUID) row[1], (UUID) row[2], (UUID) row[3], (UUID) row[4], (BigDecimal) row[5]);
            if ((source.issuePosting() == null) == (source.directTransfer() == null)
                    || result.putIfAbsent((UUID) row[0], source) != null) throw conflict("退料必须保留唯一真实来源");
        }
        if (result.size() != items.size() || items.stream().anyMatch(item ->
                !result.containsKey(item.getId()) || baseQty(item).compareTo(result.get(item.getId()).qty()) != 0)) {
            throw conflict("退料来源、数量与实际收仓明细不一致");
        }
        return result;
    }

    private Map<UUID, List<UUID>> returnPostings(UUID event) {
        Map<UUID, List<UUID>> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT stock_document_item_id,id FROM production_material_stock_postings
                WHERE event_id=:event AND posting_type='GOOD_RETURN' ORDER BY stock_document_item_id,id
                """).setParameter("event", event))) {
            result.computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>()).add((UUID) row[1]);
        }
        return result;
    }

    private Map<UUID, OriginalMovement> originalMovements(UUID document) {
        Map<UUID, OriginalMovement> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT requested.stock_document_item_id,movement.id,movement.warehouse_id
                FROM production_material_return_request_items requested
                JOIN production_workshop_material_custody_moves custody ON custody.request_item_id=requested.id
                JOIN stock_movements movement ON movement.id=custody.received_movement_id
                WHERE requested.request_id=:document AND movement.direction=1
                UNION
                SELECT link.document_item_id,movement.id,movement.warehouse_id
                FROM production_material_movement_links link
                JOIN production_material_stock_events event ON event.id=link.event_id
                JOIN stock_movements movement ON movement.id=link.movement_id
                WHERE event.stock_document_id=:document AND event.event_type='GOOD_RETURN' AND movement.direction=1
                """).setParameter("document", document))) {
            OriginalMovement movement = new OriginalMovement((UUID) row[1], (UUID) row[2]);
            OriginalMovement previous = result.putIfAbsent((UUID) row[0], movement);
            if (previous != null && !previous.equals(movement)) throw conflict("原实收流水不唯一，禁止猜测红冲来源");
        }
        return result;
    }

    private void prepare(UUID request, UUID posting, UUID actor) {
        em.createNativeQuery("SELECT fn_prepare_workshop_return_custody(:request,:posting,:actor)")
                .setParameter("request", request).setParameter("posting", posting).setParameter("actor", actor).getSingleResult();
    }

    private void complete(UUID request, UUID posting, UUID incoming, UUID outgoing, UUID actor) {
        em.createNativeQuery("SELECT * FROM fn_move_workshop_return_custody(:request,:posting,:incoming,:outgoing,:actor)")
                .setParameter("request", request).setParameter("posting", posting).setParameter("incoming", incoming)
                .setParameter("outgoing", outgoing).setParameter("actor", actor).getResultList();
    }

    private UUID move(StockDocument document, StockDocumentItem item, Source source, UUID warehouse,
            short type, short direction, WorkshopReturnKind kind, UUID linkedMovement) {
        OffsetDateTime date = document.getBillDate() == null ? OffsetDateTime.now()
                : document.getBillDate().atStartOfDay(BusinessTime.ZONE).toOffsetDateTime();
        return stock.recordMovement(new StockService.MovementRequest(date, type, "STOCK_DOC", document.getId(),
                item.getId(), item.getGoodsId(), item.getColorId(), warehouse, direction, baseQty(item),
                item.getUnitId(), item.getUnitRate(), null, item.getRemark(), item.getWeight(), null,
                new InventoryMovementCostReference.WorkshopReturn(source.requestItem(), kind, linkedMovement)));
    }

    private static BigDecimal baseQty(StockDocumentItem item) {
        if (item.getQty() == null || item.getQty().signum() <= 0
                || item.getUnitRate() != null && item.getUnitRate().signum() <= 0) throw conflict("退料数量与换算率须大于零");
        try {
            return item.getQty().multiply(item.getUnitRate() == null ? BigDecimal.ONE : item.getUnitRate())
                    .setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException failure) {
            throw conflict("退料基本数量不能按原单位精确表达");
        }
    }

    private static void requireNew(ProductionMaterialStockLedgerService.PostingResult result) {
        if (result.replayed()) throw conflict("退料已有处理记录，请刷新原单，不能重复改变库存");
    }

    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
    private record Source(UUID requestItem, UUID issuePosting, UUID directTransfer, UUID warehouse, BigDecimal qty) {}
    private record OriginalMovement(UUID id, UUID warehouse) {}
}
