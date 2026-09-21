package com.uten.imp.features.rd_task;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.rd_task.RdTaskContracts.AssignRequest;
import com.uten.imp.features.rd_task.RdTaskContracts.RdTaskInput;
import com.uten.imp.features.rd_task.RdTaskContracts.RdTaskRow;
import com.uten.imp.features.rd_task.RdTaskContracts.ResolveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * 工程研发部任务中心 REST。/api/rd-tasks。
 * list/count/create/assign/resolve 分别使用 view/create/assign/resolve，不做隐式 AND。
 */
@RestController
@RequestMapping("/api/rd-tasks")
@RequiredArgsConstructor
public class RdTaskController {

    private final RdTaskService service;

    /**
     * @param status 分段范围：open(待处理+进行中，默认，老调用点口径不变) /
     *               pending(仅待处理) / in_progress(仅进行中) / done(已完成+已取消)。
     *               ADR-100 把「待完成」拆成红黄两段后，两段各要能点进来。
     */
    @GetMapping
    @PreAuthorize("hasAuthority('rd_task:view')")
    public PageResponse<RdTaskRow> list(
            @RequestParam(defaultValue = "open") String status,
            @RequestParam(required = false) String category,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID assignee,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(status, category, keyword, assignee, page, size);
    }

    /**
     * 任务中心计数。count 保持旧含义(待处理 + 进行中)，老调用点零改动；
     * ADR-100 另给出两档：open 走红徽章(还没人接手)，inProgress 走黄徽章(已接手在办)。
     */
    @PreAuthorize("hasAuthority('rd_task:view')")
    @GetMapping("/count")
    public Map<String, Long> count() {
        RdTaskService.RdTaskCounts counts = service.counts();
        return Map.of(
                "count", counts.total(),
                "open", counts.open(),
                "inProgress", counts.inProgress());
    }

    @PostMapping
    @PreAuthorize("hasAuthority('rd_task:create')")
    public RdTaskRow create(@RequestBody @Valid RdTaskInput input) {
        return service.create(input);
    }

    @PostMapping("/{id}/resolve")
    @PreAuthorize("hasAuthority('rd_task:resolve')")
    public RdTaskRow resolve(@PathVariable UUID id, @RequestBody @Valid ResolveRequest req) {
        return service.resolve(id, req.expectedVersion(), req.note());
    }

    @PostMapping("/{id}/assign")
    @PreAuthorize("hasAuthority('rd_task:assign')")
    public RdTaskRow assign(@PathVariable UUID id, @RequestBody AssignRequest req) {
        return service.assign(id, req.assigneeEmployeeId());
    }
}
