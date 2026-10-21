package com.uten.imp.features.admin;

import com.uten.imp.features.admin.dto.PermissionTemplateDtos.*;
import com.uten.imp.features.admin.dto.PermissionTransferDtos.*;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.StepUpExempt;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/admin")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class PermissionTemplateController {
    private final PermissionTemplateService templates;
    @GetMapping("/permission-templates") public List<Template> list() { return templates.list(); }
    @PostMapping("/permission-templates") @RequiresStepUp
    public Template create(@Valid @RequestBody Save request) { return templates.create(request); }
    @PutMapping("/permission-templates/{id}") @RequiresStepUp
    public Template update(@PathVariable UUID id, @Valid @RequestBody Save request) { return templates.update(id,request); }
    @PostMapping("/permission-templates/{id}/delete") @RequiresStepUp
    public void delete(@PathVariable UUID id, @Valid @RequestBody Delete request) { templates.delete(id,request); }
    @PostMapping("/users/{targetId}/permission-template/preview")
    @StepUpExempt("只读预览权限模板差量；正式应用另需再认证")
    public Preview preview(@PathVariable UUID targetId, @Valid @RequestBody Apply request) { return templates.preview(targetId,request); }
    @PostMapping("/users/{targetId}/permission-template") @RequiresStepUp
    public Result apply(@PathVariable UUID targetId, @Valid @RequestBody Commit request) { return templates.apply(targetId,request); }
}
