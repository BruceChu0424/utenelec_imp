package com.uten.imp.features.webinquiry;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.webinquiry.dto.IngestRequest;
import com.uten.imp.features.webinquiry.dto.StatusUpdateRequest;
import com.uten.imp.features.webinquiry.dto.WebsiteInquiryDetail;
import com.uten.imp.features.webinquiry.dto.WebsiteInquiryListItem;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * 官网询盘 API（综合营销-官网询盘）。
 *
 * - POST /api/website-inquiries/ingest        → 官网推送（共享密钥，permitAll，幂等）
 * - GET  /api/website-inquiries?status=&keyword=&page=&size= → 分页列表（webinquiry:view）
 * - GET  /api/website-inquiries/new-count     → 未处理数（工作台角标，webinquiry:view）
 * - GET  /api/website-inquiries/{id}          → 详情（webinquiry:view）
 * - POST /api/website-inquiries/{id}/status   → 认领或关闭（按请求动态校验 claim/close）
 * - POST /api/website-inquiries/{id}/convert  → 一键转客户（webinquiry:convert_client）
 *
 * 权限点种子化（不回填部门，权限管理页授综合营销部；超管恒有）。
 */
@RestController
@RequestMapping("/api/website-inquiries")
@RequiredArgsConstructor
public class WebsiteInquiryController {

    private final WebsiteInquiryService service;
    private final WebsiteInquiryIngestGuard ingestGuard;

    /** 官网服务端推送入口。密钥无效一律 401（不区分未配置/不匹配，防探测）。 */
    @PostMapping("/ingest")
    public ResponseEntity<Map<String, Object>> ingest(
            @RequestHeader(name = "X-Uten-Ingest-Token", required = false) String token,
            @Valid @RequestBody IngestRequest request) {
        if (!ingestGuard.tokenValid(token)) {
            throw new ApiException(ErrorCode.UNAUTHORIZED, "invalid ingest token");
        }
        if (!ingestGuard.allow("ingest")) {
            throw new ApiException(ErrorCode.RATE_LIMITED, "ingest rate limited");
        }
        boolean created = service.ingest(request);
        return ResponseEntity.status(created ? HttpStatus.CREATED : HttpStatus.OK)
                .body(Map.of("created", created));
    }

    @GetMapping
    @PreAuthorize("hasAuthority('webinquiry:view')")
    public PageResponse<WebsiteInquiryListItem> list(
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(status, keyword, page, size);
    }

    @GetMapping("/new-count")
    @PreAuthorize("hasAuthority('webinquiry:view')")
    public Map<String, Long> newCount() {
        return Map.of("count", service.countNew());
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('webinquiry:view')")
    public WebsiteInquiryDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping("/{id}/status")
    @PreAuthorize("hasAuthority(#request.requiredPermission()) and (#request.assignToMe() != true or hasAuthority('webinquiry:claim'))")
    public WebsiteInquiryDetail updateStatus(@PathVariable UUID id,
                                             @Valid @RequestBody StatusUpdateRequest request) {
        return service.updateStatus(id, request);
    }

    @PostMapping("/{id}/convert")
    @PreAuthorize("hasAuthority('webinquiry:convert_client')")
    public WebsiteInquiryDetail convert(@PathVariable UUID id) {
        return service.convert(id);
    }
}
