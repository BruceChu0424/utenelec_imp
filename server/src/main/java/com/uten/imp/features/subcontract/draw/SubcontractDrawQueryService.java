package com.uten.imp.features.subcontract.draw;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawCapabilities;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawItemRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPendingDraft;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreview;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreviewLine;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreviewRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreviewTask;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSupplySource;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskMaterial;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskMaterials;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskPage;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskRow;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.security.DocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Consumer;

/**
 * ADR-143 委外任务中心「领料」读侧: 任务列表、计数、任务详情、批量领料预览(只读, 不加锁)。
 *
 * <p>行级与物料级数量全部来自数据库函数({@code fn_subcontract_draw_summary} / {@code _facts} /
 * {@code _line_stock}); 同一次批量领料的联合分配见 {@link SubcontractDrawAllocator}。
 * 对象级范围沿用委外订货单的经手人可见规则({@link SubcontractDocumentAccessPolicy})。
 */
@Service
@RequiredArgsConstructor
public class SubcontractDrawQueryService {

    /** 委外领料(提交、撤回、结束领料)权限点。 */
    public static final String DRAW_AUTHORITY = "subcontract_order:draw";

    static final int MAX_BATCH_ITEMS = 50;
    private static final int MAX_PAGE_SIZE = 200;

    private final EntityManager em;
    private final SubcontractDocumentAccessPolicy access;

    // ==================== 列表 / 计数 ====================

    @Transactional(readOnly = true)
    public DrawTaskPage tasks(int page, int size, String keyword, String status,
                              UUID orderId, List<UUID> orderItemIds) {
        String statusFilter = statusFilter(status);
        int pageSize = Math.min(Math.max(size, 1), MAX_PAGE_SIZE);
        int pageNo = Math.max(page, 1);
        Filters filters = filters(keyword, orderId, orderItemIds);
        String sql = (classifiedCte(SubcontractDrawSql.OPEN_ITEM_PREDICATE + filters.sql()) + """
                , counts AS (
                    SELECT COUNT(*) FILTER (WHERE status IN ('DRAWABLE','DRAWABLE_PARTIAL')) AS drawable_rows,
                           COUNT(*) FILTER (WHERE status = 'DRAW_SUBMITTED') AS submitted_rows,
                           COUNT(*) FILTER (WHERE status = 'WAITING_PLANNING') AS planning_rows,
                           COUNT(*) FILTER (WHERE status = 'WAITING_MATERIAL') AS material_rows,
                           COUNT(*) AS all_rows,
                           COUNT(*) FILTER (WHERE {STATUS_FILTER}) AS filtered_rows
                    FROM classified
                ), page AS (
                    SELECT * FROM classified WHERE {STATUS_FILTER}
                    ORDER BY status_rank, deliver_date ASC NULLS LAST, order_bill_no,
                             line_no ASC NULLS LAST, order_item_id
                    LIMIT :pageLimit OFFSET :pageOffset
                )
                SELECT counts.drawable_rows, counts.submitted_rows, counts.planning_rows,
                       counts.material_rows, counts.all_rows, counts.filtered_rows,
                       {ROW_SELECT}
                FROM counts LEFT JOIN page ON TRUE
                ORDER BY page.status_rank, page.deliver_date ASC NULLS LAST, page.order_bill_no,
                         page.line_no ASC NULLS LAST, page.order_item_id
                """).replace("{STATUS_FILTER}", statusFilter).replace("{ROW_SELECT}", rowSelect("page"));
        Query query = em.createNativeQuery(sql);
        filters.binder().accept(query);
        query.setParameter("pageLimit", pageSize);
        query.setParameter("pageOffset", (pageNo - 1) * pageSize);
        boolean canSubmit = access.hasAuthority(DRAW_AUTHORITY);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        Object[] head = rows.isEmpty() ? new Object[6] : rows.getFirst();
        List<DrawTaskRow> items = new ArrayList<>();
        for (Object[] row : rows) {
            if (row[6] != null) {
                items.add(row(row, 6, canSubmit));
            }
        }
        long filtered = number(head[5]);
        Map<String, Long> counts = new LinkedHashMap<>();
        counts.put("DRAWABLE", number(head[0]));
        counts.put("DRAW_SUBMITTED", number(head[1]));
        counts.put("WAITING_PLANNING", number(head[2]));
        counts.put("WAITING_MATERIAL", number(head[3]));
        counts.put("ALL", number(head[4]));
        int totalPages = (int) Math.ceil((double) filtered / pageSize);
        return new DrawTaskPage(new PageResponse<>(items, pageNo, pageSize, filtered, totalPages),
                counts, new DrawCapabilities(canSubmit));
    }

