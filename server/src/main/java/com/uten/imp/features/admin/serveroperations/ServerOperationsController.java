package com.uten.imp.features.admin.serveroperations;

import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.StepUpExempt;
import jakarta.validation.Valid;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/admin/server-operations")
@RequiredArgsConstructor
public class ServerOperationsController {
    private final ServerOperationsService service;

    @GetMapping("/status")
    @PreAuthorize(ServerOperationsPermissions.READ_EXPRESSION)
    public ServerOperationsDto.Status status() { return service.status(); }

    @GetMapping("/source")
    @PreAuthorize(ServerOperationsPermissions.SOURCE_EXPRESSION)
    public ServerOperationsDto.SourceView source() { return service.source(); }

    @PutMapping("/source")
    @PreAuthorize(ServerOperationsPermissions.SOURCE_EXPRESSION)
    @RequiresStepUp
    public ServerOperationsDto.SourceView save(@Valid @RequestBody ServerOperationsDto.SourceSave body) {
        return service.saveSource(body);
    }

    @PostMapping("/updates")
    @PreAuthorize(ServerOperationsPermissions.UPDATE_EXPRESSION)
    @RequiresStepUp
    @ResponseStatus(HttpStatus.ACCEPTED)
    public ServerOperationsDto.Job start(@Valid @RequestBody ServerOperationsDto.UpdateStart body) {
        return service.start(body);
    }

    @PostMapping("/updates/check")
    @PreAuthorize(ServerOperationsPermissions.UPDATE_EXPRESSION)
    @StepUpExempt("手动检查受信发布源版本，只写检查任务回执，不安装、不停机、不修改发布源；仍须服务器更新权限")
    @ResponseStatus(HttpStatus.ACCEPTED)
    public ServerOperationsDto.Job check(@Valid @RequestBody ServerOperationsDto.Check body) {
        return service.check(body);
    }

    @PostMapping("/updates/schedule-preview")
    @PreAuthorize(ServerOperationsPermissions.UPDATE_EXPRESSION)
    @StepUpExempt("只读解析服务器当地预约时间，不保存预约、不连接发布源、不执行更新；保存预约另须再认证")
    public ServerOperationsDto.ScheduleSlot schedule(@Valid @RequestBody ServerOperationsDto.SchedulePreview body) {
        return service.schedulePreview(body);
    }

    @PostMapping("/updates/{jobId}/cancel")
    @PreAuthorize(ServerOperationsPermissions.UPDATE_EXPRESSION)
    @RequiresStepUp
    public ServerOperationsDto.Job cancel(@PathVariable UUID jobId,
            @Valid @RequestBody ServerOperationsDto.Cancel body) {
        return service.cancel(jobId, body);
    }

    @GetMapping("/updates/latest")
    @PreAuthorize(ServerOperationsPermissions.READ_EXPRESSION)
    public ServerOperationsDto.LatestJob latest() { return service.latest(); }

    @GetMapping("/updates/{jobId}")
    @PreAuthorize(ServerOperationsPermissions.READ_EXPRESSION)
    public ServerOperationsDto.Job job(@PathVariable UUID jobId) { return service.byId(jobId); }
}
