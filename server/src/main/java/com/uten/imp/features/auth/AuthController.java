package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.auth.dto.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {

    private final AuthService authService;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;

    @PostMapping("/login")
    public TokenResponse login(@Valid @RequestBody LoginRequest req, HttpServletRequest http) {
        // 限流键用连接 IP（getRemoteAddr，不可被 X-Forwarded-For 伪造）；审计 IP 仍由 AuditService 取 XFF
        return authService.login(req, http.getRemoteAddr());
    }

    @PostMapping("/refresh")
    public TokenResponse refresh(@Valid @RequestBody RefreshRequest req) {
        return authService.refresh(req.refreshToken());
    }

    @PostMapping("/logout")
    public void logout(@RequestBody(required = false) RefreshRequest req) {
        String raw = req == null ? null : req.refreshToken();
        authService.logout(raw);
        currentUser.id().ifPresent(id ->
                audit.log("logout", "users", id.toString(), "success"));
    }

    @PostMapping("/change-password")
    public TokenResponse changePassword(@Valid @RequestBody ChangePasswordRequest req) {
        // 返回新令牌：当前设备保持登录（其他设备刷新令牌已失效）
        return authService.changePassword(req);
    }

    @GetMapping("/me")
    public TokenResponse.UserProfile me() {
        return authService.me(currentUser::requireId);
    }

    /**
     * 二次确认密码（不改密；用于"修改个人信息/手机/姓名"等敏感动作前的校验）。
     * 200 OK → 密码正确；401 BAD_CREDENTIALS → 密码错误。
     * 不计入登录失败计数（不影响 lockout），但审计日志落 "verify_password" 记录。
     */
    @PostMapping("/verify-password")
    public void verifyPassword(@Valid @RequestBody VerifyPasswordRequest req) {
        authService.verifyPassword(req.password());
    }

    private String clientIp(HttpServletRequest req) {
        String xff = req.getHeader("X-Forwarded-For");
        if (xff != null && !xff.isBlank()) {
            return xff.split(",")[0].trim();
        }
        return req.getRemoteAddr();
    }
}
