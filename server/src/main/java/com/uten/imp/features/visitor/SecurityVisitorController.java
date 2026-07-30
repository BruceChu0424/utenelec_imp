package com.uten.imp.features.visitor;

import com.uten.imp.features.visitor.dto.VisitorScanDto.VisitorVerifyRequest;
import com.uten.imp.features.visitor.dto.VisitorScanDto.VisitorVerifyResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 保安扫码核验接口（security/admin，staff 主体）。
 * POST /api/security/verify          验证二维码（返回绿/红 + 访客信息）
 * POST /api/security/check-in/{appId} 签到（approved → checkedIn）
 */
@RestController
@RequestMapping("/api/security")
@RequiredArgsConstructor
public class SecurityVisitorController {

    private final VisitorGateService gateService;

    @PostMapping("/verify")
    @PreAuthorize("hasAuthority('visitor:check-in')")
    public VisitorVerifyResponse verify(@Valid @RequestBody VisitorVerifyRequest req) {
        return gateService.verify(req.qrToken(), req.passcode());
    }

    @PostMapping("/check-in/{appId}")
    @PreAuthorize("hasAuthority('visitor:check-in')")
    public VisitorVerifyResponse checkIn(@PathVariable UUID appId) {
        return gateService.checkIn(appId);
    }

    /** H4：拉黑访客（status=blocked，JwtAuthFilter 即时拒绝其后续请求）。 */
    @PostMapping("/blacklist/{visitorId}")
    @PreAuthorize("hasAuthority('visitor:blacklist')")
    public void blacklist(@PathVariable UUID visitorId) {
        gateService.blacklist(visitorId);
    }
}
