package com.uten.imp.features.auth;

import com.uten.imp.features.auth.dto.ChangePasswordRequest;
import com.uten.imp.features.auth.dto.LoginRequest;
import com.uten.imp.features.auth.dto.RefreshRequest;
import com.uten.imp.features.auth.dto.StepUpRequest;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** 认证接口（/api/auth）：登录/刷新/登出/改密/当前用户/敏感操作再认证。 */
@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {

    private final LoginService loginService;
    private final PasswordService passwordService;
    private final TokenIssuer tokenIssuer;
    private final StepUpService stepUpService;
    private final SecurityContextCurrentUser currentUser;

    @PostMapping("/login")
    public TokenResponse login(@Valid @RequestBody LoginRequest req, HttpServletRequest http) {
        // 限流与审计均记录容器看到的连接 IP；可信反向代理应在边界层清洗并终结转发头。
        return loginService.login(req, http.getRemoteAddr());
    }

    @PostMapping("/refresh")
    public TokenResponse refresh(@Valid @RequestBody RefreshRequest req) {
        return tokenIssuer.refresh(req.refreshToken());
    }

    @PostMapping("/logout")
    public void logout(@Valid @RequestBody(required = false) RefreshRequest req) {
        String raw = req == null ? null : req.refreshToken();
        // Public logout deliberately has no access-token principal. TokenIssuer derives
        // the actor only from a matching refresh-token row and audits after revocation.
        tokenIssuer.logout(raw);
    }

    @PostMapping("/change-password")
    public TokenResponse changePassword(@Valid @RequestBody ChangePasswordRequest req) {
        // 返回新令牌：当前设备保持登录（其他设备刷新令牌已失效）。
        return passwordService.changePassword(req);
    }

    @GetMapping("/me")
    public TokenResponse.UserProfile me() {
        return tokenIssuer.me(currentUser::requireId);
    }

    /**
     * 敏感操作再认证: 输入当前登录密码, 换取本会话专用、5 分钟、一次性的凭证 (ADR-110)。
     * 之后把凭证放进请求头 X-Uten-Step-Up 调用标了 {@code @RequiresStepUp} 的接口。
     * 输错 422 REAUTH_FAILED; 连续输错达上限 429 REAUTH_LOCKED 并吊销当前会话。
     */
    @PostMapping("/step-up")
    public StepUpService.Grant stepUp(@Valid @RequestBody StepUpRequest req) {
        return stepUpService.issue(req.password());
    }
}