    /**
     * 「领料」红数(ADR-143 §4.1): 调用者可见、可以动手的可领行数; 没有委外领料权限恒为 0。
     * 只对开放的订货明细逐行算一次 {@code fn_subcontract_draw_summary}。
     */
    @Transactional(readOnly = true)
    public long countDrawable() {
        if (!access.hasAuthority(DRAW_AUTHORITY)) {
            return 0;
        }
        DocumentAccessPolicy.NativeReadScope scope = access.nativeReadScope("o.maker_id", "readOwners");
        Query query = em.createNativeQuery("""
                WITH candidate AS MATERIALIZED (
                    SELECT oi.id AS order_item_id
                    {ITEM_FROM}
                    WHERE {OPEN_ITEM}
                      AND o.maker_id IS NOT NULL
                      AND {SCOPE}
                )
                SELECT COUNT(*)
                FROM candidate
                CROSS JOIN LATERAL fn_subcontract_draw_summary(candidate.order_item_id) summary
                WHERE summary.drawable_qty > 0
                """.replace("{ITEM_FROM}", SubcontractDrawSql.ITEM_FROM)
                .replace("{OPEN_ITEM}", SubcontractDrawSql.OPEN_ITEM_PREDICATE)
                .replace("{SCOPE}", scope.predicate()));
        scope.bind(query);
        return number(query.getSingleResult());
    }

    /**
     * 「领料中」黄数(ADR-171 修订二, 2026-10-09): 已提交领料、等仓库发出的行数——
     * 球不在本部门手上但活还在跑, 挂黄色在办徽章(与 {@link #countDrawable()} 的红色
     * 「可以动手」相对)。与列表 {@code STATUS_CASE} 同判据: 不可领(可领量为 0)且挂着
     * 仓库未发出的领料草稿行; 没有委外领料权限恒为 0。
     */
    @Transactional(readOnly = true)
    public long countSubmitted() {
        if (!access.hasAuthority(DRAW_AUTHORITY)) {
            return 0;
        }
        DocumentAccessPolicy.NativeReadScope scope = access.nativeReadScope("o.maker_id", "readOwners");
        Query query = em.createNativeQuery("""
                WITH candidate AS MATERIALIZED (
                    SELECT oi.id AS order_item_id, {PENDING_DRAFT} AS has_pending
                    {ITEM_FROM}
                    WHERE {OPEN_ITEM}
                      AND o.maker_id IS NOT NULL
                      AND {SCOPE}
                )
                SELECT COUNT(*)
                FROM candidate
                CROSS JOIN LATERAL fn_subcontract_draw_summary(candidate.order_item_id) summary
                WHERE COALESCE(summary.drawable_qty, 0) <= 0
                  AND candidate.has_pending
                """.replace("{ITEM_FROM}", SubcontractDrawSql.ITEM_FROM)
                .replace("{OPEN_ITEM}", SubcontractDrawSql.OPEN_ITEM_PREDICATE)
                .replace("{PENDING_DRAFT}", SubcontractDrawSql.PENDING_DRAFT_EXISTS)
                .replace("{SCOPE}", scope.predicate()));
        scope.bind(query);
        return number(query.getSingleResult());
    }

    // ==================== 任务详情 ====================

