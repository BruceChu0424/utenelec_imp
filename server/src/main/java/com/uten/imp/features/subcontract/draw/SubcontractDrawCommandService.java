package com.uten.imp.features.subcontract.draw;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.SubcontractChainNoticePort;
import com.uten.imp.application.port.SubcontractOutboundWakePort;
import com.uten.imp.common.concurrency.ProcurementMutationFootprint;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawCloseRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawCloseResult;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawItemRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitResult;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawWithdrawRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawWithdrawResult;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;
import java.util.stream.IntStream;

import static com.uten.imp.features.subcontract.draw.SubcontractDrawQueryService.DRAW_AUTHORITY;

/**
 * ADR-143 委外领料写侧: 提交领料、撤回未发领料、结束领料。
 *
 * <p>锁顺序(ADR-143 §4.2, ADR-107): 订货单头 → 订货明细 → 冻结计划行的物料维度(不是现时 BOM)
 * → 涉及的仓库 → 专属批次所属分析, 一次预锁拿齐; 之后先锁待发草稿头、再按 id 锁计划行, 复核预读
 * 未变化后才写。提交在锁内按「交期、订货单号、行号」重算联合分配, 实时本批可领低于提交量即 409
 * 并逐项给出实时值。
 *
 * <p>幂等: 同一账号同一幂等键串行(事务级咨询锁); 新建草稿的主键由「账号 + 幂等键 + 序号」确定性
 * 生成, 重放时按序号找回原草稿原样返回, 不再建单。
 */
@Service
@RequiredArgsConstructor
public class SubcontractDrawCommandService {

    private static final Pattern IDEMPOTENCY_KEY = Pattern.compile("[A-Za-z0-9._:-]{8,128}");
    /** 一次提交最多新建的出仓草稿张数(订货单 × 仓库), 也是重放时探测的序号上限。 */
    private static final int MAX_DOCUMENTS = 200;
    private static final String DRAW_REMARK = "委外领料";
    private static final String REPLAY_CHANGED = "这批领料已撤回或已变化，请重新打开领料页后再提交";
    private static final String OUTBOUND_VIEW = "subcontract_outbound:view";
    private static final String OUTBOUND_EXECUTE = "subcontract_outbound:execute";

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final SubcontractDocumentAccessPolicy access;
    private final SubcontractDrawQueryService queries;
    private final SubcontractMaterialPlanService plans;
    private final FulfillmentMutationLocks locks;
    private final ProcurementMutationFootprint footprint;
    private final DocNumberService docNumbers;
    private final SubcontractChainNoticePort chainNotice;
    private final SubcontractOutboundWakePort drawRecheck;

    // ==================== 提交领料 ====================

