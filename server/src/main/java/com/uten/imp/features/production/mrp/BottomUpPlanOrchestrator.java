package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * 自底向上、最深层优先的计划分解（#13）。
 *
 * <p>对顶层成品计划做一次「整树确认」：复用既有逐层 {@link ProductionPlanningPackageService#confirm}
 * 建第一层，然后递归下行——对每个自动生成的 MAKE 子计划 {@code autoApprove}（status 0→1，无人工审核副作用）
 * 再 {@code confirm}（建本层执行段 + 下一层草稿子计划 + MAKE supply peg），直到自制叶子件。
 *
 * <p><b>建造自顶向下；就绪/执行自底向上</b>：最深 MAKE 叶段先齐套就绪；下层完工入库经既有 V194 钩子
 * （{@code ProductionExecutionReadinessService.onFinishedInboundApproved}）自动把父 WAITING 段升 READY，
 * 天然链式（C 完工→B 就绪→B 完工→A 就绪）。本类不重写 {@code confirm}、不碰 V194，仅组合。
 *
 * <p>整树单事务（all-or-nothing，符合「整包确认」）；每层 confirm 的 idempotencyKey 确定性派生
 * （root:L{depth}:{childPlanId}），整树重放幂等。
 *
 * <p>能力开关在控制器层（{@code production.bottom-up-orchestrator.enabled}，默认关）门控 HTTP 入口；
 * 本服务本身始终可用，便于服务级 E2E 验证。
 */
@Service
@RequiredArgsConstructor
public class BottomUpPlanOrchestrator {

    private static final int MAX_DEPTH = 10;

    private final ProductionPlanningPackageService packageService;
    private final ProductionPlanService planService;
    private final MrpService mrpService;
    private final TxSessionVars tx;

    /**
     * 确认顶层计划并递归建出整棵 MAKE 子计划树。
     *
     * @return 顶层计划的 {@link PlanningPackageResult}（其 {@code subplans()} 含直层 MAKE 子）
     */
    @Transactional
    public PlanningPackageResult confirmFullTree(UUID planId, GeneratePlanningPackageRequest request) {
        tx.bind();
        // 提前校验 BOM 图（环 / 超 10 层 → 硬错），避免建到一半才发现深层异常
        mrpService.preview(planId);
        PlanningPackageResult topResult = packageService.confirm(planId, request);
        confirmDescendants(topResult.subplans(), request.getWarehouseId(),
                request.getIdempotencyKey(), 1);
        return topResult;
    }

    /** 递归下行：自动审核 + 确认每个 MAKE 子计划，直到无下层自制件。 */
    private void confirmDescendants(List<GenerateSubplansRequest.Created> children,
                                    UUID warehouseId, String rootIdemKey, int depth) {
        if (children == null || children.isEmpty()) {
            return; // 到达自制叶子件，本枝结束
        }
        if (depth > MAX_DEPTH) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "MAKE 树超过 " + MAX_DEPTH + " 层，禁止继续展开");
        }
        for (GenerateSubplansRequest.Created child : children) {
            // (a) 最小化审核 0→1（戳 bom_depth + auto_generated；无销售联动/通知副作用）
            planService.autoApproveForOrchestrator(child.planId(), depth);
            // (b) 自制叶子件（无 BOM）没有可展开的子件：仅审核使其可报工/入库，不调 confirm
            //     （confirm 的 snapshot 内联 goods_bom_items，无 BOM 会得空产品行）。与人工流程一致。
            if (!mrpService.planGoodsHasBom(child.planId())) {
                continue;
            }
            // (c) 本层 preview 取 execution-segment fingerprint
            PlanningPreviewResult childPreview = packageService.preview(child.planId(), warehouseId);
            // (d) 构造本层确认请求：确定性 idempotencyKey（整树重放幂等）、同仓、生成采购申请
            GeneratePlanningPackageRequest childReq = new GeneratePlanningPackageRequest();
            childReq.setWarehouseId(warehouseId);
            childReq.setIdempotencyKey(rootIdemKey + ":L" + depth + ":" + child.planId());
            childReq.setPreviewFingerprint(childPreview.fingerprint());
            childReq.setGeneratePurchaseRequest(true);
            // (e) confirm 本层（建执行段 + 下一层草稿子计划 + MAKE peg）；replayed 时幂等不重建
            PlanningPackageResult childResult = packageService.confirm(child.planId(), childReq);
            // (f) 继续下行（replayed 也下行，以补建任何缺失的更深层；各层幂等保证不重复）
            confirmDescendants(childResult.subplans(), warehouseId, rootIdemKey, depth + 1);
        }
    }
}