    @Transactional(readOnly = true)
    public DrawTaskMaterials materials(UUID orderItemId) {
        if (orderItemId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "缺少委外任务");
        }
        DocumentAccessPolicy.NativeReadScope scope = access.nativeReadScope("o.maker_id", "readOwners");
        Query query = em.createNativeQuery(classifiedCte(SubcontractDrawSql.APPROVED_ITEM_PREDICATE
                + " AND oi.id = :detailItemId AND " + scope.predicate() + " ")
                + " SELECT " + rowSelect("classified") + " FROM classified");
        query.setParameter("detailItemId", orderItemId);
        scope.bind(query);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外任务不存在，或这条委外明细还没有领料计划");
        }
        Object[] taskRow = rows.getFirst();
        UUID makerId = uuid(taskRow[ROW_MAKER]);
        boolean open = isOpen(orderItemId);
        boolean canOperate = canOperate(makerId);
        DrawTaskRow task = row(taskRow, 0, access.hasAuthority(DRAW_AUTHORITY));
        if (!open) {
            // 已结清/已结束领料/计划已关闭: 不再有「可领」, 余量全部计入还缺, 恒等式不变。
            task = withoutDrawable(task);
        }
        BigDecimal complete = task.drawnQty().add(task.pendingQty());
        BigDecimal targetSets = complete.add(task.drawableQty());

        List<DrawTaskMaterial> materials = new ArrayList<>();
        boolean anyOpenUnsent = false;
        for (FactLine fact : facts(List.of(orderItemId)).getOrDefault(orderItemId, List.of())) {
            BigDecimal covered = fact.sentQty().add(fact.pendingQty());
            // 需求 = 我方需发量 LEAST(计划量, f(Qm))(§三.4a): 财务批准的委外商自带料那部分不用我方物料。
            BigDecimal shortQty = fact.neededQty().subtract(covered).subtract(fact.availableQty())
                    .max(BigDecimal.ZERO);
            BigDecimal drawable = open && fact.lineOpen()
                    ? SubcontractDrawAllocator.materialQty(targetSets, fact.perUnitQty())
                            .subtract(covered).max(BigDecimal.ZERO)
                    : BigDecimal.ZERO;
            String state;
            if (!fact.lineOpen()) {
                state = "CLOSED";
            } else if (fact.sentQty().compareTo(fact.neededQty()) >= 0) {
                state = "SENT_FULL";
            } else if (fact.pendingQty().signum() > 0) {
                state = "PENDING";
            } else if (shortQty.signum() > 0) {
                state = "SHORT";
            } else {
                state = "DRAWABLE";
            }
            if (open && fact.lineOpen() && fact.sentQty().compareTo(fact.neededQty()) < 0) {
                anyOpenUnsent = true;
            }
            materials.add(new DrawTaskMaterial(fact.planItemId(), fact.lineNo(), fact.goodsId(),
                    fact.goodsCode(), fact.goodsName(), fact.colorId(), fact.colorName(), fact.unitId(),
                    fact.unitName(), fact.perUnitQty(), fact.neededQty(), fact.sentQty(), fact.pendingQty(),
                    fact.availableQty(), drawable, shortQty, state,
                    shortQty.signum() > 0 && fact.lineOpen()
                            ? supplySources(fact.goodsId(), fact.colorId()) : List.of()));
        }
        List<DrawPendingDraft> drafts = pendingDrafts(orderItemId);
        List<String> actions = new ArrayList<>();
        // 撤回只对仓库还没改过的草稿有效(改过的要请仓库在拣货页退回); 全部改过就不给, 免得点了必然 409。
        if (canOperate && drafts.stream().anyMatch(draft -> !draft.edited())) {
            actions.add("WITHDRAW");
        }
        if (canOperate && anyOpenUnsent) {
            actions.add("CLOSE");
        }
        return new DrawTaskMaterials(task, materials, drafts, actions);
    }

    // ==================== 批量领料预览 ====================

    @Transactional(readOnly = true)
    public DrawPreview preview(DrawPreviewRequest request) {
        List<DrawItemRequest> items = normalizeItems(request == null ? null : request.items());
        DrawBatch batch = computeBatch(items, false);
        if (batch.allocation().anyExceeded()) {
            throw new ApiException(ErrorCode.CONFLICT, exceededMessage(batch,
                    "本次领料数量超过本批可领", "请调整数量后重新核对"));
        }
        List<DrawPreviewTask> tasks = new ArrayList<>();
        for (SubcontractDrawAllocator.TaskResult result : batch.allocation().tasks()) {
            TaskRow row = batch.rows().get(result.orderItemId());
            tasks.add(new DrawPreviewTask(row.orderItemId(), row.orderId(), row.orderBillNo(), row.lineNo(),
                    row.supplierName(), row.goodsId(), row.goodsCode(), row.goodsName(), row.colorName(),
                    row.unitName(), row.orderQty(), row.drawnQty(), row.drawableQty(),
                    result.batchDrawableQty(), result.qty()));
        }
        List<DrawPreviewLine> lines = new ArrayList<>();
        Set<String> documents = new LinkedHashSet<>();
        for (SubcontractDrawAllocator.Slice slice : batch.allocation().slices()) {
            FactLine fact = batch.factLine(slice.planItemId());
            lines.add(new DrawPreviewLine(slice.orderItemId(), slice.planItemId(), slice.warehouseId(),
                    slice.warehouseName(), fact.goodsId(), fact.goodsCode(), fact.goodsName(), fact.colorId(),
                    fact.colorName(), fact.unitId(), fact.unitName(), slice.qty(), slice.warehouseAvailableQty()));
            documents.add(slice.orderId() + ":" + slice.warehouseId());
        }
        return new DrawPreview(tasks, lines, documents.size());
    }

    /**
     * 读取所选任务的事实并按「交期、订货单号、行号」联合分配。预览只读调用; 提交在锁内调用
     * (requireOperate=true 时逐张订货单校验委外领料的对象级写范围)。
     */
    public DrawBatch computeBatch(List<DrawItemRequest> items, boolean requireOperate) {
        List<UUID> ids = items.stream().map(DrawItemRequest::orderItemId).toList();
        Map<UUID, TaskRow> rows = openRows(ids);
        if (rows.size() != ids.size()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "所选委外任务已领满、已结束领料或已不在您的可见范围内，请刷新后重新选择");
        }
        if (requireOperate) {
            for (TaskRow row : rows.values()) {
                access.requireScopedOperationWritable(row.makerId(), "无权为该委外订货单领料", DRAW_AUTHORITY);
            }
        }
        Map<UUID, List<FactLine>> facts = facts(ids);
        Map<UUID, List<SubcontractDrawAllocator.Stock>> stocks = lineStocks(ids);
        Map<UUID, BigDecimal> requested = new HashMap<>();
        items.forEach(item -> requested.put(item.orderItemId(), item.qty()));
        List<TaskRow> ordered = rows.values().stream()
                .sorted(Comparator.comparing(TaskRow::deliverDate, Comparator.nullsLast(Comparator.naturalOrder()))
                        .thenComparing(row -> Objects.toString(row.orderBillNo(), ""))
                        .thenComparing(TaskRow::lineNo, Comparator.nullsLast(Comparator.naturalOrder()))
                        .thenComparing(row -> row.orderItemId().toString()))
                .toList();
        List<SubcontractDrawAllocator.Task> tasks = new ArrayList<>();
        Map<UUID, FactLine> factByPlanItem = new HashMap<>();
        for (TaskRow row : ordered) {
            List<SubcontractDrawAllocator.Line> lines = new ArrayList<>();
            for (FactLine fact : facts.getOrDefault(row.orderItemId(), List.of())) {
                factByPlanItem.put(fact.planItemId(), fact);
                if (!fact.lineOpen()) {
                    continue;
                }
                lines.add(new SubcontractDrawAllocator.Line(fact.planItemId(), fact.goodsId(), fact.colorId(),
                        fact.perUnitQty(), fact.plannedQty(), fact.sentQty().add(fact.pendingQty()),
                        stocks.getOrDefault(fact.planItemId(), List.of())));
            }
            tasks.add(new SubcontractDrawAllocator.Task(row.orderItemId(), row.orderId(), row.materialQty(),
                    requested.get(row.orderItemId()), lines));
        }
        return new DrawBatch(rows, factByPlanItem, SubcontractDrawAllocator.allocate(tasks));
    }

    /** 「委外订货单 X 第 n 行 Y: 本批可领 a 个(填写 b)」逐项列出超出的任务。 */
    public String exceededMessage(DrawBatch batch, String prefix, String suffix) {
        List<String> parts = new ArrayList<>();
        for (SubcontractDrawAllocator.TaskResult result : batch.allocation().tasks()) {
            if (!result.exceeded()) {
                continue;
            }
            TaskRow row = batch.rows().get(result.orderItemId());
            parts.add("委外订货单 " + row.orderBillNo() + " 第 " + row.lineNo() + " 行 "
                    + Objects.toString(row.goodsName(), "") + " 本批可领 " + plain(result.batchDrawableQty())
                    + " " + Objects.toString(row.unitName(), "") + "(填写 " + plain(result.qty()) + ")");
        }
        return prefix + "：" + String.join("；", parts) + "；" + suffix;
    }

    /** 1-50 个、不重复; qty 为 null(取本批可领)或大于 0 且最多 4 位小数。 */
    static List<DrawItemRequest> normalizeItems(List<DrawItemRequest> items) {
        if (items == null || items.isEmpty() || items.size() > MAX_BATCH_ITEMS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "批量领料必须选择 1-50 个委外任务");
        }
        Map<UUID, DrawItemRequest> distinct = new LinkedHashMap<>();
        for (DrawItemRequest item : items) {
            if (item == null || item.orderItemId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "领料任务信息不正确，请刷新后重新选择");
            }
            if (item.qty() != null && (item.qty().signum() <= 0
                    || Math.max(item.qty().stripTrailingZeros().scale(), 0) > 4)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "本次领料数量必须大于 0，最多 4 位小数");
            }
            if (distinct.putIfAbsent(item.orderItemId(), item) != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一委外任务不能重复选择");
            }
        }
        return List.copyOf(distinct.values());
    }

    /** 当前用户能否为这张订货单领料: 持有委外领料权限, 且订货单在其可见范围内(经手人规则)。 */
    public boolean canOperate(UUID makerId) {
        return access.hasAuthority(DRAW_AUTHORITY)
                && access.canRead(makerId, access.scope())
                && access.canWrite(makerId, access.scope(DRAW_AUTHORITY));
    }

    // ==================== 读取 ====================

    /** 这条订货明细此刻是否还是领料任务(计划 OPEN、未结清、还有没发完的开放计划行)。 */
    private boolean isOpen(UUID orderItemId) {
        Object value = em.createNativeQuery("""
                SELECT EXISTS (
                    SELECT 1
                    {ITEM_FROM}
                    WHERE {OPEN_ITEM}
                      AND oi.id = :openItemId)
                """.replace("{ITEM_FROM}", SubcontractDrawSql.ITEM_FROM)
                .replace("{OPEN_ITEM}", SubcontractDrawSql.OPEN_ITEM_PREDICATE))
                .setParameter("openItemId", orderItemId)
                .getSingleResult();
        return Boolean.TRUE.equals(value);
    }

    private static DrawTaskRow withoutDrawable(DrawTaskRow task) {
        BigDecimal shortQty = task.materialQty().subtract(task.drawnQty()).subtract(task.pendingQty())
                .max(BigDecimal.ZERO);
        return new DrawTaskRow(task.orderItemId(), task.orderId(), task.orderBillNo(), task.lineNo(),
                task.supplierId(), task.supplierName(), task.goodsId(), task.goodsCode(), task.goodsName(),
                task.colorId(), task.colorName(), task.unitId(), task.unitName(), task.orderQty(),
                task.drawnQty(), task.pendingQty(), BigDecimal.ZERO, shortQty, task.materialKindCount(),
                task.readyKindCount(), task.shortKindCount(), task.unplannedShortKindCount(),
                task.pendingQty().signum() > 0 ? "DRAW_SUBMITTED" : "WAITING_MATERIAL",
                task.deliverDate(), false, task.materialQty());
    }

    /** 选中的开放任务(范围内), 带行级可领/已领/已覆盖套数。 */
    private Map<UUID, TaskRow> openRows(List<UUID> ids) {
        DocumentAccessPolicy.NativeReadScope scope = access.nativeReadScope("o.maker_id", "readOwners");
        Query query = em.createNativeQuery("""
                WITH candidate AS MATERIALIZED (
                    SELECT {ROW_COLUMNS}
                    {ITEM_FROM}
                    WHERE {OPEN_ITEM}
                      AND oi.id IN (:batchItemIds)
                      AND {SCOPE}
                )
                SELECT candidate.order_item_id, candidate.order_id, candidate.order_bill_no, candidate.line_no,
                       candidate.supplier_name, candidate.goods_id, candidate.goods_code, candidate.goods_name,
                       candidate.color_name, candidate.unit_name, candidate.deliver_date, candidate.maker_id,
                       summary.order_qty, summary.drawn_qty, summary.drawable_qty, summary.material_qty
                FROM candidate
                CROSS JOIN LATERAL fn_subcontract_draw_summary(candidate.order_item_id) summary
                """.replace("{ROW_COLUMNS}", SubcontractDrawSql.ROW_COLUMNS)
                .replace("{ITEM_FROM}", SubcontractDrawSql.ITEM_FROM)
                .replace("{OPEN_ITEM}", SubcontractDrawSql.OPEN_ITEM_PREDICATE)
                .replace("{SCOPE}", scope.predicate()));
        query.setParameter("batchItemIds", ids);
        scope.bind(query);
        Map<UUID, TaskRow> rows = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            TaskRow task = new TaskRow(uuid(row[0]), uuid(row[1]), str(row[2]), integer(row[3]), str(row[4]),
                    uuid(row[5]), str(row[6]), str(row[7]), str(row[8]), str(row[9]), localDate(row[10]),
                    uuid(row[11]), decimal(row[12]), decimal(row[13]), decimal(row[14]), decimal(row[15]));
            rows.put(task.orderItemId(), task);
        }
        return rows;
    }

    /** 物料级事实(按订货明细分组, 按计划行号排序), 带物料主档显示名。 */
    private Map<UUID, List<FactLine>> facts(List<UUID> ids) {
        Query query = em.createNativeQuery("""
                SELECT oi.id, facts.plan_item_id, facts.line_no, facts.goods_id, material.code, material.name,
                       facts.color_id, material_color.name, facts.unit_id, material_unit.name,
                       facts.bom_unit_qty, facts.planned_qty, facts.sent_qty, facts.pending_qty,
                       facts.available_qty, facts.line_open, facts.needed_qty
                FROM subcontract_order_items oi
                CROSS JOIN LATERAL fn_subcontract_draw_facts(oi.id) facts
                LEFT JOIN goods material ON material.id = facts.goods_id
                LEFT JOIN colors material_color ON material_color.id = facts.color_id
                LEFT JOIN units material_unit ON material_unit.id = facts.unit_id
                WHERE oi.id IN (:factItemIds)
                ORDER BY oi.id, facts.line_no ASC NULLS LAST, facts.plan_item_id
                """);
        query.setParameter("factItemIds", ids);
        Map<UUID, List<FactLine>> facts = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            facts.computeIfAbsent(uuid(row[0]), ignored -> new ArrayList<>()).add(new FactLine(
                    uuid(row[1]), integer(row[2]), uuid(row[3]), str(row[4]), str(row[5]), uuid(row[6]),
                    str(row[7]), uuid(row[8]), str(row[9]), decimal(row[10]), decimal(row[11]),
                    decimal(row[12]), decimal(row[13]), decimal(row[14]), Boolean.TRUE.equals(row[15]),
                    decimal(row[16])));
        }
        return facts;
    }

    /** 每条开放计划行在各作业叶仓的可动用量: 专属批次 + 公共可用。 */
    private Map<UUID, List<SubcontractDrawAllocator.Stock>> lineStocks(List<UUID> ids) {
        Query query = em.createNativeQuery("""
                SELECT line.id, stock.warehouse_id, warehouse.code, warehouse.name,
                       stock.exact_qty, stock.public_qty
                FROM subcontract_material_plan_items line
                CROSS JOIN LATERAL fn_subcontract_draw_line_stock(line.id) stock
                JOIN warehouses warehouse ON warehouse.id = stock.warehouse_id
                WHERE line.order_item_id IN (:stockItemIds)
                  AND NOT line.is_deleted AND line.draw_closed_at IS NULL
                ORDER BY line.id, warehouse.code, warehouse.id
                """);
        query.setParameter("stockItemIds", ids);
        Map<UUID, List<SubcontractDrawAllocator.Stock>> stocks = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            stocks.computeIfAbsent(uuid(row[0]), ignored -> new ArrayList<>())
                    .add(new SubcontractDrawAllocator.Stock(uuid(row[1]), str(row[2]), str(row[3]),
                            decimal(row[4]), decimal(row[5])));
        }
        return stocks;
    }

    private List<DrawSupplySource> supplySources(UUID goodsId, UUID colorId) {
        return SubcontractOpenSupplySources.read(em, goodsId, colorId).stream()
                .map(source -> new DrawSupplySource(source.kind(), source.docId(), source.docNo(), source.openQty()))
                .toList();
    }

    private List<DrawPendingDraft> pendingDrafts(UUID orderItemId) {
        Query query = em.createNativeQuery("""
                SELECT issue.id, issue.bill_no, issue.warehouse_id, warehouse.name, COUNT(item.id),
                       issue.created_at, creator_employee.full_name,
                """ + SubcontractMaterialPlanService.DRAFT_EDITED_BY_WAREHOUSE + """
                FROM subcontract_material_issues issue
                JOIN subcontract_material_issue_items item ON item.issue_id = issue.id
                 AND NOT item.is_deleted AND item.plan_item_id IS NOT NULL
                 AND item.order_item_id = :draftItemId
                LEFT JOIN warehouses warehouse ON warehouse.id = issue.warehouse_id
                LEFT JOIN users creator ON creator.id = issue.created_by
                LEFT JOIN employees creator_employee ON creator_employee.id = creator.employee_id
                WHERE issue.status = 0 AND NOT issue.is_deleted
                GROUP BY issue.id, issue.bill_no, issue.warehouse_id, warehouse.name,
                         issue.created_at, creator_employee.full_name, issue.created_by, issue.updated_by
                ORDER BY issue.created_at, issue.bill_no
                """);
        query.setParameter("draftItemId", orderItemId);
        List<DrawPendingDraft> drafts = new ArrayList<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            drafts.add(new DrawPendingDraft(uuid(row[0]), str(row[1]), uuid(row[2]), str(row[3]),
                    (int) number(row[4]), offsetDateTime(row[5]), str(row[6]), Boolean.TRUE.equals(row[7])));
        }
        return drafts;
    }

    // ==================== SQL 拼装 ====================

    /**
     * 候选 → 行级汇总 → 还缺物料是否有在途供应 → 状态。只给还缺物料的行算一次物料级事实,
     * 在途供应按不同物料只查一次。
     */
    private static String classifiedCte(String predicate) {
        return """
                WITH candidate AS MATERIALIZED (
                    SELECT {ROW_COLUMNS}, {PENDING_DRAFT} AS has_pending
                    {ITEM_FROM}
                    WHERE {PREDICATE}
                ), base AS MATERIALIZED (
                    SELECT candidate.*, summary.order_qty, summary.material_kind_count, summary.ready_kind_count,
                           summary.drawn_qty, summary.pending_qty, summary.drawable_qty, summary.short_qty,
                           summary.complete_qty, summary.material_qty
                    FROM candidate
                    CROSS JOIN LATERAL fn_subcontract_draw_summary(candidate.order_item_id) summary
                ), short_lines AS MATERIALIZED (
                    SELECT base.order_item_id, facts.goods_id, facts.color_id
                    FROM base
                    CROSS JOIN LATERAL fn_subcontract_draw_facts(base.order_item_id) facts
                    WHERE base.material_kind_count > base.ready_kind_count
                      AND facts.line_open
                      AND facts.needed_qty - facts.sent_qty - facts.pending_qty - facts.available_qty > 0
                ), supplied AS MATERIALIZED (
                    SELECT material.goods_id, material.color_id
                    FROM (SELECT DISTINCT goods_id, color_id FROM short_lines) material
                    WHERE EXISTS (
                        {OPEN_SUPPLY}
                    )
                ), unplanned AS (
                    SELECT short_lines.order_item_id, COUNT(*) AS unplanned_count
                    FROM short_lines
                    WHERE NOT EXISTS (
                        SELECT 1 FROM supplied
                        WHERE supplied.goods_id = short_lines.goods_id
                          AND supplied.color_id IS NOT DISTINCT FROM short_lines.color_id)
                    GROUP BY short_lines.order_item_id
                ), enriched AS (
                    SELECT base.*, COALESCE(unplanned.unplanned_count, 0) AS unplanned_short_kind_count
                    FROM base LEFT JOIN unplanned ON unplanned.order_item_id = base.order_item_id
                ), classified AS MATERIALIZED (
                    SELECT enriched.*,
                           {STATUS_CASE} AS status,
                           {STATUS_RANK_CASE} AS status_rank
                    FROM enriched
                )
                """.replace("{ROW_COLUMNS}", SubcontractDrawSql.ROW_COLUMNS)
                .replace("{PENDING_DRAFT}", SubcontractDrawSql.PENDING_DRAFT_EXISTS)
                .replace("{ITEM_FROM}", SubcontractDrawSql.ITEM_FROM)
                .replace("{OPEN_SUPPLY}", SubcontractDrawSql.openSupplySources("material.goods_id", "material.color_id"))
                .replace("{STATUS_CASE}", SubcontractDrawSql.STATUS_CASE)
                .replace("{STATUS_RANK_CASE}", SubcontractDrawSql.STATUS_RANK_CASE)
                .replace("{PREDICATE}", predicate);
    }

    /** 行列(固定顺序, 见 {@link #row}); alias 为 CTE 名。 */
    private static String rowSelect(String alias) {
        return String.join(", ", List.of(
                alias + ".order_item_id", alias + ".order_id", alias + ".order_bill_no", alias + ".line_no",
                alias + ".supplier_id", alias + ".supplier_name", alias + ".goods_id", alias + ".goods_code",
                alias + ".goods_name", alias + ".color_id", alias + ".color_name", alias + ".unit_id",
                alias + ".unit_name", alias + ".order_qty", alias + ".drawn_qty", alias + ".pending_qty",
                alias + ".drawable_qty", alias + ".short_qty", alias + ".material_kind_count",
                alias + ".ready_kind_count", alias + ".unplanned_short_kind_count", alias + ".status",
                alias + ".deliver_date", alias + ".maker_id", alias + ".material_qty")) + "\n";
    }

    private static final int ROW_MAKER = 23;

    private DrawTaskRow row(Object[] r, int o, boolean canSubmit) {
        BigDecimal drawable = decimal(r[o + 16]);
        int kinds = (int) number(r[o + 18]);
        int ready = (int) number(r[o + 19]);
        UUID makerId = uuid(r[o + 23]);
        return new DrawTaskRow(uuid(r[o]), uuid(r[o + 1]), str(r[o + 2]), integer(r[o + 3]), uuid(r[o + 4]),
                str(r[o + 5]), uuid(r[o + 6]), str(r[o + 7]), str(r[o + 8]), uuid(r[o + 9]), str(r[o + 10]),
                uuid(r[o + 11]), str(r[o + 12]), decimal(r[o + 13]), decimal(r[o + 14]), decimal(r[o + 15]),
                drawable, decimal(r[o + 17]), kinds, ready, Math.max(kinds - ready, 0),
                (int) number(r[o + 20]), str(r[o + 21]), localDate(r[o + 22]),
                canSubmit && makerId != null && drawable.signum() > 0, decimal(r[o + 24]));
    }

    /** 状态筛选白名单(固定 SQL 片段, 不拼用户输入)。 */
    private static String statusFilter(String status) {
        String normalized = status == null ? "" : status.strip().toUpperCase(java.util.Locale.ROOT);
        return switch (normalized) {
            case "", "ALL" -> "TRUE";
            case "DRAWABLE" -> "status IN ('DRAWABLE','DRAWABLE_PARTIAL')";
            case "DRAW_SUBMITTED" -> "status = 'DRAW_SUBMITTED'";
            case "WAITING_PLANNING" -> "status = 'WAITING_PLANNING'";
            case "WAITING_MATERIAL" -> "status = 'WAITING_MATERIAL'";
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "领料状态的筛选值不正确，请刷新后重试");
        };
    }

    private record Filters(String sql, Consumer<Query> binder) {
    }

    private Filters filters(String keyword, UUID orderId, List<UUID> orderItemIds) {
        DocumentAccessPolicy.NativeReadScope scope = access.nativeReadScope("o.maker_id", "readOwners");
        StringBuilder sql = new StringBuilder(" AND ").append(scope.predicate()).append(' ');
        String pattern = keyword == null || keyword.isBlank() ? null : "%" + keyword.strip() + "%";
        if (pattern != null) {
            sql.append("""
                     AND (o.bill_no ILIKE :keyword OR supplier.name ILIKE :keyword
                          OR COALESCE(oi.goods_code_snapshot, goods.code) ILIKE :keyword
                          OR COALESCE(oi.goods_name_snapshot, goods.name) ILIKE :keyword)
                    """);
        }
        if (orderId != null) {
            sql.append(" AND o.id = :filterOrderId ");
        }
        List<UUID> itemIds = orderItemIds == null ? List.of()
                : orderItemIds.stream().filter(Objects::nonNull).distinct().toList();
        if (itemIds.size() > MAX_PAGE_SIZE) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次最多按 200 个委外任务筛选");
        }
        if (!itemIds.isEmpty()) {
            sql.append(" AND oi.id IN (:filterItemIds) ");
        }
        return new Filters(sql.toString(), query -> {
            scope.bind(query);
            if (pattern != null) {
                query.setParameter("keyword", pattern);
            }
            if (orderId != null) {
                query.setParameter("filterOrderId", orderId);
            }
            if (!itemIds.isEmpty()) {
                query.setParameter("filterItemIds", itemIds);
            }
        });
    }

    // ==================== 内部模型与转换 ====================

    /** 一个选中的开放任务(订货单位数量); materialQty = 我方供料套数 Qm(联合分配按它封顶, §三.4a)。 */
    record TaskRow(UUID orderItemId, UUID orderId, String orderBillNo, Integer lineNo, String supplierName,
                   UUID goodsId, String goodsCode, String goodsName, String colorName, String unitName,
                   LocalDate deliverDate, UUID makerId, BigDecimal orderQty, BigDecimal drawnQty,
                   BigDecimal drawableQty, BigDecimal materialQty) {
    }

    /** 一条计划行的物料级事实(物料基本单位); neededQty = 我方需发量 LEAST(计划量, f(Qm))。 */
    record FactLine(UUID planItemId, Integer lineNo, UUID goodsId, String goodsCode, String goodsName,
                    UUID colorId, String colorName, UUID unitId, String unitName, BigDecimal perUnitQty,
                    BigDecimal plannedQty, BigDecimal sentQty, BigDecimal pendingQty, BigDecimal availableQty,
                    boolean lineOpen, BigDecimal neededQty) {
    }

    /** 一次批量领料的读取结果与联合分配。 */
    record DrawBatch(Map<UUID, TaskRow> rows, Map<UUID, FactLine> facts,
                     SubcontractDrawAllocator.Result allocation) {
        FactLine factLine(UUID planItemId) {
            FactLine fact = facts.get(planItemId);
            if (fact == null) {
                throw new IllegalStateException("draw allocation references an unknown plan line");
            }
            return fact;
        }
    }

    static String plain(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }

    static UUID uuid(Object value) {
        if (value == null) return null;
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    static String str(Object value) {
        return value == null ? null : value.toString();
    }

    static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        return value instanceof BigDecimal decimal ? decimal : new BigDecimal(value.toString());
    }

    static Integer integer(Object value) {
        return value == null ? null : ((Number) value).intValue();
    }

    static long number(Object value) {
        return value == null ? 0L : ((Number) value).longValue();
    }

    static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        if (value instanceof java.sql.Date date) return date.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime time) return time;
        if (value instanceof java.time.Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof java.sql.Timestamp timestamp) return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        if (value instanceof java.time.ZonedDateTime zoned) return zoned.toOffsetDateTime();
        if (value instanceof java.time.LocalDateTime local) return local.atOffset(ZoneOffset.UTC);
        return OffsetDateTime.parse(value.toString());
    }
}