    @Transactional
    public DrawSubmitResult submit(DrawSubmitRequest request) {
        if (request == null || request.idempotencyKey() == null
                || !IDEMPOTENCY_KEY.matcher(request.idempotencyKey()).matches()) {
            throw validation("领料提交的操作编号缺失或不正确，请重新打开领料页后再提交");
        }
        List<DrawItemRequest> items = SubcontractDrawQueryService.normalizeItems(request.items());
        requireDrawAuthority();
        tx.bind();
        UUID actor = currentUser.requireId();
        String key = request.idempotencyKey();
        // 同账号同幂等键的整批重放串行化, 第二次一定能看到第一次提交的草稿。
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key, 561))")
                .setParameter("key", actor + ":SUBCONTRACT_DRAW:" + key)
                .getSingleResult();
        List<UUID> itemIds = items.stream().map(DrawItemRequest::orderItemId).sorted().toList();
        DrawSubmitResult replay = replay(actor, key, itemIds);
        if (replay != null) {
            return replay;
        }
        FulfillmentMutationLocks.Guard guard = lock(itemIds, true);
        lockPlanRows(itemIds);
        guard.verifyUnchanged();

        SubcontractDrawQueryService.DrawBatch batch = queries.computeBatch(items, true);
        if (batch.allocation().anyExceeded()) {
            throw conflict(queries.exceededMessage(batch, "本批可领已变化",
                    "请按实时可领重新核对后再提交"));
        }
        List<String> empty = new ArrayList<>();
        for (SubcontractDrawAllocator.TaskResult result : batch.allocation().tasks()) {
            if (result.qty().signum() <= 0) {
                SubcontractDrawQueryService.TaskRow row = batch.rows().get(result.orderItemId());
                empty.add("委外订货单 " + row.orderBillNo() + " 第 " + row.lineNo() + " 行 "
                        + Objects.toString(row.goodsName(), ""));
            }
        }
        if (!empty.isEmpty()) {
            throw conflict(String.join("；", empty) + " 当前没有可领数量，请取消勾选后再提交");
        }

        Map<DraftKey, List<SubcontractDrawAllocator.Slice>> groups = new LinkedHashMap<>();
        for (SubcontractDrawAllocator.Slice slice : batch.allocation().slices()) {
            groups.computeIfAbsent(new DraftKey(slice.orderId(), slice.warehouseId()),
                    ignored -> new ArrayList<>()).add(slice);
        }
        if (groups.size() > MAX_DOCUMENTS) {
            throw conflict("一次领料要开出的出仓单超过 " + MAX_DOCUMENTS + " 张，请分批提交");
        }
        Map<UUID, ParentGoods> parents = parentGoods(itemIds);
        LocalDate today = BusinessTime.today();
        OffsetDateTime now = OffsetDateTime.now();
        List<UUID> issueIds = new ArrayList<>();
        List<String> billNos = new ArrayList<>();
        int index = 0;
        for (Map.Entry<DraftKey, List<SubcontractDrawAllocator.Slice>> group : groups.entrySet()) {
            UUID issueId = draftId(actor, key, index++);
            String billNo = docNumbers.nextNumber(DocNumberPrefix.SUB_MATERIAL_ISSUE);
            createDraft(issueId, billNo, group.getKey(), group.getValue(), batch, parents, actor, today, now);
            plans.reserveDraft(issueId, group.getKey().warehouseId());
            issueIds.add(issueId);
            billNos.add(billNo);
        }
        issueIds.forEach(chainNotice::notifySubcontractOutboundReady);
        itemIds.forEach(chainNotice::resolveSubcontractDrawAvailable);
        // 本批占用了共享物料, 其它任务的可领量下降: 提交后由 outbox 把它们的提醒水位降下来。
        drawRecheck.enqueueDrawRecheck(batch.facts().values().stream()
                .map(fact -> new SubcontractOutboundWakePort.StockedDimension(fact.goodsId(), fact.colorId(), null))
                .toList());
        return new DrawSubmitResult(issueIds, billNos, issueIds.size(), false);
    }

    // ==================== 撤回 / 结束领料 ====================

    @Transactional
    public DrawWithdrawResult withdraw(DrawWithdrawRequest request) {
        List<UUID> itemIds = normalizeIds(request == null ? null : request.orderItemIds());
        requireDrawAuthority();
        tx.bind();
        requireOperable(itemIds);
        FulfillmentMutationLocks.Guard guard = lock(itemIds, false);
        lockDraftHeaders(itemIds);
        lockPlanRows(itemIds);
        guard.verifyUnchanged();
        SubcontractMaterialPlanService.WithdrawResult result = plans.withdrawPendingDraws(itemIds, false);
        if (result.issueIds().isEmpty()) {
            throw conflict("所选委外任务没有待仓库发料的领料，无需撤回");
        }
        return new DrawWithdrawResult(result.issueIds(), result.removedLineCount());
    }

    @Transactional
    public DrawCloseResult close(UUID orderItemId, DrawCloseRequest request) {
        if (orderItemId == null) {
            throw validation("缺少委外任务");
        }
        String reason = request == null || request.reason() == null ? "" : request.reason().strip();
        if (reason.isEmpty()) {
            throw validation("结束领料必须填写原因");
        }
        if (reason.length() > 200) {
            throw validation("结束领料原因不能超过 200 个字");
        }
        requireDrawAuthority();
        tx.bind();
        List<UUID> itemIds = List.of(orderItemId);
        requireOperable(itemIds);
        FulfillmentMutationLocks.Guard guard = lock(itemIds, false);
        lockDraftHeaders(itemIds);
        lockPlanRows(itemIds);
        guard.verifyUnchanged();
        plans.closeDrawForOrderItem(orderItemId, reason);
        return new DrawCloseResult(true);
    }

    // ==================== 仓库退回整张领料(不发) ====================

    /**
     * 仓库把一张领料草稿整张退回给委外人员(实物发不出: 缺货、料损等)。仓库改过拣货数量的草稿委外人员
     * 撤回不了, 仓库又不能删单、不能删光物料行, 这是仓库这一侧的出口: 释放这张草稿的占用(专属批次退回
     * 原分析)、作废草稿、告诉提交领料的人, 再重算可领。只动这一张草稿, 同一任务在别的仓的待发领料不受影响。
     *
     * <p>权限与拣货页、审核出仓同一道门: 委外出仓查看 + 委外出仓执行; 只认仓库待发池里的领料草稿。
     * 锁顺序与委外人员撤回一致: 订货单 → 订货明细 → 计划行物料维度 → 仓库 → 分析, 再草稿头, 再计划行。
     */
    @Transactional
    public DrawWithdrawResult returnToDraw(UUID issueId, String reason) {
        if (issueId == null) {
            throw validation("缺少领料出仓单");
        }
        String normalized = reason == null ? "" : reason.strip();
        if (normalized.isEmpty()) {
            throw validation("退回领料必须填写原因");
        }
        if (normalized.length() > 200) {
            throw validation("退回原因不能超过 200 个字");
        }
        if (!access.hasAuthority(OUTBOUND_VIEW) || !access.hasAuthority(OUTBOUND_EXECUTE)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少委外出仓执行权限");
        }
        tx.bind();
        List<UUID> itemIds = draftOrderItems(issueId);
        if (itemIds.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外领料出仓任务不存在或已处理");
        }
        FulfillmentMutationLocks.Guard guard = lock(itemIds, false);
        List<?> header = em.createNativeQuery("""
                SELECT issue.id FROM subcontract_material_issues issue
                WHERE issue.id = :issueId AND issue.status = 0 AND NOT issue.is_deleted
                FOR UPDATE
                """).setParameter("issueId", issueId).getResultList();
        if (header.isEmpty()) {
            throw conflict("这张领料已发出、已撤回或已退回，请刷新后查看");
        }
        lockPlanRows(itemIds);
        guard.verifyUnchanged();
        if (!draftOrderItems(issueId).equals(itemIds)) {
            throw conflict("这张领料的明细刚被改过，请刷新拣货页后重试");
        }
        SubcontractMaterialPlanService.WithdrawResult result = plans.withdrawDraft(issueId, normalized);
        return new DrawWithdrawResult(result.issueIds(), result.removedLineCount());
    }

    /** 仓库待发池里这张领料草稿(待发、未作废)现有领料行涉及的订货明细, 按 id 排序。 */
    private List<UUID> draftOrderItems(UUID issueId) {
        List<UUID> ids = new ArrayList<>();
        for (Object row : em.createNativeQuery("""
                SELECT DISTINCT item.order_item_id
                FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id = item.issue_id
                 AND issue.status = 0 AND NOT issue.is_deleted AND issue.owner_pool = :pool
                WHERE item.issue_id = :issueId AND NOT item.is_deleted
                  AND item.plan_item_id IS NOT NULL AND item.order_item_id IS NOT NULL
                ORDER BY item.order_item_id
                """).setParameter("issueId", issueId)
                .setParameter("pool", SubcontractMaterialIssue.POOL_WAREHOUSE_OUTBOUND)
                .getResultList()) {
            ids.add(uuid(row));
        }
        return ids;
    }

    // ==================== 锁 ====================

    /**
     * 一次预锁(ADR-107): 订货单(含其冻结计划行物料维度、来源申请与分析) + 本批计划行物料维度
     * + 专属批次可能来自的分析 + 涉及的仓库(待发草稿所在仓; 提交时另含这些物料有库存行的作业叶仓)。
     */
    private FulfillmentMutationLocks.Guard lock(List<UUID> itemIds, boolean includeStockWarehouses) {
        Set<CommercialSource> orders = new LinkedHashSet<>();
        for (Object[] row : rows("""
                SELECT DISTINCT oi.order_id FROM subcontract_order_items oi
                WHERE oi.id IN (:ids) ORDER BY oi.order_id
                """, itemIds)) {
            orders.add(new CommercialSource(CommercialType.SUBCONTRACT_ORDER, uuid(row[0])));
        }
        FulfillmentMutationLockPlan declared = FulfillmentMutationLockPlan.declared(
                orders, planDimensions(itemIds), Set.of());
        return locks.acquire(declared, () -> discover(itemIds, includeStockWarehouses));
    }

    private FulfillmentMutationLockPlan discover(List<UUID> itemIds, boolean includeStockWarehouses) {
        List<String> parts = new ArrayList<>();
        Set<UUID> orderIds = new LinkedHashSet<>();
        for (Object[] row : rows("""
                SELECT oi.id, oi.order_id, oi.xmin::text FROM subcontract_order_items oi
                WHERE oi.id IN (:ids) ORDER BY oi.id
                """, itemIds)) {
            orderIds.add(uuid(row[1]));
            parts.add("draw-item:" + Arrays.toString(row));
        }
        List<InventoryDimension> dimensions = planDimensions(itemIds);
        parts.add("draw-dimensions:" + dimensions);
        Set<UUID> analyses = new LinkedHashSet<>();
        for (Object[] row : rows("""
                WITH applications AS (
                    SELECT source.application_item_id AS id
                    FROM subcontract_order_item_sources source
                    WHERE source.order_item_id IN (:ids) AND source.alloc_qty > 0
                    UNION
                    SELECT oi.application_item_id
                    FROM subcontract_order_items oi
                    WHERE oi.id IN (:ids) AND oi.application_item_id IS NOT NULL
                )
                SELECT action.analysis_id
                FROM applications
                JOIN preplan_supply_action_allocations allocation ON allocation.external_item_id = applications.id
                JOIN preplan_supply_actions action ON action.id = allocation.action_id
                 AND action.route = 'SUBCONTRACT' AND action.status <> 'CANCELLED'
                UNION
                SELECT action.analysis_id
                FROM applications
                JOIN preplan_supply_actions action ON action.public_surplus_external_item_id = applications.id
                 AND action.route = 'SUBCONTRACT' AND action.status <> 'CANCELLED'
                ORDER BY 1
                """, itemIds)) {
            if (row[0] != null) {
                analyses.add(uuid(row[0]));
            }
        }
        parts.add("draw-analyses:" + analyses);
        Set<UUID> warehouses = new LinkedHashSet<>();
        for (Object[] row : rows("""
                SELECT DISTINCT issue.warehouse_id
                FROM subcontract_material_issues issue
                JOIN subcontract_material_issue_items item ON item.issue_id = issue.id
                 AND NOT item.is_deleted AND item.plan_item_id IS NOT NULL
                WHERE issue.status = 0 AND NOT issue.is_deleted AND issue.warehouse_id IS NOT NULL
                  AND item.order_item_id IN (:ids)
                ORDER BY issue.warehouse_id
                """, itemIds)) {
            warehouses.add(uuid(row[0]));
        }
        if (includeStockWarehouses) {
            for (Object[] row : rows("""
                    SELECT DISTINCT balance.warehouse_id
                    FROM subcontract_material_plan_items line
                    JOIN stock_balances balance ON balance.goods_id = line.goods_id
                     AND balance.color_id IS NOT DISTINCT FROM line.color_id
                    WHERE line.order_item_id IN (:ids) AND NOT line.is_deleted
                      -- 与 fn_subcontract_draw_line_stock 同一仓口径(ADR-146 计入可用量的仓)。
                      AND fn_warehouse_counts_as_usable(balance.warehouse_id)
                    ORDER BY balance.warehouse_id
                    """, itemIds)) {
                warehouses.add(uuid(row[0]));
            }
        }
        parts.add("draw-warehouses:" + warehouses);
        FulfillmentMutationLockPlan orderPlan = footprint.orders(orderIds.stream()
                .map(id -> new ProcurementMutationFootprint.OrderRef("SUBCONTRACT", id)).toList());
        FulfillmentMutationLockPlan existing = FulfillmentMutationLockPlan.merge(
                CanonicalFingerprint.sha256(List.of(orderPlan.fingerprint(), String.join("|", parts))),
                List.of(orderPlan, new FulfillmentMutationLockPlan(Set.of(), Set.copyOf(dimensions), Set.of(),
                        analyses, "subcontract-draw")));
        List<FulfillmentMutationLockPlan> plansByWarehouse = new ArrayList<>(List.of(existing));
        parts.add(existing.fingerprint());
        for (UUID warehouse : warehouses) {
            FulfillmentMutationLockPlan inputs = footprint.withInputs(existing, CommercialType.SUBCONTRACT_ORDER,
                    itemIds, dimensions, warehouse);
            plansByWarehouse.add(inputs);
            parts.add(inputs.fingerprint());
        }
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(parts), plansByWarehouse);
    }

    private List<InventoryDimension> planDimensions(List<UUID> itemIds) {
        List<InventoryDimension> dimensions = new ArrayList<>();
        for (Object[] row : rows("""
                SELECT DISTINCT line.goods_id, line.color_id
                FROM subcontract_material_plan_items line
                WHERE line.order_item_id IN (:ids) AND NOT line.is_deleted
                """, itemIds)) {
            dimensions.add(new InventoryDimension(uuid(row[0]), uuid(row[1])));
        }
        return dimensions.stream().distinct().sorted().toList();
    }

    /** 待发草稿头先于计划行加锁(与仓库保存/审核出仓单的顺序一致)。 */
    private void lockDraftHeaders(List<UUID> itemIds) {
        em.createNativeQuery("""
                SELECT issue.id FROM subcontract_material_issues issue
                WHERE issue.status = 0 AND NOT issue.is_deleted
                  AND EXISTS (
                      SELECT 1 FROM subcontract_material_issue_items item
                      WHERE item.issue_id = issue.id AND NOT item.is_deleted
                        AND item.plan_item_id IS NOT NULL AND item.order_item_id IN (:ids))
                ORDER BY issue.id
                FOR UPDATE
                """).setParameter("ids", itemIds).getResultList();
    }

    private void lockPlanRows(List<UUID> itemIds) {
        em.createNativeQuery("""
                SELECT line.id FROM subcontract_material_plan_items line
                WHERE line.order_item_id IN (:ids) AND NOT line.is_deleted
                ORDER BY line.id
                FOR UPDATE
                """).setParameter("ids", itemIds).getResultList();
    }

    // ==================== 校验 ====================

    private void requireDrawAuthority() {
        if (!access.hasAuthority(DRAW_AUTHORITY)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少委外领料权限");
        }
    }

    /** 已获财务批准且有领料计划; 订货单须在调用者可见范围内, 并可按委外领料权限办理。 */
    private void requireOperable(List<UUID> itemIds) {
        List<Object[]> rows = rows("""
                SELECT oi.id, o.maker_id
                FROM subcontract_order_items oi
                JOIN subcontract_orders o ON o.id = oi.order_id
                WHERE oi.id IN (:ids) AND NOT oi.is_deleted AND o.status = 1 AND NOT o.is_deleted
                  AND EXISTS (SELECT 1 FROM subcontract_material_plans plan
                              WHERE plan.order_id = o.id AND NOT plan.is_deleted)
                """, itemIds);
        if (rows.size() != itemIds.size()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外任务不存在或不需要领料");
        }
        for (Object[] row : rows) {
            UUID makerId = uuid(row[1]);
            if (!access.canRead(makerId, access.scope())) {
                throw new ApiException(ErrorCode.NOT_FOUND, "委外任务不存在或不需要领料");
            }
            access.requireScopedOperationWritable(makerId, "无权为该委外订货单办理领料", DRAW_AUTHORITY);
        }
    }

    private static List<UUID> normalizeIds(List<UUID> ids) {
        List<UUID> distinct = ids == null ? List.of()
                : ids.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (distinct.isEmpty() || distinct.size() > SubcontractDrawQueryService.MAX_BATCH_ITEMS) {
            throw validation("撤回领料必须选择 1-50 个委外任务");
        }
        return distinct;
    }

    // ==================== 幂等重放 ====================

    /**
     * 同一幂等键第二次到达(上次响应丢失后的重试): 只有当时建出的草稿都还在(待仓库发或已发出)时
     * 才原样返回。草稿已被撤回、整张退回、作废或出仓已红冲, 说明这批领料的事实已经变了: 绝不能
     * 报「已提交过」假装成功, 也不能按同一主键再建(会撞主键), 一律 409 让人重新打开领料页。
     */
    private DrawSubmitResult replay(UUID actor, String key, List<UUID> itemIds) {
        List<UUID> candidates = IntStream.range(0, MAX_DOCUMENTS).mapToObj(i -> draftId(actor, key, i)).toList();
        Map<UUID, Object[]> found = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT issue.id, issue.bill_no, issue.status, issue.is_deleted,
                       (SELECT string_agg(DISTINCT item.order_item_id::text, ',')
                        FROM subcontract_material_issue_items item
                        WHERE item.issue_id = issue.id AND NOT item.is_deleted),
                       EXISTS (SELECT 1 FROM subcontract_material_issue_items gone
                               WHERE gone.issue_id = issue.id AND gone.is_deleted)
                FROM subcontract_material_issues issue
                WHERE issue.id IN (:ids)
                """).setParameter("ids", candidates))) {
            found.put(uuid(row[0]), row);
        }
        if (found.isEmpty()) {
            return null;
        }
        boolean changed = false;
        for (Object[] row : found.values()) {
            int status = row[2] == null ? -1 : ((Number) row[2]).intValue();
            if (Boolean.TRUE.equals(row[3]) || (status != 0 && status != 1)) {
                throw conflict(REPLAY_CHANGED);
            }
            changed |= Boolean.TRUE.equals(row[5]);
        }
        List<UUID> issueIds = new ArrayList<>();
        List<String> billNos = new ArrayList<>();
        Set<UUID> replayedItems = new HashSet<>();
        for (UUID candidate : candidates) {
            Object[] row = found.get(candidate);
            if (row == null) {
                break;
            }
            issueIds.add(candidate);
            billNos.add(Objects.toString(row[1], null));
            if (row[4] != null) {
                for (String id : row[4].toString().split(",")) {
                    replayedItems.add(UUID.fromString(id));
                }
            }
        }
        if (!replayedItems.equals(new HashSet<>(itemIds))) {
            // 撤回了其中部分任务的领料(行已删)也会对不上: 按「已变化」提示, 不说成键冲突。
            throw conflict(changed ? REPLAY_CHANGED : "同一操作编号对应了不同的领料批次，请重新打开领料页后再提交");
        }
        return new DrawSubmitResult(issueIds, billNos, issueIds.size(), true);
    }

    /** 新草稿主键 = UUID(账号 + 幂等键 + 序号), 重放可按序号找回。 */
    static UUID draftId(UUID actor, String key, int index) {
        return UUID.nameUUIDFromBytes(("SUBCONTRACT-DRAW:" + actor + ':' + key + ':' + index)
                .getBytes(StandardCharsets.UTF_8));
    }

    // ==================== 建草稿 ====================

    private record DraftKey(UUID orderId, UUID warehouseId) {
    }

    private record ParentGoods(UUID orderItemId, UUID goodsId, UUID colorId, String code, String name,
                               UUID supplierId, String orderBillNo, LocalDate deliverDate) {
    }

    private Map<UUID, ParentGoods> parentGoods(List<UUID> itemIds) {
        Map<UUID, ParentGoods> parents = new HashMap<>();
        for (Object[] row : rows("""
                SELECT oi.id, oi.goods_id, oi.color_id, goods.code, goods.name,
                       o.supplier_id, o.bill_no, o.deliver_date
                FROM subcontract_order_items oi
                JOIN subcontract_orders o ON o.id = oi.order_id
                LEFT JOIN goods ON goods.id = oi.goods_id
                WHERE oi.id IN (:ids)
                """, itemIds)) {
            parents.put(uuid(row[0]), new ParentGoods(uuid(row[0]), uuid(row[1]), uuid(row[2]),
                    str(row[3]), str(row[4]), uuid(row[5]), str(row[6]),
                    SubcontractDrawQueryService.localDate(row[7])));
        }
        return parents;
    }

    /**
     * 新建一张委外材料出仓草稿: 仓库待发池(无个人归属, 由持出仓权限的人办理), 建单人为提交领料的人,
     * 每行写入 requested_qty = 本次领料量(仓库只能改少)。
     */
    private void createDraft(UUID issueId, String billNo, DraftKey key,
                             List<SubcontractDrawAllocator.Slice> slices,
                             SubcontractDrawQueryService.DrawBatch batch, Map<UUID, ParentGoods> parents,
                             UUID actor, LocalDate today, OffsetDateTime now) {
        ParentGoods head = parents.get(slices.getFirst().orderItemId());
        em.createNativeQuery("""
                INSERT INTO subcontract_material_issues(
                    id, bill_no, bill_date, supplier_id, warehouse_id, maker_id, owner_pool,
                    deliver_date, remark, status, is_closed, source_doc_no, created_by, updated_by)
                VALUES (:id, :billNo, :billDate, CAST(:supplierId AS uuid), :warehouseId, NULL, :ownerPool,
                    CAST(:deliverDate AS date), :remark, 0, FALSE, CAST(:sourceDocNo AS text), :actor, :actor)
                """)
                .setParameter("id", issueId)
                .setParameter("billNo", billNo)
                .setParameter("billDate", today)
                .setParameter("supplierId", head.supplierId())
                .setParameter("warehouseId", key.warehouseId())
                .setParameter("ownerPool", SubcontractMaterialIssue.POOL_WAREHOUSE_OUTBOUND)
                .setParameter("deliverDate", head.deliverDate())
                .setParameter("remark", DRAW_REMARK)
                .setParameter("sourceDocNo", head.orderBillNo())
                .setParameter("actor", actor)
                .executeUpdate();
        int lineNo = 1;
        for (SubcontractDrawAllocator.Slice slice : slices) {
            SubcontractDrawQueryService.FactLine fact = batch.factLine(slice.planItemId());
            ParentGoods parent = parents.get(slice.orderItemId());
            em.createNativeQuery("""
                    INSERT INTO subcontract_material_issue_items(
                        id, bill_no, bill_date, issue_id, order_item_id, plan_item_id, line_no,
                        goods_id, goods_code_snapshot, goods_name_snapshot,
                        goods_snapshot_source, goods_snapshot_locked_at,
                        color_id, unit_id, unit_rate, qty, requested_qty,
                        parent_goods_id, parent_goods_code_snapshot, parent_goods_name_snapshot,
                        parent_goods_snapshot_source, parent_goods_snapshot_locked_at, parent_color_id,
                        created_by, updated_by)
                    VALUES (:id, :billNo, :billDate, :issueId, :orderItemId, :planItemId, :lineNo,
                        :goodsId, CAST(:goodsCode AS text), CAST(:goodsName AS text), :snapshotSource, :lockedAt,
                        CAST(:colorId AS uuid), CAST(:unitId AS uuid), 1, :qty, :qty,
                        :parentGoodsId, CAST(:parentCode AS text), CAST(:parentName AS text),
                        :snapshotSource, :lockedAt, CAST(:parentColorId AS uuid),
                        :actor, :actor)
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("billNo", billNo)
                    .setParameter("billDate", today)
                    .setParameter("issueId", issueId)
                    .setParameter("orderItemId", slice.orderItemId())
                    .setParameter("planItemId", slice.planItemId())
                    .setParameter("lineNo", lineNo++)
                    .setParameter("goodsId", fact.goodsId())
                    .setParameter("goodsCode", fact.goodsCode())
                    .setParameter("goodsName", fact.goodsName())
                    .setParameter("snapshotSource", SubcontractGoodsSnapshot.MASTER_AT_SAVE)
                    .setParameter("lockedAt", now)
                    .setParameter("colorId", fact.colorId())
                    .setParameter("unitId", fact.unitId())
                    .setParameter("qty", slice.qty())
                    .setParameter("parentGoodsId", parent.goodsId())
                    .setParameter("parentCode", parent.code())
                    .setParameter("parentName", parent.name())
                    .setParameter("parentColorId", parent.colorId())
                    .setParameter("actor", actor)
                    .executeUpdate();
        }
    }

    // ==================== 工具 ====================

    private List<Object[]> rows(String sql, List<UUID> ids) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery(sql).setParameter("ids", ids));
    }

    private static UUID uuid(Object value) {
        return SubcontractDrawQueryService.uuid(value);
    }

    private static String str(Object value) {
        return SubcontractDrawQueryService.str(value);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
