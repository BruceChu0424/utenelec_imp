package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.job.AiJobService;
import com.uten.imp.features.ai.job.AiJobView;
import com.uten.imp.security.AiChatAccessPolicy;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/ai/chat")
@PreAuthorize("isAuthenticated() and !principal.visitor")
public class AiChatController {
    private final AiJobService jobs;
    private final AiChatAccessPolicy access;
    private final AiChatEvidence evidence;
    private final AiCompletionPort ai;
    private final AiChatPageGuideCatalog pages;
    private final ObjectMapper json;
    private final AiChatToolRegistry tools;
    public AiChatController(AiJobService jobs, AiChatAccessPolicy access, AiChatEvidence evidence,
                            AiCompletionPort ai, AiChatPageGuideCatalog pages, ObjectMapper json, AiChatToolRegistry tools) {
        this.jobs = jobs; this.access = access; this.evidence = evidence; this.ai = ai; this.pages = pages; this.json = json; this.tools = tools;
    }
    @GetMapping("/capabilities")
    public Map<String, Object> capabilities() {
        try { access.requireChat(); }
        catch (ApiException denied) { return Map.of("canChat", false, "available", false,
                "canUploadSalesOrder", false, "canManagePermissions", false, "scopeSummary", "当前账号不能使用 AI 对话", "suggestions", List.of()); }
        var actor = access.requireChat();
        var domains = access.domains();
        boolean available = ai.availability().available();
        return Map.of("canChat", true, "available", available,
                "canUploadSalesOrder", domains.contains("SALES") && (actor.isSuperAdmin() || actor.getPermissions().containsAll(java.util.Set.of("sales_order:view", "sales_order:create"))),
                "canManagePermissions", tools.available("prepare_permission_grant").isPresent(),
                "scopeSummary", actor.isSuperAdmin() ? "超级管理员；操作仍需明确确认和审计" : "仅限本人部门、现行功能权限和数据范围",
                "suggestions", List.of("这个页面怎么填写？请举例", "我能让你帮忙做什么？", "我的工作台有哪些待办？"));
    }
    @PostMapping("/messages")
    public ResponseEntity<AiJobView> message(@Valid @RequestBody AiChatRequest request) {
        var actor = access.requireChat();
        AiChatJobHandler.validateRequest(request);
        if (request.previousJobId() != null) evidence.previous(request.previousJobId());
        if (request.attachmentJobId() != null) evidence.requireOrderAttachment(request.attachmentJobId());
        if (request.pageContext() != null) pages.resolve(request.pageContext().route(), request.pageContext().fieldKey());
        Map<String, Object> input = new LinkedHashMap<>();
        input.put("request", request); input.put("access", evidence.stamp());
        try {
            return ResponseEntity.status(HttpStatus.ACCEPTED).body(jobs.submitStructured(AiChatJobHandler.KIND,
                    Map.of(), json.writeValueAsBytes(input), actor));
        } catch (JsonProcessingException impossible) { throw new ApiException(ErrorCode.VALIDATION_FAILED); }
    }
}
