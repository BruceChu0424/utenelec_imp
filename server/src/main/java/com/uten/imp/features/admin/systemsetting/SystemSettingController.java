package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 系统设置管理端 (仅超级管理员 authorization:manage)。
 *
 * <p>读侧: GET 列出全部登记项 (带取值范围, 前端直接按范围校验)。
 * <p>写侧: 只有 PUT 批量保存一条路 (期望旧值防覆盖 + 服务端范围校验 + 审计), 入口要求再认证。
 */
@RestController
@RequestMapping("/api/admin/system-settings")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class SystemSettingController {

    private final SystemSettingsService service;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    public List<SystemSettingDto> list() {
        return service.list();
    }

    @PutMapping
    @RequiresStepUp
    public List<SystemSettingDto> updateBatch(@Valid @RequestBody SystemSettingDto.BatchUpdate body) {
        AuthUser u = currentUser.get().orElseThrow(() -> new IllegalStateException("未登录"));
        return service.writeBatch(body, u.getId(), u.getLoginAccount());
    }
}
