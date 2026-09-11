package com.uten.imp.features.suggestion;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.suggestion.dto.SuggestionDto;
import com.uten.imp.features.suggestion.dto.SuggestionReplyRequest;
import com.uten.imp.features.suggestion.dto.SuggestionSubmitRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 建议箱接口（当前登录员工；认证由 SecurityConfig 全局 authenticated 保证）。
 *
 * <pre>
 *   GET  /api/suggestions?scope=&category=&status=  广场（默认）/ 我的建议（status=列表表头筛选）
 *   GET  /api/suggestions/{id}               详情（含回复）
 *   POST /api/suggestions                    提交建议（suggestion:submit）
 *   POST /api/suggestions/{id}/like          点赞切换
 *   POST /api/suggestions/{id}/replies       官方回复（suggestion:reply），可顺带推进状态
 * </pre>
 */
@RestController
@RequestMapping("/api/suggestions")
@RequiredArgsConstructor
public class SuggestionController {

    private final SuggestionService service;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping
    @PreAuthorize("hasAuthority('suggestion:submit')")
    public PageResponse<SuggestionDto> list(
            @RequestParam(required = false) String scope,
            @RequestParam(required = false) String category,
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(scope, category, status, page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('suggestion:submit')")
    public SuggestionDto detail(@PathVariable UUID id) {
        SuggestionDto result = service.getById(id);
        detailViewAudit.record(
                "view_suggestion_detail", "suggestions", id, null,
                null, "建议");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('suggestion:submit')")
    public SuggestionDto submit(@Valid @RequestBody SuggestionSubmitRequest req) {
        return service.submit(req);
    }

    @PostMapping("/{id}/like")
    @PreAuthorize("hasAuthority('suggestion:submit')")
    public SuggestionDto toggleLike(@PathVariable UUID id) {
        return service.toggleLike(id);
    }

    @PostMapping("/{id}/replies")
    @PreAuthorize("hasAuthority('suggestion:reply')")
    public SuggestionDto reply(@PathVariable UUID id, @Valid @RequestBody SuggestionReplyRequest req) {
        return service.reply(id, req);
    }
}
