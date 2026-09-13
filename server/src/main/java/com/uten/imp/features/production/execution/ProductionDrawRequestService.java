package com.uten.imp.features.production.execution;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import static com.uten.imp.features.production.execution.ProductionDrawRequest.*;

/** Records workshop intent without issuing inventory or changing material allocation. */
@Service
@RequiredArgsConstructor
public class ProductionDrawRequestService {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionWorkshopMembership membership;
    private final ChainNoticeService notices;

    @Transactional(readOnly = true)
    public Preview preview(PreviewRequest request) {
        List<Item> items = normalize(request == null ? null : request.items(), false);
        List<Segment> segments = segments(items);
        requireAccess(segments);
        return buildPreview(items, segments);
    }

    @Transactional
    public Result submit(SubmitRequest request) {
        List<Item> items = normalize(request == null ? null : request.items(), true);
        if (request.idempotencyKey() == null
                || !request.idempotencyKey().matches("[A-Za-z0-9._:-]{8,128}")
                || request.previewFingerprint() == null
                || !request.previewFingerprint().matches("[0-9a-f]{64}")) {
            throw validation("领料提交缺少有效幂等键或汇总版本，请重新打开领料汇总");
        }
        tx.bind();
        // Same actor/key serializes complete batch replays, including disjoint changed members.
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key, 559))")
                .setParameter("key", currentUser.requireId() + ":DRAW_REQUEST:" + request.idempotencyKey())
                .getSingleResult();
        List<Segment> before = segments(items);
        requireAccess(before);
        String requestHash = selectionRequestHash(items, request.previewFingerprint(), request.lines());
        Result replay = replay(request.idempotencyKey(), requestHash, items);
        if (replay != null) return replay;
        // No inventory is mutated. Preserve established upstream -> segment -> document order.
        lockRows("production_plans", before.stream().map(Segment::planId).distinct().sorted().toList());
        lockRows("production_planning_packages", before.stream().map(Segment::packageId).distinct().sorted().toList());
        lockRows("production_execution_segments", items.stream().map(Item::segmentId).toList());
        List<Segment> locked = segments(items);
        requireAccess(locked); // Assignment or plan state may have changed while acquiring locks.
        List<UUID> drawIds = documentIds(items.stream().map(Item::segmentId).toList());
        if (drawIds.isEmpty()) throw conflict("任务没有有效领料明细，请刷新车间任务");
        lockRows("stock_documents", drawIds);
        Preview preview = buildPreview(items, locked);
        if (!Objects.equals(preview.fingerprint(), request.previewFingerprint())) {
            throw conflict("领料汇总已变化，请刷新后重新核对物料和实际仓库");
        }
        List<Line> selectedLines = selectLines(preview.lines(), request.lines());
        List<UUID> submittedDrawIds = selectedLines.stream().map(Line::drawId).distinct().sorted().toList();
        List<UUID> submittedSegments = selectedLines.stream().map(Line::segmentId).distinct().sorted().toList();
        for (Task task : preview.tasks()) {
            if (!submittedSegments.contains(task.segmentId())) continue;
            int changed = em.createNativeQuery("""
                    UPDATE production_execution_segments SET lock_version=lock_version+1,
                        updated_at=now(), updated_by=:actor
                    WHERE id=:id AND lock_version=:version AND status IN ('READY','DISPATCHED')
                      AND is_deleted=FALSE
                    """).setParameter("actor", currentUser.requireId())
                    .setParameter("id", task.segmentId()).setParameter("version", task.expectedVersion())
                    .executeUpdate();
            if (changed != 1) throw conflict("车间任务已变化，请刷新后重新领料");
            List<UUID> taskDocuments = selectedLines.stream()
                    .filter(line -> line.segmentId().equals(task.segmentId()))
                    .map(Line::drawId).distinct().sorted().toList();
            em.createNativeQuery("""
                    INSERT INTO production_execution_segment_events(
                        execution_segment_id, action, idempotency_key, request_hash,
                        expected_version, resulting_version, created_by, draw_document_ids, draw_item_quantities)
                    VALUES (:id, 'DRAW_REQUEST', :key, :hash, :version, :resultVersion,
                            :actor, CAST(:documents AS uuid[]), CAST(:quantities AS jsonb))
                    """).setParameter("id", task.segmentId())
                    .setParameter("key", request.idempotencyKey()).setParameter("hash", requestHash)
                    .setParameter("version", task.expectedVersion())
                    .setParameter("resultVersion", task.expectedVersion() + 1)
                    .setParameter("actor", currentUser.requireId())
                    .setParameter("documents", uuidArray(taskDocuments))
                    .setParameter("quantities", quantitiesJson(selectedLines.stream()
                            .filter(line -> line.segmentId().equals(task.segmentId())).toList())).executeUpdate();
        }
        submittedDrawIds.forEach(notices::notifyProductionDrawPending);
        notices.resolveProductionWorkshopTasks(submittedSegments, "DRAW_REQUESTED");
        return result(submittedSegments, submittedDrawIds, false);
    }

    static List<Item> normalize(List<Item> items, boolean requireVersion) {
        if (items == null || items.isEmpty() || items.size() > 50) {
            throw validation("批量领料必须选择 1-50 个车间任务");
        }
        Map<UUID, Item> distinct = new LinkedHashMap<>();
        for (Item item : items) {
            if (item == null || item.segmentId() == null
                    || (requireVersion && item.expectedVersion() == null)
                    || (item.expectedVersion() != null && item.expectedVersion() < 0)) {
                throw validation("领料任务缺少有效标识或版本");
            }
            if (distinct.putIfAbsent(item.segmentId(), item) != null) {
                throw validation("同一车间任务不能重复选择");
            }
        }
        return distinct.values().stream().sorted(Comparator.comparing(Item::segmentId)).toList();
    }

    private List<Segment> segments(List<Item> items) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT segment.id, segment.plan_id, segment.package_id, segment.status,
                       segment.lock_version, segment.workshop_department_id,
                       segment.responsible_employee_id, plan.maker_id,
                       package.status, plan.status, plan.is_closed, plan.is_canceled, plan.is_stopped,
                       segment.material_requirement_mode,
                       plan.bill_no, segment.segment_code, department.name,
                       goods.code, goods.name, segment.planned_qty
                FROM production_execution_segments segment
                JOIN production_plans plan ON plan.id=segment.plan_id AND NOT plan.is_deleted
                JOIN production_planning_packages package ON package.id=segment.package_id AND NOT package.is_deleted
                LEFT JOIN departments department ON department.id=segment.workshop_department_id
                LEFT JOIN goods ON goods.id=segment.product_goods_id
                WHERE segment.id IN (:ids) AND NOT segment.is_deleted
                ORDER BY segment.id
                """).setParameter("ids", items.stream().map(Item::segmentId).toList()));
        if (rows.size() != items.size()) throw new ApiException(ErrorCode.NOT_FOUND, "车间任务不存在或已撤回");
        return rows.stream().map(row -> new Segment(uuid(row[0]), uuid(row[1]), uuid(row[2]),
                str(row[3]), ((Number) row[4]).longValue(), uuid(row[5]), uuid(row[6]), uuid(row[7]),
                str(row[8]), ((Number) row[9]).intValue(), Boolean.TRUE.equals(row[10]),
                Boolean.TRUE.equals(row[11]), Boolean.TRUE.equals(row[12]), str(row[13]),
                str(row[14]), str(row[15]), str(row[16]), str(row[17]), str(row[18]), decimal(row[19]))).toList();
    }

    private void requireAccess(List<Segment> segments) {
        if (!access.hasAuthority("production_execution:view") || !access.hasAuthority("production_execution:start")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少车间领料权限");
        }
        for (Segment segment : segments) {
            if (membership.isWorkshopMember(segment.workshopId(), segment.responsibleId(),
                    currentUser.employeeId().orElse(null))) continue;
            access.requireScopedOperationWritable(segment.makerId(), "无权为此车间任务提交领料",
                    "production_execution:start");
        }
    }

    private Preview buildPreview(List<Item> items, List<Segment> segments) {
        UUID workshop = segments.getFirst().workshopId();
        Map<UUID, Item> requested = new LinkedHashMap<>();
        items.forEach(item -> requested.put(item.segmentId(), item));
        for (Segment segment : segments) {
            if (workshop == null || !workshop.equals(segment.workshopId())) {
                throw validation("一次批量领料只能选择同一车间的任务，请按车间分别办理");
            }
            Long version = requested.get(segment.id()).expectedVersion();
            if (version != null && version != segment.version()) throw conflict("车间任务已变化，请刷新后重新选择");
            if (!List.of("READY", "DISPATCHED").contains(segment.status())
                    || !"DEMANDED".equals(segment.materialMode()) || !"CONFIRMED".equals(segment.packageStatus())
                    || segment.planStatus() != 1 || segment.closed() || segment.canceled() || segment.stopped()) {
                throw conflict("仅物料齐套、尚未开工的有效车间任务可以提交领料");
            }
        }
        List<UUID> segmentIds = items.stream().map(Item::segmentId).toList();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT mapping.execution_segment_id, document.id, document.bill_no, item.id,
                       document.warehouse_id, warehouse.name, item.goods_id,
                       item.goods_code_snapshot, item.goods_name_snapshot, item.color_id, color.name,
                       item.unit_id, unit.name, item.qty, document.status,
                       fn_production_draw_item_requested_qty(item.id)
                FROM production_planning_package_documents mapping
                JOIN stock_documents document ON document.id=mapping.document_id
                  AND document.doc_type='DRAW' AND NOT document.is_deleted AND document.status IN (0,1)
                JOIN stock_document_items item ON item.doc_id=document.id AND NOT item.is_deleted
                JOIN production_planning_package_document_items item_mapping
                  ON item_mapping.document_item_id=item.id AND item_mapping.document_type='DRAW'
                JOIN production_material_demands demand ON demand.id=item_mapping.demand_id
                  AND demand.execution_segment_id=mapping.execution_segment_id AND NOT demand.is_deleted
                LEFT JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
                LEFT JOIN colors color ON color.id=item.color_id
                LEFT JOIN units unit ON unit.id=item.unit_id
                WHERE mapping.execution_segment_id IN (:ids) AND mapping.document_type='DRAW'
                ORDER BY mapping.execution_segment_id, document.warehouse_id, document.id, item.id
                """).setParameter("ids", segmentIds));
        List<Line> lines = new ArrayList<>();
        for (Object[] row : rows) {
            // Existing issued/requested sibling warehouses continue their own
            // workflow; submit only the remaining exact warehouse documents.
            BigDecimal qty = decimal(row[13]).subtract(decimal(row[15]));
            if (qty.signum() <= 0) continue;
            lines.add(new Line(uuid(row[0]), uuid(row[1]), str(row[2]), uuid(row[3]),
                    uuid(row[4]), str(row[5]), uuid(row[6]), str(row[7]), str(row[8]),
                    uuid(row[9]), str(row[10]), uuid(row[11]), str(row[12]), qty));
        }
        if (lines.stream().map(Line::segmentId).distinct().count() != items.size()) {
            throw conflict("所选任务缺少有效领料明细，请刷新后重试");
        }
        List<Task> tasks = segments.stream().map(segment -> new Task(segment.id(), segment.planId(),
                segment.planNo(), segment.code(), segment.workshopId(), segment.workshopName(),
                segment.productCode(), segment.productName(), segment.qty(), segment.version())).toList();
        return new Preview(fingerprint(tasks, lines), tasks.size(),
                (int) lines.stream().map(Line::drawId).distinct().count(), lines.size(), tasks, lines, summarize(lines));
    }

    static List<Summary> summarize(List<Line> lines) {
        Map<Dimension, Summary> result = new LinkedHashMap<>();
        for (Line line : lines) {
            Dimension key = new Dimension(line.warehouseId(), line.goodsId(), line.colorId(), line.unitId());
            Summary previous = result.get(key);
            result.put(key, new Summary(line.warehouseId(), line.warehouseName(), line.goodsId(),
                    line.goodsCode(), line.goodsName(), line.colorId(), line.colorName(), line.unitId(),
                    line.unitName(), line.qty().add(previous == null ? BigDecimal.ZERO : previous.qty())));
        }
        return List.copyOf(result.values());
    }

    static String fingerprint(List<Task> tasks, List<Line> lines) {
        List<String> parts = new ArrayList<>();
        parts.add("WORKSHOP-DRAW-PREVIEW-V1");
        tasks.stream().sorted(Comparator.comparing(Task::segmentId)).forEach(task -> parts.add(
                "TASK:" + task.segmentId() + ":" + task.expectedVersion() + ":" + task.workshopDepartmentId()));
        lines.stream().sorted(Comparator.comparing(Line::drawItemId)).forEach(line -> parts.add(
                "LINE:" + line.segmentId() + ":" + line.drawId() + ":" + line.drawItemId() + ":"
                        + line.warehouseId() + ":" + line.goodsId() + ":" + line.colorId() + ":"
                        + line.unitId() + ":" + line.qty().stripTrailingZeros().toPlainString()));
        return PlanningPackageFingerprint.sha256(parts);
    }

    static String requestHash(List<Item> items, String fingerprint) {
        List<String> parts = new ArrayList<>(List.of("WORKSHOP-DRAW-REQUEST-V1", fingerprint));
        items.stream().sorted(Comparator.comparing(Item::segmentId))
                .forEach(item -> parts.add(item.segmentId() + ":" + item.expectedVersion()));
        return PlanningPackageFingerprint.sha256(parts);
    }

    static List<Line> selectLines(List<Line> available, List<Selection> selections) {
        if (selections == null) return available;
        if (selections.isEmpty() || selections.size() > 5000) throw validation("请选择本次领料物料");
        Map<UUID, Line> byId = new LinkedHashMap<>();
        available.forEach(line -> byId.put(line.drawItemId(), line));
        Map<UUID, Line> result = new LinkedHashMap<>();
        for (Selection selection : selections) {
            if (selection == null || selection.drawItemId() == null || selection.quantity() == null
                    || selection.quantity().signum() <= 0 || selection.quantity().stripTrailingZeros().scale() > 4) {
                throw validation("本次领料数量必须大于 0，最多 4 位小数");
            }
            Line line = byId.get(selection.drawItemId());
            if (line == null || selection.quantity().compareTo(line.qty()) > 0) {
                throw conflict("所选物料或数量超出当前尚未申请量，请刷新领料汇总");
            }
            Line selected = new Line(line.segmentId(), line.drawId(), line.drawNo(), line.drawItemId(),
                    line.warehouseId(), line.warehouseName(), line.goodsId(), line.goodsCode(), line.goodsName(),
                    line.colorId(), line.colorName(), line.unitId(), line.unitName(), selection.quantity());
            if (result.putIfAbsent(line.drawItemId(), selected) != null) throw validation("同一领料行不能重复选择");
        }
        return List.copyOf(result.values());
    }

    private static String quantitiesJson(List<Line> lines) {
        return "{" + String.join(",", lines.stream().sorted(Comparator.comparing(Line::drawItemId))
                .map(line -> "\"" + line.drawItemId() + "\":" + line.qty().toPlainString()).toList()) + "}";
    }

    private static String selectionRequestHash(List<Item> items, String fingerprint, List<Selection> lines) {
        List<String> parts = new ArrayList<>(List.of(requestHash(items, fingerprint)));
        if (lines == null) parts.add("ALL");
        else {
            if (lines.stream().anyMatch(line -> line == null || line.drawItemId() == null || line.quantity() == null))
                throw validation("领料行缺少标识或数量");
            lines.stream().sorted(Comparator.comparing(Selection::drawItemId)).forEach(line -> parts.add(
                    line.drawItemId() + ":" + line.quantity().stripTrailingZeros().toPlainString()));
        }
        return PlanningPackageFingerprint.sha256(parts);
    }

    private Result replay(String key, String hash, List<Item> items) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT event.execution_segment_id, event.request_hash, document_id
                FROM production_execution_segment_events event
                CROSS JOIN LATERAL unnest(event.draw_document_ids) document_id
                WHERE event.action='DRAW_REQUEST' AND event.created_by=:actor AND event.idempotency_key=:key
                ORDER BY event.execution_segment_id, document_id
                """).setParameter("actor", currentUser.requireId()).setParameter("key", key));
        if (rows.isEmpty()) return null;
        List<UUID> segmentIds = rows.stream().map(row -> uuid(row[0])).distinct().sorted().toList();
        if (rows.stream().anyMatch(row -> !hash.equals(row[1]))
                || !items.stream().map(Item::segmentId).toList().containsAll(segmentIds)) {
            throw conflict("相同幂等键对应不同的领料批次，请重新核对");
        }
        return result(segmentIds, rows.stream().map(row -> uuid(row[2])).distinct().sorted().toList(), true);
    }

    private List<UUID> documentIds(List<UUID> segmentIds) {
        return NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT document.id FROM production_planning_package_documents mapping
                JOIN stock_documents document ON document.id=mapping.document_id AND NOT document.is_deleted
                  AND document.doc_type='DRAW' AND document.status IN (0,1)
                WHERE mapping.execution_segment_id IN (:ids) AND mapping.document_type='DRAW'
                ORDER BY document.id
                """, UUID.class).setParameter("ids", segmentIds), UUID.class);
    }

    private void lockRows(String table, List<UUID> ids) {
        em.createNativeQuery("SELECT id FROM " + table + " WHERE id IN (:ids) ORDER BY id FOR UPDATE")
                .setParameter("ids", ids).getResultList();
    }
    private static Result result(List<UUID> segments, List<UUID> documents, boolean replayed) {
        return new Result(segments, documents, segments.size(), documents.size(), replayed);
    }
    private static String uuidArray(List<UUID> ids) {
        return "{" + String.join(",", ids.stream().map(UUID::toString).toList()) + "}";
    }
    private static UUID uuid(Object value) { return value == null ? null : (UUID) value; }
    private static String str(Object value) { return value == null ? null : value.toString(); }
    private static BigDecimal decimal(Object value) { return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString()); }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
    private static ApiException validation(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
    private record Dimension(UUID warehouse, UUID goods, UUID color, UUID unit) {}
    private record Segment(UUID id, UUID planId, UUID packageId, String status, long version,
                           UUID workshopId, UUID responsibleId, UUID makerId, String packageStatus,
                           int planStatus, boolean closed, boolean canceled, boolean stopped, String materialMode,
                           String planNo, String code, String workshopName, String productCode,
                           String productName, BigDecimal qty) {}
}
