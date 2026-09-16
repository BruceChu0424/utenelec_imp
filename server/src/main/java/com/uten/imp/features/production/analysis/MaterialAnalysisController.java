package com.uten.imp.features.production.analysis;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.RequestUuidSets;
import com.uten.imp.features.production.mrp.GoodsWorkshopPreferenceView;
import com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** HTTP boundary for persistent pre-plan material analysis. */
@RestController
@RequestMapping("/api/production/material-analyses")
@RequiredArgsConstructor
public class MaterialAnalysisController {

    private final MaterialAnalysisService queryService;
    private final MaterialAnalysisCommandService commandService;
    private final MaterialStockReallocationService stockReallocationService;
    private final ProductionGoodsWorkshopPreferenceService workshopPreferences;
    private final MaterialAnalysisSupplyProgressService supplyProgressService;
    private final SubcontractMakeTaskService subcontractMakeTasks;
    private final AnalysisLinkedSalesOrderService linkedSalesOrders;
    private final AuditDetailViewRecorder detailViewAudit;
    private final GoodsOwningWarehouseWriteService goodsOwningWarehouses;

    @GetMapping
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public PageResponse<AnalysisListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String sourceType,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return queryService.list(keyword, status, sourceType, page, size);
    }

    @GetMapping("/sales-candidates")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public SalesCandidatePage salesCandidates(
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return queryService.salesCandidates(keyword, page, size);
    }

    /**
     * 货品 → 最近一次分析确认的供应路线（路线「学习预填」：无建议路线的物料、
     * 或上次确认与建议不同的物料，下次分析默认带出上次的选择，前端黄标/草稿
     * 提醒核对）。goodsIds 为逗号分隔 UUID，返回 {goodsId: [{colorId, unitId,
     * route, reason}]}（同货品多颜色/单位各有记忆）。
     */
    @GetMapping("/last-routes")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:route')")
    public java.util.Map<String, java.util.List<MaterialAnalysisService.LastRoutePerGoods>> lastRoutes(
            @RequestParam String goodsIds) {
        java.util.Set<UUID> ids = RequestUuidSets.commaSeparated(goodsIds, "货品 ID");
        return queryService.lastRoutesPerGoods(ids);
    }

    /**
     * 物料行 → 下游采购 / 委外申请的联动状态（ADR-081 下层办齐「已下单子件」
     * 分支）：materialLineIds 为逗号分隔 UUID。mode=ADJUSTABLE 表示申请还停在
     * 申请态、可直接把追加量并入同一张申请（V477 口径）；ORDERED 表示已分解出
     * 订货单 / 委外申请，追加量走 notify 超量通道另立追加申请。
     */
    @GetMapping("/{id}/supply-links")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public java.util.List<MaterialAnalysisService.SupplyLinkView> supplyLinks(
            @PathVariable UUID id, @RequestParam String materialLineIds) {
        java.util.Set<UUID> ids = RequestUuidSets.commaSeparated(materialLineIds, "物料行 ID");
        if (ids.size() > RequestLimits.LOOKUP_IDS) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "物料行 ID 数量必须为 1-" + RequestLimits.LOOKUP_IDS);
        }
        return queryService.supplyLinks(id, ids);
    }

    /** Learned defaults used only to prefill a new planning draft. */
    @GetMapping("/default-workshops")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public List<GoodsWorkshopPreferenceView> defaultWorkshops(
            @RequestParam("ids") Set<UUID> ids) {
        if (ids == null || ids.isEmpty()
                || ids.size() > RequestLimits.LOOKUP_IDS) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "货品 ID 数量必须为 1-" + RequestLimits.LOOKUP_IDS);
        }
        return workshopPreferences.findValidByGoodsIds(ids);
    }

    @PostMapping("/preview")
    @PreAuthorize("""
            hasAuthority('production_material_analysis:view') and (
              (#request.analysisId == null and hasAuthority('production_material_analysis:create'))
              or (#request.analysisId != null and hasAuthority('production_material_analysis:refresh'))
            )
            """)
    public AnalysisView preview(@Valid @RequestBody PreviewRequest request) {
        return queryService.preview(request);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public AnalysisView detail(@PathVariable UUID id) {
        AnalysisView result = queryService.detail(id);
        detailViewAudit.record(
                "view_material_analysis_detail", "production_material_analyses", id,
                null, null, "物料分析");
        return result;
    }

    /**
     * 关联销售订货单的货品清单(只读，ADR-088)。
     *
     * <p>物料分析顶部卡片点订单编号进入的专用只读页数据源——不是销售订单详情：
     * 只要分析查看权，且 orderId 必须确实被本张分析引用(服务端反查，见
     * {@link AnalysisLinkedSalesOrderService#linkedOrder})，一律不返回价格金额。
     */
    @GetMapping("/{id}/sales-orders/{orderId}")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public AnalysisLinkedSalesOrderService.LinkedSalesOrderView linkedSalesOrder(
            @PathVariable UUID id,
            @PathVariable UUID orderId) {
        AnalysisLinkedSalesOrderService.LinkedSalesOrderView result =
                linkedSalesOrders.linkedOrder(id, orderId);
        // 这是一次「跨模块读」：拿生产权限看销售单据明细，留痕对象记订单本身，
        // 与销售侧详情查看同一 action/targetType 对，审计里能合并成一条线索。
        detailViewAudit.record(
                "view_sales_order_detail", "sales_orders", orderId,
                null, null, "销售订货单");
        return result;
    }

    /** 物料节点供给全链路进度（只读）：下单/财务/收货/质检/入库逐步状态。 */
    @GetMapping("/{id}/materials/{materialLineId}/supply-progress")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public SupplyProgressView supplyProgress(
            @PathVariable UUID id,
            @PathVariable UUID materialLineId) {
        return supplyProgressService.supplyProgress(id, materialLineId);
    }

    @GetMapping("/{id}/materials/{materialLineId}/cross-reallocation-candidates")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:cross_reallocate')")
    public PageResponse<CrossReallocationCandidate> crossReallocationCandidates(
            @PathVariable UUID id,
            @PathVariable UUID materialLineId,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return stockReallocationService.candidates(
                id, materialLineId, keyword, page, size);
    }

    @GetMapping("/{id}/materials/{materialLineId}/cross-reallocation-sources")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:cross_reallocate')")
    public PageResponse<CrossReallocationSourceCandidate> crossReallocationSources(
            @PathVariable UUID id,
            @PathVariable UUID materialLineId,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return stockReallocationService.sources(id, materialLineId, keyword, page, size);
    }

    @PostMapping("/{id}/cross-reallocations")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:cross_reallocate')")
    public AnalysisView createCrossReallocation(
            @PathVariable UUID id,
            @Valid @RequestBody CrossReallocationRequest request,
            @RequestParam(defaultValue = "false") boolean returnTarget) {
        return returnTarget
                ? stockReallocationService.createReturningTarget(id, request)
                : stockReallocationService.create(id, request);
    }

    @GetMapping("/{id}/cross-reallocations/{reallocationId}/replenishment-preview")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public CrossReallocationReplenishmentView crossReallocationReplenishmentPreview(
            @PathVariable UUID id, @PathVariable UUID reallocationId) {
        return stockReallocationService.replenishmentPreview(id, reallocationId);
    }

    @GetMapping("/{id}/cross-reallocation-replenishment-preview")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public CrossReallocationReplenishmentView crossReallocationReplenishmentForCommand(
            @PathVariable UUID id, @RequestParam String idempotencyKey) {
        return stockReallocationService.replenishmentPreviewForCommand(id, idempotencyKey);
    }

    @PostMapping("/{id}/cross-reallocations/{reallocationId}/revoke")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:cross_reallocate')")
    public AnalysisView revokeCrossReallocation(
            @PathVariable UUID id,
            @PathVariable UUID reallocationId,
            @Valid @RequestBody CrossReallocationRevokeRequest request) {
        return stockReallocationService.revoke(id, reallocationId, request);
    }

    @PutMapping("/{id}/routes")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:route')")
    public AnalysisView saveRoutes(
            @PathVariable UUID id,
            @Valid @RequestBody RouteRequest request) {
        return queryService.saveRoutes(id, request);
    }

    /**
     * 货品主档「所属仓库」回写 (V587)：计划员在物料分析各表里改这批货平时归哪个
     * 仓管，保存即写回 goods 主档，返回 {updated, skipped}。owningWarehouseId
     * 传 null = 清空。不是分析级数据，故不挂在 /{id} 下。
     *
     * <p>权限为什么复用 :route 这把锁：所属仓库与供料路线是同一类「计划员在分析页
     * 维护的货品级计划属性」——同一批人、同一屏、同一次保存动作，另铸一个权限码要
     * 再发一版迁移并登记权限目录 (V228 两级权限目录)，不值当。查看权 + 路线维护权
     * 同时具备才放行。
     */
    @PutMapping("/goods-owning-warehouses")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:route')")
    public java.util.Map<String, Integer> saveGoodsOwningWarehouses(
            @Valid @RequestBody
            List<GoodsOwningWarehouseWriteService.OwningWarehouseRequest> requests) {
        return goodsOwningWarehouses.applyOwningWarehouses(requests);
    }

    @PutMapping("/{id}/allocation-priorities")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:reallocate')")
    public AnalysisView saveAllocationPriorities(
            @PathVariable UUID id,
            @Valid @RequestBody AllocationPriorityRequest request) {
        return queryService.saveAllocationPriorities(id, request);
    }

    /** 现货层借用（调货）：把一条直接组件路径的已分配覆盖量调给另一产品同物料路径。 */
    @PostMapping("/{id}/borrows")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:reallocate')")
    public AnalysisView createBorrow(
            @PathVariable UUID id,
            @Valid @RequestBody BorrowRequest request) {
        return queryService.createBorrow(id, request);
    }

    /** 撤销一笔 ACTIVE 借用，恢复基线分配投影。 */
    @PostMapping("/{id}/borrows/{borrowId}/revoke")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:reallocate')")
    public AnalysisView revokeBorrow(
            @PathVariable UUID id,
            @PathVariable UUID borrowId,
            @Valid @RequestBody CancelRequest request) {
        return queryService.revokeBorrow(id, borrowId, request);
    }

    @PostMapping("/{id}/notify")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:notify')")
    public AnalysisView notifySupply(
            @PathVariable UUID id,
            @Valid @RequestBody NotifyRequest request) {
        return commandService.notifySupply(id, request);
    }

    @PostMapping("/{id}/claim-shared-future")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:claim_shared_future')")
    public AnalysisView claimSharedFuture(
            @PathVariable UUID id,
            @Valid @RequestBody ClaimSharedFutureRequest request) {
        return commandService.claimSharedFuture(id, request);
    }

    /** V458：有子层级委外件的前置自制任务进度（先自制、后通知委外的账本投影）。 */
    @GetMapping("/subcontract-make-tasks")
    @PreAuthorize("hasAnyAuthority('production_material_analysis:view',"
            + " 'subcontract_application:view')")
    public PageResponse<SubcontractMakeTaskService.TaskView> subcontractMakeTasks(
            @RequestParam(required = false) UUID analysisId,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return subcontractMakeTasks.tasks(
                new SubcontractMakeTaskService.TaskPageRequest(
                        page, size, status, keyword, analysisId));
    }

    /** V458：按已产未通知量分批通知委外（生成只读委外申请并通知委外部）。 */
    @GetMapping("/subcontract-make-tasks/{taskId}")
    @PreAuthorize("hasAnyAuthority('production_material_analysis:view', 'subcontract_application:view')")
    public SubcontractMakeTaskService.TaskView subcontractMakeTask(@PathVariable UUID taskId) {
        return subcontractMakeTasks.task(taskId);
    }

    @PostMapping("/subcontract-make-tasks/{taskId}/notify")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:notify')")
    public SubcontractMakeTaskService.NotifyResult notifySubcontractMakeBatch(
            @PathVariable UUID taskId,
            @Valid @RequestBody SubcontractMakeTaskService.NotifyRequest request) {
        return subcontractMakeTasks.notifyBatch(taskId, request);
    }

    /**
     * 下达车间（ADR-071）：所有自制行一视同仁——候选行先建子件任务，随后按
     * 行内数量/车间/负责人逐行生成生产计划；有审核权限同事务审核下达。缺料
     * 批次生成 WAITING 段，由车间侧等料齐套自动提升，计划侧不再做齐套判断。
     * 整个操作单事务原子完成：任一行失败全部回滚，不会残留已建子件行。
     */
    @PostMapping("/{id}/issue-plans")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:generate')")
    public GenerateResult issueWorkshopPlans(
            @PathVariable UUID id,
            @Valid @RequestBody IssueWorkshopPlansRequest request) {
        return commandService.issueWorkshopPlans(id, request);
    }

    @PostMapping("/{id}/cancel")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:cancel')")
    public AnalysisView cancelAnalysis(
            @PathVariable UUID id,
            @Valid @RequestBody CancelRequest request) {
        return commandService.cancelAnalysis(id, request);
    }

    @PostMapping("/{id}/actions/{actionId}/cancel")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and (hasAuthority('production_material_analysis:notify') or hasAuthority('production_material_analysis:claim_shared_future'))")
    public AnalysisView cancelAction(
            @PathVariable UUID id,
            @PathVariable UUID actionId,
            @Valid @RequestBody CancelRequest request) {
        return commandService.cancelAction(id, actionId, request);
    }

    @PostMapping("/{id}/root-outputs/{eventId}/revoke")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:notify')")
    public AnalysisView revokeRootOutput(
            @PathVariable UUID id, @PathVariable UUID eventId,
            @Valid @RequestBody CancelRequest request) {
        return commandService.revokeRootOutput(id,eventId,request);
    }
}
