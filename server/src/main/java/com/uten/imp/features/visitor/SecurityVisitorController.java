package com.uten.imp.features.visitor;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.visitor.dto.VisitorScanDto.BlacklistListItem;
import com.uten.imp.features.visitor.dto.VisitorScanDto.BlacklistRequest;
import com.uten.imp.features.visitor.dto.VisitorScanDto.VisitorVerifyRequest;
import com.uten.imp.features.visitor.dto.VisitorScanDto.VisitorVerifyResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 保安扫码核验接口（security/admin/hr，staff 主体）。
 * POST   /api/security/verify           验证二维码（返回绿/红 + 访客信息，含 visitorId）
 * POST   /api/security/check-in/{appId} 签到（approved → checkedIn）
 * POST   /api/security/blacklist/{visitorId}   拉黑（body.reason 必填，2026-09-18 UI 首发）
 * DELETE /api/security/blacklist/{visitorId}   解除拉黑（误操作恢复）
 * GET    /api/security/blacklist              黑名单分页列表（管理页）
 */
@RestController
@RequestMapping("/api/security")
@RequiredArgsConstructor
public class SecurityVisitorController {

    private final VisitorGateService gateService;

    @PostMapping("/verify")
    @PreAuthorize("hasAuthority('visitor:verify')")
    public VisitorVerifyResponse verify(@Valid @RequestBody VisitorVerifyRequest req) {
        return gateService.verify(req.qrToken(), req.passcode());
    }

    @PostMapping("/check-in/{appId}")
    @PreAuthorize("hasAuthority('visitor:check_in')")
    public VisitorVerifyResponse checkIn(@PathVariable UUID appId) {
        return gateService.checkIn(appId);
    }

    /** H4/V603：拉黑访客（status=blocked，JwtAuthFilter 即时拒绝其后续请求）。 */
    @PostMapping("/blacklist/{visitorId}")
    @PreAuthorize("hasAuthority('visitor:blacklist')")
    public void blacklist(@PathVariable UUID visitorId,
                          @Valid @RequestBody BlacklistRequest req) {
        gateService.blacklist(visitorId, req.reason());
    }

    /** 解除拉黑：账号回 active，可重新登录/申请；历史申请状态不变。 */
    @DeleteMapping("/blacklist/{visitorId}")
    @PreAuthorize("hasAuthority('visitor:blacklist')")
    public void unblacklist(@PathVariable UUID visitorId) {
        gateService.unblacklist(visitorId);
    }

    /** 黑名单管理页列表。 */
    @GetMapping("/blacklist")
    @PreAuthorize("hasAuthority('visitor:blacklist')")
    public PageResponse<BlacklistListItem> blacklist(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return gateService.blacklistPage(page, size);
    }
}
