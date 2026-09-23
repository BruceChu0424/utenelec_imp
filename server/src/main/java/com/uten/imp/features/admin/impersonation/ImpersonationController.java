package com.uten.imp.features.admin.impersonation;

import com.uten.imp.features.admin.impersonation.dto.ImpersonationModeResponse;
import com.uten.imp.features.admin.impersonation.dto.ImpersonationStartRequest;
import com.uten.imp.features.admin.impersonation.dto.ImpersonationStartResponse;
import com.uten.imp.features.admin.impersonation.dto.ImpersonationTargetDto;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.StepUpExempt;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 超级管理员「切换人 / 模拟身份」端点。
 *
 * <ul>
 *   <li>{@code POST /enter}、{@code POST /start}：由 admin token 调用，要求
 *       {@code authorization:manage and principal.superAdmin}。进入切换人要求再认证
 *       ({@link RequiresStepUp}, 与其它敏感操作共用失败计数); 窗口内凭模式凭证切换不同目标。</li>
 *   <li>{@code POST /end}：由模拟 token 调用（主体=目标，非超管），故不加 superAdmin 守卫；
 *       服务内按 {@code impersonatedBy} 判定，非模拟时幂等。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/admin/impersonation")
@RequiredArgsConstructor
public class ImpersonationController {

    private final ImpersonationService service;

    /** 模拟目标候选（picker）：始终用 admin 凭证加载（前端拦截器把 /targets 当管理端点）。 */
    @GetMapping("/targets")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<ImpersonationTargetDto> targets(
            @RequestParam(required = false) String search) {
        return service.listTargets(search);
    }

    @PostMapping("/enter")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    @RequiresStepUp
    public ImpersonationModeResponse enter() {
        return service.enter();
    }

    @PostMapping("/start")
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    @StepUpExempt("凭进入切换人时再认证换得的模式凭证 (绑定本人与本会话、限时), 窗口内切换不同目标不必再输密码")
    public ImpersonationStartResponse start(@Valid @RequestBody ImpersonationStartRequest req) {
        return service.start(req.targetEmployeeId(), req.modeToken());
    }

    @PostMapping("/end")
    @StepUpExempt("退出切换人只会收回临时视角, 不扩大任何权限")
    public ResponseEntity<Void> end() {
        service.end();
        return ResponseEntity.noContent().build();
    }
}
