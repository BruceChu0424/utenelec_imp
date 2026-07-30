package com.uten.imp.features.suggestion;

import com.uten.imp.features.suggestion.dto.SuggestionDto;
import com.uten.imp.features.suggestion.dto.SuggestionReplyRequest;
import com.uten.imp.features.suggestion.dto.SuggestionSubmitRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 建议箱接口（当前登录员工；认证由 SecurityConfig 全局 authenticated 保证）。
 *
 * <pre>
 *   GET  /api/suggestions?scope=&category=   广场（默认）/ 我的建议
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

    @GetMapping
    @PreAuthorize("hasAuthority('suggestion:submit')")
    public Map<String, Object> list(@RequestParam(required = false) String scope,
                                    @RequestParam(required = false) String category) {
        return Map.of("items", service.list(scope, category));
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('suggestion:submit')")
    public SuggestionDto detail(@PathVariable UUID id) {
        return service.getById(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('suggestion:submit')")
    public SuggestionDto submit(@RequestBody SuggestionSubmitRequest req) {
        return service.submit(req);
    }

    @PostMapping("/{id}/like")
    @PreAuthorize("hasAuthority('suggestion:submit')")
    public SuggestionDto toggleLike(@PathVariable UUID id) {
        return service.toggleLike(id);
    }

    @PostMapping("/{id}/replies")
    @PreAuthorize("hasAuthority('suggestion:reply')")
    public SuggestionDto reply(@PathVariable UUID id, @RequestBody SuggestionReplyRequest req) {
        return service.reply(id, req);
    }
}
