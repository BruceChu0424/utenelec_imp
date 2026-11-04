package com.uten.imp.responsibility;

import com.uten.imp.responsibility.dto.DataHandoverCandidatePage;
import com.uten.imp.responsibility.dto.DataHandoverPreview;
import com.uten.imp.responsibility.dto.DataHandoverRequest;
import com.uten.imp.responsibility.dto.DataHandoverResult;
import com.uten.imp.security.StepUpExempt;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Set;
import java.util.List;
import java.util.UUID;

/** Administrative API for previewing and atomically executing employee responsibility handovers. */
@RestController
@RequestMapping("/api/admin/data-handovers")
@RequiredArgsConstructor
public class DataHandoverAdminController {

    private final DataHandoverService service;
    private final DataHandoverCandidateService candidates;

    @GetMapping("/preview")
    @PreAuthorize("hasAuthority('employee:handover') or (principal.superAdmin and hasAuthority('authorization:manage'))")
    public DataHandoverPreview preview(
            @RequestParam UUID sourceEmployeeId,
            @RequestParam(required = false) UUID targetEmployeeId,
            @RequestParam(required = false) Set<String> scopes) {
        return service.preview(sourceEmployeeId, targetEmployeeId, scopes);
    }

    @GetMapping("/candidates")
    @PreAuthorize("hasAnyAuthority('employee:handover','employee:offboard') or (principal.superAdmin and hasAuthority('authorization:manage'))")
    public DataHandoverCandidatePage candidates(
            @RequestParam String role,
            @RequestParam(required = false, defaultValue = "") String query,
            @RequestParam(required = false, defaultValue = "1") int page,
            @RequestParam(required = false, defaultValue = "20") int size,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(defaultValue = "false") boolean includeSubtree,
            @RequestParam(required = false) List<UUID> excludeEmployeeIds) {
        return candidates.search(role, query, page, size, departmentId, includeSubtree, excludeEmployeeIds);
    }

    @PostMapping("/candidates/query")
    @PreAuthorize("hasAnyAuthority('employee:handover','employee:offboard') or (principal.superAdmin and hasAuthority('authorization:manage'))")
    @StepUpExempt("与原候选GET同权的纯读分页，排除集仅放入请求体；不提交、不执行或修改交接")
    public DataHandoverCandidatePage queryCandidates(@Valid @RequestBody CandidateQuery request) {
        return candidates.search(request.role(), request.query(), request.page() == null ? 1 : request.page(),
                request.size() == null ? 20 : request.size(), request.departmentId(),
                Boolean.TRUE.equals(request.includeSubtree()), request.excludeEmployeeIds());
    }

    public record CandidateQuery(@jakarta.validation.constraints.NotBlank String role,
            @jakarta.validation.constraints.Size(max = 100) String query,
            Integer page, Integer size, UUID departmentId, Boolean includeSubtree,
            @jakarta.validation.constraints.Size(max = com.uten.imp.common.validation.RequestLimits.ADMIN_SCOPE_OWNERS)
            List<@jakarta.validation.constraints.NotNull UUID> excludeEmployeeIds) { }

    @PostMapping
    @StepUpExempt("离职/调岗数据交接是人事按 employee:handover 办理的日常业务流转, 已有预览确认与交接审计, 不改授权与凭据")
    @PreAuthorize("hasAuthority('employee:handover') or (principal.superAdmin and hasAuthority('authorization:manage'))")
    public DataHandoverResult execute(@Valid @RequestBody DataHandoverRequest request) {
        return service.executeManual(request);
    }
}
