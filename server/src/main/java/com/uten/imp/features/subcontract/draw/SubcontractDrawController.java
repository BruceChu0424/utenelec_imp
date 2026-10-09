package com.uten.imp.features.subcontract.draw;

import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawCloseRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawCloseResult;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreview;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawPreviewRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawSubmitResult;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskMaterials;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawTaskPage;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawWithdrawRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawWithdrawResult;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 委外任务中心「领料」(ADR-143 §4.1/§4.2): 委外任务列表、任务详情、批量领料预览与提交、
 * 撤回未发领料、结束领料。查看与预览需 {@code subcontract_order:view}; 提交、撤回、结束领料需
 * {@code subcontract_order:draw}; 另按委外订货单的经手人可见范围做对象级过滤。
 */
@RestController
@RequestMapping("/api/subcontract/draw-tasks")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('subcontract_order:view')")
public class SubcontractDrawController {

    private final SubcontractDrawQueryService queries;
    private final SubcontractDrawCommandService commands;

    /** 委外任务分页(状态/关键字/订货单/明细筛选) + 分段计数 + 能力位。 */
    @GetMapping
    public DrawTaskPage tasks(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "") String status,
            @RequestParam(required = false) UUID orderId,
            @RequestParam(required = false) List<UUID> orderItemIds) {
        return queries.tasks(page, size, keyword, status, orderId, orderItemIds);
    }

    /**
     * 领料计数: {@code drawable} = 可领且调用者能动手的行数(红, 无委外领料权限恒为 0);
     * {@code submitted} = 已提交领料、等仓库发出的行数(黄, ADR-171 修订二)。
     */
    @GetMapping("/count")
    public Map<String, Long> count() {
        return Map.of("drawable", queries.countDrawable(),
                "submitted", queries.countSubmitted());
    }

    /** 任务详情: 物料表、待仓库发的领料草稿、服务端允许的动作。 */
    @GetMapping("/{orderItemId}/materials")
    public DrawTaskMaterials materials(@PathVariable UUID orderItemId) {
        return queries.materials(orderItemId);
    }

    /** 批量领料预览: 按交期、订货单号、行号联合分配共享物料(只读)。 */
    @PostMapping("/preview")
    public DrawPreview preview(@RequestBody DrawPreviewRequest request) {
        return queries.preview(request);
    }

    /** 提交领料: 锁内重算, 按「订货单 × 仓库」新建委外材料出仓草稿并通知仓库; 幂等键防重复提交。 */
    @PostMapping("/submit")
    @PreAuthorize("hasAuthority('subcontract_order:view') and hasAuthority('subcontract_order:draw')")
    public DrawSubmitResult submit(@RequestBody DrawSubmitRequest request) {
        return commands.submit(request);
    }

    /** 撤回所选委外任务还没发出的领料(仓库已改过拣货的拒绝)。 */
    @PostMapping("/withdraw")
    @PreAuthorize("hasAuthority('subcontract_order:view') and hasAuthority('subcontract_order:draw')")
    public DrawWithdrawResult withdraw(@RequestBody DrawWithdrawRequest request) {
        return commands.withdraw(request);
    }

    /** 结束领料(不再发外): 撤回未发领料、关闭本明细的领料计划行、重评短交; 必填原因。 */
    @PostMapping("/{orderItemId}/close")
    @PreAuthorize("hasAuthority('subcontract_order:view') and hasAuthority('subcontract_order:draw')")
    public DrawCloseResult close(@PathVariable UUID orderItemId, @RequestBody DrawCloseRequest request) {
        return commands.close(orderItemId, request);
    }
}
