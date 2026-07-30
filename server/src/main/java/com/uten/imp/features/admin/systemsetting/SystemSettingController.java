package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * 系统设置管理端（仅超级管理员 user:manage，与 AdminPermission/AdminUserController 一致）。
 *
 * <p>读侧：GET 列出全部设置（按 category 分组，前端渲染表单）。
 * <p>写侧：PUT 单项更新（类型校验 + 审计，见 {@link SystemSettingsService#write}）。
 */
@RestController
@RequestMapping("/api/admin/system-settings")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('user:manage')")
public class SystemSettingController {

    private final SystemSettingsService service;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    public List<SystemSettingDto> list() {
        return service.list();
    }

    @PutMapping("/{key}")
    public SystemSettingDto update(@PathVariable String key, @RequestBody SystemSettingDto.Update body) {
        AuthUser u = currentUser.get().orElseThrow(() -> new IllegalStateException("未登录"));
        return service.write(key, body.value(), body.password(), u.getId(), u.getLoginAccount());
    }
}
