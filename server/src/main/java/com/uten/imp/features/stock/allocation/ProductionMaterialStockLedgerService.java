package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.allocation.dto.ReturnableMaterialSourceRow;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Exact DRAW/WDRAW split ledger over V150 production stock allocations.
 *
 * <p>All quantities accepted here are base-unit quantities. The stock document
 * row is already locked by {@code StockDocService}; this service additionally
 * locks package, demand and reservation rows in stable order so different
 * documents cannot consume the same allocation twice.
 */
@Service
@RequiredArgsConstructor
public class ProductionMaterialStockLedgerService {

    private static final short RESERVATION_EFFECTIVE = 0;
    private static final short RESERVATION_DONE = 1;


    @Transactional(readOnly = true)
    public List<ReturnableMaterialSourceRow> returnableSources(
            UUID planId, UUID drawId) {
        if (planId == null && drawId == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "planId 与 drawId 至少提供一个");
        }
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT link.plan_id, package.id, draw.id, draw.bill_no,
                               item.id, draw.warehouse_id,
                               item.goods_id, goods.code, goods.name,
                               item.color_id, color.name,
                               item.unit_id, unit.name,
                               COALESCE(item.unit_rate, 1),
                               COALESCE(issue.issued_base, 0)
                                   / COALESCE(NULLIF(item.unit_rate, 0), 1),
                               COALESCE(ret.returned_base, 0)
                                   / COALESCE(NULLIF(item.unit_rate, 0), 1),
                               COALESCE(cap.max_return_base, 0)
                                   / COALESCE(NULLIF(item.unit_rate, 0), 1)
                        FROM stock_document_items item
                        JOIN stock_documents draw ON draw.id = item.doc_id
                        JOIN plan_draw_links link
                          ON link.draw_id = draw.id
                         AND link.is_deleted = FALSE
                        JOIN production_planning_packages package
                          ON package.plan_id = link.plan_id
                         AND package.status = 'CONFIRMED'
                         AND package.is_deleted = FALSE
                        JOIN goods ON goods.id = item.goods_id
                        LEFT JOIN colors color ON color.id = item.color_id
                        LEFT JOIN units unit ON unit.id = item.unit_id
                        LEFT JOIN LATERAL (
                            SELECT SUM(CASE p.posting_type
                                    WHEN 'ISSUE' THEN p.qty_base
                                    WHEN 'ISSUE_REVERSE' THEN -p.qty_base
                                    ELSE 0 END) AS issued_base
                            FROM production_material_stock_postings p
                            WHERE p.stock_document_item_id = item.id
                              AND p.posting_type IN (
                                  'ISSUE', 'ISSUE_REVERSE')
                        ) issue ON TRUE
                        LEFT JOIN LATERAL (
                            SELECT
                              COALESCE((
                                SELECT SUM(gr.qty_base)
                                FROM production_material_stock_postings source
                                JOIN production_material_stock_postings gr
                                  ON gr.source_posting_id = source.id
                                 AND gr.posting_type = 'GOOD_RETURN'
                                WHERE source.stock_document_item_id = item.id
                                  AND source.posting_type = 'ISSUE'
                              ), 0)
                              -
                              COALESCE((
                                SELECT SUM(rr.qty_base)
                                FROM production_material_stock_postings source
                                JOIN production_material_stock_postings gr
                                  ON gr.source_posting_id = source.id
                                 AND gr.posting_type = 'GOOD_RETURN'
                                JOIN production_material_stock_postings rr
                                  ON rr.source_posting_id = gr.id
                                 AND rr.posting_type = 'GOOD_RETURN_REVERSE'
                                WHERE source.stock_document_item_id = item.id
                                  AND source.posting_type = 'ISSUE'
                              ), 0) AS returned_base
                        ) ret ON TRUE
                        LEFT JOIN LATERAL (
                            SELECT COALESCE(SUM(LEAST(
                                       source_open.open_base,
                                       GREATEST(clearance.uncleared_qty, 0)
                                   )), 0) AS max_return_base
                            FROM (
                                SELECT source.demand_id,
                                       SUM(
                                           source.qty_base
                                           - COALESCE((
                                               SELECT SUM(issue_reverse.qty_base)
                                               FROM production_material_stock_postings issue_reverse
                                               WHERE issue_reverse.source_posting_id = source.id
                                                 AND issue_reverse.posting_type = 'ISSUE_REVERSE'
                                           ), 0)
                                           - COALESCE((
                                               SELECT SUM(good_return.qty_base)
                                               FROM production_material_stock_postings good_return
                                               WHERE good_return.source_posting_id = source.id
                                                 AND good_return.posting_type = 'GOOD_RETURN'
                                           ), 0)
                                           + COALESCE((
                                               SELECT SUM(return_reverse.qty_base)
                                               FROM production_material_stock_postings good_return
                                               JOIN production_material_stock_postings return_reverse
                                                 ON return_reverse.source_posting_id = good_return.id
                                                AND return_reverse.posting_type = 'GOOD_RETURN_REVERSE'
                                               WHERE good_return.source_posting_id = source.id
                                                 AND good_return.posting_type = 'GOOD_RETURN'
                                           ), 0)
                                       ) AS open_base
                                FROM production_material_stock_postings source
                                WHERE source.stock_document_item_id = item.id
                                  AND source.posting_type = 'ISSUE'
                                GROUP BY source.demand_id
                            ) source_open
                            JOIN v_production_material_clearance clearance
                              ON clearance.demand_id = source_open.demand_id
                            WHERE source_open.open_base > 0
                              AND clearance.uncleared_qty > 0
                        ) cap ON TRUE
                        WHERE draw.doc_type = 'DRAW'
                          AND draw.status = 1
                          AND draw.is_deleted = FALSE
                          AND COALESCE(item.unit_rate, 0) > 0
                          AND (CAST(:planId AS uuid) IS NULL
                               OR link.plan_id = CAST(:planId AS uuid))
                          AND (CAST(:drawId AS uuid) IS NULL
                               OR draw.id = CAST(:drawId AS uuid))
                          AND COALESCE(cap.max_return_base, 0) > 0
                        ORDER BY draw.bill_no, item.line_no, item.id
                        """)
                .setParameter("planId", planId)
                .setParameter("drawId", drawId))
                .stream()
                .map(row -> new ReturnableMaterialSourceRow(
                        (UUID) row[0], (UUID) row[1], (UUID) row[2],
                        (String) row[3], (UUID) row[4], (UUID) row[5],
                        (UUID) row[6], (String) row[7], (String) row[8],
                        (UUID) row[9], (String) row[10], (UUID) row[11],
                        (String) row[12], decimal(row[13]), decimal(row[14]),
                        decimal(row[15]), decimal(row[16])))
                .toList();
    }
    private final EntityManager em;
    private final TxSessionVars tx;

    @Transactional(propagation = Propagation.MANDATORY)
    public PostingResult issue(
            UUID documentId,
            UUID warehouseId,
            Collection<MaterialLine> rawLines,
            String idempotencyKey,
            UUID actorId) {
        tx.bind();
        List<MaterialLine> lines = normalize(rawLines, warehouseId, false);
        Event event = beginEvent(
                documentId, "ISSUE", idempotencyKey, hash(lines), actorId);
        if (event.replayed()) return new PostingResult(true);

        LockedPlanningPackage planningPackage = lockPackageForDraw(documentId);
        Set<UUID> touched = new LinkedHashSet<>();
        for (MaterialLine line : lines) {
            if (usesExactDemandMapping(
                    planningPackage.executionModelVersion())) {
                consume(
                        planningPackage.packageId(),
                        event.id(),
                        line,
                        actorId,
                        touched);
            } else {
                consumeLegacy(
                        planningPackage.packageId(),
                        event.id(),
                        line,
                        actorId,
                        touched);
            }
        }
        refreshDemandStatuses(touched);
        return new PostingResult(false);
    }


    @Transactional(propagation = Propagation.MANDATORY)
    public PreparedReverse prepareReverseIssue(
            UUID documentId,
            UUID warehouseId,
            Collection<MaterialLine> rawLines,
            String idempotencyKey,
            UUID actorId) {
        tx.bind();
        List<MaterialLine> lines = normalize(rawLines, warehouseId, false);
        Event event = beginEvent(
                documentId, "ISSUE_REVERSE", idempotencyKey, hash(lines), actorId);
        if (event.replayed()) {
            return new PreparedReverse(
                    event.id(), true, List.of(), actorId);
        }
        lockPackageForDraw(documentId);
        for (MaterialLine line : lines) {
            BigDecimal available = availableIssuePostings(line.documentItemId())
                    .stream()
                    .map(row -> decimal(row[3]))
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            if (available.compareTo(line.qtyBase()) < 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "反出库数量超过来源行尚未退回的已领基本量");
            }
        }
        return new PreparedReverse(
                event.id(), false, lines, actorId);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void completeReverseIssue(PreparedReverse prepared) {
        tx.bind();
        if (prepared == null || prepared.replayed()) {
            return;
        }
        Set<UUID> touched = new LinkedHashSet<>();
        for (MaterialLine line : prepared.lines()) {
            unwindIssued(
                    prepared.eventId(),
                    line,
                    "ISSUE_REVERSE",
                    prepared.actorId(),
                    touched);
        }
        refreshDemandStatuses(touched);
    }

    /**
     * WDRAW is the good-material return path. Every line must point at one
     * original DRAW item through upstream_item_id; dimensions and warehouse
     * must match exactly. Unknown historical provenance is intentionally
     * rejected instead of guessed.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public PostingResult goodReturn(
            UUID documentId,
            UUID warehouseId,
            Collection<MaterialLine> rawLines,
            UUID actorId) {
        tx.bind();
        List<MaterialLine> lines = normalize(rawLines, warehouseId, true);
        Event event = beginEvent(
                documentId,
                "GOOD_RETURN",
                "WDRAW-APPROVE-0001",
                hash(lines),
                actorId);
        if (event.replayed()) return new PostingResult(true);

        Set<UUID> touched = new LinkedHashSet<>();
        for (MaterialLine line : lines) {
            validateReturnSource(line);
            unwindIssued(event.id(), line, "GOOD_RETURN", actorId, touched);
        }
        refreshDemandStatuses(touched);
        return new PostingResult(false);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public PostingResult reverseGoodReturn(
            UUID documentId,
            UUID warehouseId,
            Collection<MaterialLine> rawLines,
            UUID actorId) {
        tx.bind();
        List<MaterialLine> lines = normalize(rawLines, warehouseId, true);
        Event event = beginEvent(
                documentId,
                "GOOD_RETURN_REVERSE",
                "WDRAW-REVERSE-0001",
                hash(lines),
                actorId);
        if (event.replayed()) return new PostingResult(true);

        Set<UUID> touched = new LinkedHashSet<>();
        for (MaterialLine line : lines) {
            validateReturnSource(line);
            restoreReturned(event.id(), line, actorId, touched);
        }
        refreshDemandStatuses(touched);
        return new PostingResult(false);
    }

    /**
     * Consumes only the demand explicitly mapped to this DRAW item.  A goods
     * match inside the same package is never sufficient once multiple
     * execution segments can require the same component.
     */
    private void consume(
            UUID packageId,
            UUID eventId,
            MaterialLine line,
            UUID actorId,
            Set<UUID> touched) {
        List<UUID> demandIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT d.id
                        FROM production_planning_package_document_items mapping
                        JOIN production_planning_package_documents header
                          ON header.package_id = mapping.package_id
                         AND header.document_type = mapping.document_type
                         AND header.document_id = mapping.document_id
                        JOIN production_material_demands d
                          ON d.id = mapping.demand_id
                        WHERE mapping.package_id = :packageId
                          AND mapping.document_type = 'DRAW'
                          AND mapping.document_id = :documentId
                          AND mapping.document_item_id = :documentItemId
                          AND d.package_id = :packageId
                          AND d.warehouse_id = :warehouseId
                          AND d.goods_id = :goodsId
                          AND d.color_id IS NOT DISTINCT FROM
                              CAST(:colorId AS uuid)
                          AND d.is_deleted = FALSE
                          AND d.status NOT IN ('RELEASED', 'REVERSED')
                          AND (
                              d.execution_segment_id IS NULL
                              OR header.execution_segment_id =
                                 d.execution_segment_id
                          )
                        ORDER BY d.id
                        FOR UPDATE OF d
                        """, UUID.class)
                .setParameter("packageId", packageId)
                .setParameter("documentId", line.documentId())
                .setParameter("documentItemId", line.documentItemId())
                .setParameter("warehouseId", line.warehouseId())
                .setParameter("goodsId", line.goodsId())
                .setParameter("colorId", line.colorId()), UUID.class);
        if (demandIds.size() != 1) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "DRAW item must map to exactly one material demand");
        }

        List<Object[]> reservations = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT r.id, r.demand_id,
                                       r.qty - r.consumed_qty
                                             - r.released_qty
                                FROM stock_reservations r
                                WHERE r.demand_id = :demandId
                                  AND r.owner_type =
                                      'PRODUCTION_MATERIAL_DEMAND'
                                  AND r.status = :effective
                                  AND r.is_deleted = FALSE
                                  AND r.qty - r.consumed_qty
                                      - r.released_qty > 0
                                ORDER BY r.supply_id, r.id
                                FOR UPDATE OF r
                                """)
                        .setParameter("demandId", demandIds.getFirst())
                        .setParameter(
                                "effective", RESERVATION_EFFECTIVE));
        BigDecimal remaining = line.qtyBase();
        for (Object[] row : reservations) {
            if (remaining.signum() <= 0) break;
            UUID reservationId = (UUID) row[0];
            UUID demandId = (UUID) row[1];
            BigDecimal chunk = remaining.min(decimal(row[2]));
            int updated = em.createNativeQuery("""
                            UPDATE stock_reservations
                            SET consumed_qty = consumed_qty + :qty,
                                status = CASE
                                    WHEN consumed_qty + :qty
                                         + released_qty = qty
                                    THEN :done ELSE :effective END,
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                              AND status = :effective
                              AND is_deleted = FALSE
                              AND qty - consumed_qty
                                  - released_qty >= :qty
                            """)
                    .setParameter("qty", chunk)
                    .setParameter("done", RESERVATION_DONE)
                    .setParameter("effective", RESERVATION_EFFECTIVE)
                    .setParameter("actorId", actorId)
                    .setParameter("id", reservationId)
                    .executeUpdate();
            if (updated != 1) concurrentConflict();
            insertPosting(
                    eventId, line.documentItemId(), demandId,
                    reservationId, null, "ISSUE", chunk, actorId);
            touched.add(demandId);
            remaining = remaining.subtract(chunk);
        }
        if (remaining.signum() > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "Exact segment material reservation is insufficient");
        }
    }

    private void consumeLegacy(
            UUID packageId,
            UUID eventId,
            MaterialLine line,
            UUID actorId,
            Set<UUID> touched) {
        List<UUID> demandIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM production_material_demands
                        WHERE package_id = :packageId
                          AND warehouse_id = :warehouseId
                          AND goods_id = :goodsId
                          AND color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                          AND is_deleted = FALSE
                          AND status NOT IN ('RELEASED', 'REVERSED')
                        ORDER BY need_date NULLS FIRST, id
                        FOR UPDATE
                        """, UUID.class)
                .setParameter("packageId", packageId)
                .setParameter("warehouseId", line.warehouseId())
                .setParameter("goodsId", line.goodsId())
                .setParameter("colorId", line.colorId()), UUID.class);
        if (demandIds.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "领料行没有匹配的有效物料需求，禁止绕过计划包发料");
        }

        List<Object[]> reservations = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT r.id, r.demand_id,
                                       r.qty - r.consumed_qty - r.released_qty
                                FROM stock_reservations r
                                JOIN production_material_demands d
                                  ON d.id = r.demand_id
                                WHERE r.demand_id IN (:demandIds)
                                  AND r.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
                                  AND r.status = :effective
                                  AND r.is_deleted = FALSE
                                  AND r.qty - r.consumed_qty - r.released_qty > 0
                                ORDER BY d.need_date NULLS FIRST,
                                         r.demand_id, r.supply_id, r.id
                                FOR UPDATE OF r
                                """)
                        .setParameter("demandIds", demandIds)
                        .setParameter("effective", RESERVATION_EFFECTIVE));
        BigDecimal remaining = line.qtyBase();
        for (Object[] row : reservations) {
            if (remaining.signum() <= 0) break;
            UUID reservationId = (UUID) row[0];
            UUID demandId = (UUID) row[1];
            BigDecimal chunk = remaining.min(decimal(row[2]));
            int updated = em.createNativeQuery("""
                            UPDATE stock_reservations
                            SET consumed_qty = consumed_qty + :qty,
                                status = CASE
                                    WHEN consumed_qty + :qty + released_qty = qty
                                    THEN :done ELSE :effective END,
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                              AND status = :effective
                              AND is_deleted = FALSE
                              AND qty - consumed_qty - released_qty >= :qty
                            """)
                    .setParameter("qty", chunk)
                    .setParameter("done", RESERVATION_DONE)
                    .setParameter("effective", RESERVATION_EFFECTIVE)
                    .setParameter("actorId", actorId)
                    .setParameter("id", reservationId)
                    .executeUpdate();
            if (updated != 1) concurrentConflict();
            insertPosting(
                    eventId, line.documentItemId(), demandId, reservationId,
                    null, "ISSUE", chunk, actorId);
            touched.add(demandId);
            remaining = remaining.subtract(chunk);
        }
        if (remaining.signum() > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "可领物料分配不足，缺少基本量 "
                            + remaining.stripTrailingZeros().toPlainString()
                            + "；已齐套部分可分批发料，缺料部分继续保留待料");
        }
    }

    private void unwindIssued(
            UUID eventId,
            MaterialLine line,
            String postingType,
            UUID actorId,
            Set<UUID> touched) {
        UUID sourceItemId = "GOOD_RETURN".equals(postingType)
                ? line.upstreamItemId()
                : line.documentItemId();
        List<Object[]> sources = availableIssuePostings(sourceItemId);
        BigDecimal remaining = line.qtyBase();
        for (Object[] row : sources) {
            if (remaining.signum() <= 0) break;
            UUID sourcePostingId = (UUID) row[0];
            UUID demandId = (UUID) row[1];
            UUID reservationId = (UUID) row[2];
            BigDecimal chunk = remaining.min(decimal(row[3]));
            lockDemand(demandId);
            lockReservation(reservationId);
            int updated = em.createNativeQuery("""
                            UPDATE stock_reservations
                            SET consumed_qty = consumed_qty - :qty,
                                status = :effective,
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                              AND is_deleted = FALSE
                              AND consumed_qty >= :qty
                            """)
                    .setParameter("qty", chunk)
                    .setParameter("effective", RESERVATION_EFFECTIVE)
                    .setParameter("actorId", actorId)
                    .setParameter("id", reservationId)
                    .executeUpdate();
            if (updated != 1) concurrentConflict();
            insertPosting(
                    eventId, line.documentItemId(), demandId, reservationId,
                    sourcePostingId, postingType, chunk, actorId);
            touched.add(demandId);
            remaining = remaining.subtract(chunk);
        }
        if (remaining.signum() > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "反出库/退料数量超过该来源行尚未退回的已领基本量");
        }
    }

    private void restoreReturned(
            UUID eventId,
            MaterialLine line,
            UUID actorId,
            Set<UUID> touched) {
        List<Object[]> returns = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT p.id, p.demand_id, p.reservation_id,
                                       p.qty_base - COALESCE((
                                           SELECT SUM(rr.qty_base)
                                           FROM production_material_stock_postings rr
                                           WHERE rr.posting_type = 'GOOD_RETURN_REVERSE'
                                             AND rr.source_posting_id = p.id
                                       ), 0) AS open_qty
                                FROM production_material_stock_postings p
                                JOIN production_material_stock_events e
                                  ON e.id = p.event_id
                                WHERE e.stock_document_id = :documentId
                                  AND p.stock_document_item_id = :itemId
                                  AND p.posting_type = 'GOOD_RETURN'
                                  AND p.qty_base > COALESCE((
                                      SELECT SUM(rr.qty_base)
                                      FROM production_material_stock_postings rr
                                      WHERE rr.posting_type = 'GOOD_RETURN_REVERSE'
                                        AND rr.source_posting_id = p.id
                                  ), 0)
                                ORDER BY p.created_at DESC, p.id DESC
                                FOR UPDATE OF p
                                """)
                        .setParameter("documentId", line.documentId())
                        .setParameter("itemId", line.documentItemId()));
        BigDecimal remaining = line.qtyBase();
        for (Object[] row : returns) {
            if (remaining.signum() <= 0) break;
            UUID returnPostingId = (UUID) row[0];
            UUID demandId = (UUID) row[1];
            UUID reservationId = (UUID) row[2];
            BigDecimal chunk = remaining.min(decimal(row[3]));
            lockDemand(demandId);
            lockReservation(reservationId);
            int updated = em.createNativeQuery("""
                            UPDATE stock_reservations
                            SET consumed_qty = consumed_qty + :qty,
                                status = CASE
                                    WHEN consumed_qty + :qty + released_qty = qty
                                    THEN :done ELSE :effective END,
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                              AND is_deleted = FALSE
                              AND consumed_qty + released_qty + :qty <= qty
                            """)
                    .setParameter("qty", chunk)
                    .setParameter("done", RESERVATION_DONE)
                    .setParameter("effective", RESERVATION_EFFECTIVE)
                    .setParameter("actorId", actorId)
                    .setParameter("id", reservationId)
                    .executeUpdate();
            if (updated != 1) concurrentConflict();
            insertPosting(
                    eventId, line.documentItemId(), demandId, reservationId,
                    returnPostingId, "GOOD_RETURN_REVERSE", chunk, actorId);
            touched.add(demandId);
            remaining = remaining.subtract(chunk);
        }
        if (remaining.signum() > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "退料红冲数量超过本退料单已审核的良品退回量");
        }
    }

    private List<Object[]> availableIssuePostings(UUID sourceItemId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT p.id, p.demand_id, p.reservation_id,
                               p.qty_base
                               - COALESCE((
                                   SELECT SUM(x.qty_base)
                                   FROM production_material_stock_postings x
                                   WHERE x.posting_type = 'ISSUE_REVERSE'
                                     AND x.source_posting_id = p.id
                               ), 0)
                               - COALESCE((
                                   SELECT SUM(x.qty_base)
                                   FROM production_material_stock_postings x
                                   WHERE x.posting_type = 'GOOD_RETURN'
                                     AND x.source_posting_id = p.id
                               ), 0)
                               + COALESCE((
                                   SELECT SUM(rr.qty_base)
                                   FROM production_material_stock_postings gr
                                   JOIN production_material_stock_postings rr
                                     ON rr.source_posting_id = gr.id
                                    AND rr.posting_type = 'GOOD_RETURN_REVERSE'
                                   WHERE gr.posting_type = 'GOOD_RETURN'
                                     AND gr.source_posting_id = p.id
                               ), 0) AS open_qty
                        FROM production_material_stock_postings p
                        WHERE p.stock_document_item_id = :itemId
                          AND p.posting_type = 'ISSUE'
                          AND p.qty_base
                              - COALESCE((
                                  SELECT SUM(x.qty_base)
                                  FROM production_material_stock_postings x
                                  WHERE x.posting_type = 'ISSUE_REVERSE'
                                    AND x.source_posting_id = p.id
                              ), 0)
                              - COALESCE((
                                  SELECT SUM(x.qty_base)
                                  FROM production_material_stock_postings x
                                  WHERE x.posting_type = 'GOOD_RETURN'
                                    AND x.source_posting_id = p.id
                              ), 0)
                              + COALESCE((
                                  SELECT SUM(rr.qty_base)
                                  FROM production_material_stock_postings gr
                                  JOIN production_material_stock_postings rr
                                    ON rr.source_posting_id = gr.id
                                   AND rr.posting_type = 'GOOD_RETURN_REVERSE'
                                  WHERE gr.posting_type = 'GOOD_RETURN'
                                    AND gr.source_posting_id = p.id
                              ), 0) > 0
                        ORDER BY p.created_at DESC, p.id DESC
                        FOR UPDATE OF p
                        """).setParameter("itemId", sourceItemId));
    }

    private void validateReturnSource(MaterialLine line) {
        if (line.upstreamItemId() == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "生产良品退料必须逐行选择原领料明细，禁止按货品猜测来源");
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT source.goods_id, source.color_id,
                                       draw.warehouse_id, draw.status,
                                       source.unit_id, source.unit_rate,
                                       returned.unit_id, returned.unit_rate
                                FROM stock_document_items source
                                JOIN stock_documents draw ON draw.id = source.doc_id
                                JOIN stock_document_items returned
                                  ON returned.id = :returnItemId
                                JOIN plan_draw_links link
                                  ON link.draw_id = draw.id
                                 AND link.is_deleted = FALSE
                                JOIN production_planning_packages package
                                  ON package.plan_id = link.plan_id
                                 AND package.status = 'CONFIRMED'
                                 AND package.is_deleted = FALSE
                                JOIN production_plans plan
                                  ON plan.id = package.plan_id
                                WHERE source.id = :sourceItemId
                                  AND draw.doc_type = 'DRAW'
                                  AND draw.is_deleted = FALSE
                                ORDER BY plan.id, package.id
                                FOR UPDATE OF plan, package
                                """)
                        .setParameter("sourceItemId", line.upstreamItemId())
                        .setParameter("returnItemId", line.documentItemId()));
        if (rows.size() != 1) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "退料来源没有且仅有一个有效生产计划包，禁止自动回账");
        }
        Object[] source = rows.getFirst();
        if (!Objects.equals(source[0], line.goodsId())
                || !Objects.equals(source[1], line.colorId())
                || !Objects.equals(source[2], line.warehouseId())
                || ((Number) source[3]).shortValue() != 1
                || !Objects.equals(source[4], source[6])
                || decimal(source[5]).signum() <= 0
                || decimal(source[5]).compareTo(decimal(source[7])) != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "退料与原领料的货品、颜色、仓库、单位、换算率或有效状态不一致");
        }
    }

    private LockedPlanningPackage lockPackageForDraw(UUID documentId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT package.id, package.execution_model_version
                        FROM plan_draw_links link
                        JOIN production_planning_packages package
                          ON package.plan_id = link.plan_id
                         AND package.status = 'CONFIRMED'
                         AND package.is_deleted = FALSE
                        JOIN production_plans plan
                          ON plan.id = package.plan_id
                        WHERE link.draw_id = :documentId
                          AND link.is_deleted = FALSE
                        ORDER BY plan.id, package.id
                        FOR UPDATE OF plan, package
                        """)
                        .setParameter("documentId", documentId));
        if (rows.size() != 1) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "领料单没有且仅有一个有效生产计划包，禁止发料");
        }
        Object[] row = rows.getFirst();
        return new LockedPlanningPackage(
                (UUID) row[0], ((Number) row[1]).shortValue());
    }

    static boolean usesExactDemandMapping(short executionModelVersion) {
        if (executionModelVersion == 1) {
            return true;
        }
        if (executionModelVersion == 0) {
            return false;
        }
        throw new ApiException(
                ErrorCode.CONFLICT,
                "Unsupported production execution model version");
    }

    private Event beginEvent(
            UUID documentId,
            String eventType,
            String rawKey,
            String requestHash,
            UUID actorId) {
        String key = normalizeKey(rawKey);
        List<Object[]> existing = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, request_hash
                                FROM production_material_stock_events
                                WHERE stock_document_id = :documentId
                                  AND event_type = :eventType
                                  AND idempotency_key = :key
                                FOR UPDATE
                                """)
                        .setParameter("documentId", documentId)
                        .setParameter("eventType", eventType)
                        .setParameter("key", key));
        if (!existing.isEmpty()) {
            if (!Objects.equals(existing.getFirst()[1], requestHash)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "相同幂等键对应不同领退料请求");
            }
            return new Event((UUID) existing.getFirst()[0], true);
        }
        UUID id = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO production_material_stock_events(
                            id, stock_document_id, event_type, idempotency_key,
                            request_hash, created_at, created_by
                        ) VALUES (
                            :id, :documentId, :eventType, :key,
                            :requestHash, now(), :actorId
                        )
                        """)
                .setParameter("id", id)
                .setParameter("documentId", documentId)
                .setParameter("eventType", eventType)
                .setParameter("key", key)
                .setParameter("requestHash", requestHash)
                .setParameter("actorId", actorId)
                .executeUpdate();
        return new Event(id, false);
    }

    private void insertPosting(
            UUID eventId,
            UUID itemId,
            UUID demandId,
            UUID reservationId,
            UUID sourcePostingId,
            String postingType,
            BigDecimal qty,
            UUID actorId) {
        em.createNativeQuery("""
                        INSERT INTO production_material_stock_postings(
                            id, event_id, stock_document_item_id, demand_id,
                            reservation_id, source_posting_id, posting_type,
                            qty_base, created_at, created_by
                        ) VALUES (
                            gen_random_uuid(), :eventId, :itemId, :demandId,
                            :reservationId, :sourcePostingId, :postingType,
                            :qty, now(), :actorId
                        )
                        """)
                .setParameter("eventId", eventId)
                .setParameter("itemId", itemId)
                .setParameter("demandId", demandId)
                .setParameter("reservationId", reservationId)
                .setParameter("sourcePostingId", sourcePostingId)
                .setParameter("postingType", postingType)
                .setParameter("qty", qty)
                .setParameter("actorId", actorId)
                .executeUpdate();
    }

    /**
     * Accounting writers lock demand before reservation. Settlement uses the
     * same order, preventing return-vs-issue deadlocks while preserving one
     * serialization point for the clearance equation.
     */
    private void lockDemand(UUID demandId) {
        List<?> locked = em.createNativeQuery("""
                        SELECT id FROM production_material_demands
                        WHERE id = :id AND is_deleted = FALSE
                        FOR UPDATE
                        """).setParameter("id", demandId).getResultList();
        if (locked.size() != 1) concurrentConflict();
    }

    private void lockReservation(UUID reservationId) {
        List<?> locked = em.createNativeQuery("""
                        SELECT id
                        FROM stock_reservations
                        WHERE id = :id
                          AND owner_type = 'PRODUCTION_MATERIAL_DEMAND'
                          AND is_deleted = FALSE
                        FOR UPDATE
                        """)
                .setParameter("id", reservationId)
                .getResultList();
        if (locked.size() != 1) concurrentConflict();
    }

    private void refreshDemandStatuses(Set<UUID> ids) {
        if (ids.isEmpty()) return;
        em.createNativeQuery("""
                        WITH coverage AS (
                            SELECT d.id, d.required_qty, d.released_qty,
                                   COALESCE((
                                       SELECT SUM(r.qty - r.released_qty)
                                       FROM stock_reservations r
                                       WHERE r.demand_id = d.id
                                         AND r.is_deleted = FALSE
                                   ), 0) AS stock_committed,
                                   COALESCE((
                                       SELECT SUM(
                                           p.allocated_qty - p.consumed_qty
                                             - p.released_qty)
                                       FROM production_material_supply_pegs p
                                       WHERE p.demand_id = d.id
                                         AND p.status <> 'REVERSED'
                                   ), 0) AS supply_committed,
                                   COALESCE((
                                       SELECT SUM(r.consumed_qty)
                                       FROM stock_reservations r
                                       WHERE r.demand_id = d.id
                                         AND r.is_deleted = FALSE
                                   ), 0) AS fulfilled
                            FROM production_material_demands d
                            WHERE d.id IN (:ids)
                        )
                        UPDATE production_material_demands d
                        SET status = CASE
                                WHEN c.released_qty >= c.required_qty THEN 'RELEASED'
                                WHEN c.fulfilled >= c.required_qty THEN 'FULFILLED'
                                WHEN c.stock_committed + c.supply_committed
                                     >= c.required_qty
                                     AND c.supply_committed > 0
                                     THEN 'WAITING_SUPPLY'
                                WHEN c.stock_committed >= c.required_qty
                                     THEN 'ALLOCATED'
                                WHEN c.stock_committed + c.supply_committed > 0
                                     THEN 'PARTIAL'
                                ELSE 'OPEN'
                            END,
                            lock_version = lock_version + 1,
                            updated_at = now()
                        FROM coverage c
                        WHERE d.id = c.id
                        """)
                .setParameter("ids", ids)
                .executeUpdate();
    }

    private static List<MaterialLine> normalize(
            Collection<MaterialLine> rawLines,
            UUID expectedWarehouseId,
            boolean requireUpstream) {
        if (expectedWarehouseId == null || rawLines == null || rawLines.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "领退料必须指定仓库且至少包含一条明细");
        }
        Map<LineKey, BigDecimal> totals = new LinkedHashMap<>();
        Map<LineKey, MaterialLine> samples = new LinkedHashMap<>();
        for (MaterialLine line : rawLines) {
            if (line == null
                    || line.documentId() == null
                    || line.documentItemId() == null
                    || line.goodsId() == null
                    || !expectedWarehouseId.equals(line.warehouseId())
                    || line.qtyBase() == null
                    || line.qtyBase().signum() <= 0
                    || (requireUpstream && line.upstreamItemId() == null)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "领退料明细缺少来源、货品、仓库或正数基本量");
            }
            LineKey key = new LineKey(
                    line.documentItemId(),
                    line.goodsId(),
                    line.colorId(),
                    line.upstreamItemId());
            samples.putIfAbsent(key, line);
            totals.merge(key, line.qtyBase(), BigDecimal::add);
        }
        List<MaterialLine> result = new ArrayList<>();
        totals.forEach((key, qty) -> {
            MaterialLine sample = samples.get(key);
            result.add(new MaterialLine(
                    sample.documentId(),
                    sample.documentItemId(),
                    sample.goodsId(),
                    sample.colorId(),
                    sample.warehouseId(),
                    sample.upstreamItemId(),
                    qty));
        });
        result.sort(Comparator
                .comparing(MaterialLine::goodsId)
                .thenComparing(
                        MaterialLine::colorId,
                        Comparator.nullsFirst(Comparator.naturalOrder()))
                .thenComparing(MaterialLine::documentItemId));
        return List.copyOf(result);
    }

    private static String hash(List<MaterialLine> lines) {
        StringBuilder canonical = new StringBuilder();
        for (MaterialLine line : lines) {
            canonical.append(line.documentItemId()).append('|')
                    .append(line.goodsId()).append('|')
                    .append(line.colorId()).append('|')
                    .append(line.warehouseId()).append('|')
                    .append(line.upstreamItemId()).append('|')
                    .append(line.qtyBase().stripTrailingZeros().toPlainString())
                    .append('\n');
        }
        try {
            return HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256")
                            .digest(canonical.toString()
                                    .getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 unavailable", impossible);
        }
    }

    private static String normalizeKey(String key) {
        if (key == null || key.isBlank()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "领退料必须提供幂等键");
        }
        String normalized = key.strip();
        if (normalized.length() < 8 || normalized.length() > 128) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "领退料幂等键长度必须为 8 到 128 个字符");
        }
        return normalized;
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal number) return number;
        return new BigDecimal(value.toString());
    }

    private static void concurrentConflict() {
        throw new ApiException(
                ErrorCode.CONFLICT,
                "生产物料占用已被并发修改，请刷新后重试");
    }

    public record MaterialLine(
            UUID documentId,
            UUID documentItemId,
            UUID goodsId,
            UUID colorId,
            UUID warehouseId,
            UUID upstreamItemId,
            BigDecimal qtyBase) {
    }

    public record PostingResult(boolean replayed) {
    }

    private record Event(UUID id, boolean replayed) {
    }

    private record LockedPlanningPackage(
            UUID packageId, short executionModelVersion) {
    }

    public record PreparedReverse(
            UUID eventId,
            boolean replayed,
            List<MaterialLine> lines,
            UUID actorId) {
    }
    private record LineKey(
            UUID itemId, UUID goodsId, UUID colorId, UUID upstreamItemId) {
    }
}
