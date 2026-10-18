package com.uten.imp.features.admin;

import com.uten.imp.features.admin.dto.PermissionTransferDtos.*;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.StepUpExempt;
import com.uten.imp.common.web.JsonBodyLimit;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;

@RestController
@RequestMapping("/api/admin")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class PermissionConfigurationTransferController {
    private final PermissionConfigurationTransferService transfer;
    @GetMapping("/permission-configuration/export")
    public Backup exportConfiguration() { return transfer.exportConfiguration(); }
    @PostMapping("/permission-configuration/import/preview")
    @StepUpExempt("只读检查备份与匹配、计算权限差量，不保存授权；正式导入另需再认证")
    @JsonBodyLimit(18 * 1024 * 1024)
    public Preview previewImport(@Valid @RequestBody ImportRequest request) { return transfer.previewImport(request); }
    @PostMapping("/permission-configuration/import")
    @RequiresStepUp
    @JsonBodyLimit(18 * 1024 * 1024)
    public Result importConfiguration(@Valid @RequestBody ImportCommit request) { return transfer.importConfiguration(request); }
    @GetMapping("/users/{sourceId}/permission-copy")
    public CopySnapshot copySnapshot(@PathVariable UUID sourceId) { return transfer.copySnapshot(sourceId); }
    @PostMapping("/users/{targetId}/permission-copy/preview")
    @StepUpExempt("只读比较来源与目标的操作权限，不保存授权；正式粘贴另需再认证")
    public Preview previewCopy(@PathVariable UUID targetId, @Valid @RequestBody CopyRequest request) { return transfer.previewCopy(targetId, request); }
    @PostMapping("/users/{targetId}/permission-copy")
    @RequiresStepUp
    public Result copyPermissions(@PathVariable UUID targetId, @Valid @RequestBody CopyCommit request) { return transfer.copyPermissions(targetId, request); }
}
