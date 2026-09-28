package com.uten.imp.features.ai;

import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * {@code GET /api/ai/status}(ADR-133): 当前账号能否用上 AI。只给员工账号; 不返回服务商、模型等配置细节。
 */
@RestController
@RequestMapping("/api/ai")
@PreAuthorize("isAuthenticated() and !principal.visitor")
public class AiStatusController {

    private final AiCompletionPort completion;
    private final SecurityContextCurrentUser currentUser;

    public AiStatusController(AiCompletionPort completion, SecurityContextCurrentUser currentUser) {
        this.completion = completion;
        this.currentUser = currentUser;
    }

    /**
     * @param available      管理员已配置并启用了可用的 AI 服务(服务器允许出网/区域)
     * @param aiAllowedForMe 当前账号持有 ai:use
     * @param supportsVision 当前 AI 服务能识别图片/扫描件
     */
    public record AiStatus(boolean available, boolean aiAllowedForMe, boolean supportsVision) {
    }

    @GetMapping("/status")
    public AiStatus status() {
        AuthUser user = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        AiCompletionPort.AiAvailability availability = completion.availability();
        boolean allowed = user.getPermissions() != null && user.getPermissions().contains(AiPermissions.AI_USE);
        return new AiStatus(availability.available(), allowed,
                availability.available() && availability.supportsVision());
    }
}
