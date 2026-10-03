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
import org.springframework.web.bind.annotation.RequestParam;
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
    private final AiDocumentWorkflows workflows;
    public AiChatController(AiJobService jobs, AiChatAccessPolicy access, AiChatEvidence evidence,
                            AiCompletionPort ai, AiChatPageGuideCatalog pages, ObjectMapper json, AiChatToolRegistry tools,
                            AiDocumentWorkflows workflows) {
        this.jobs = jobs; this.access = access; this.evidence = evidence; this.ai = ai; this.pages = pages; this.json = json; this.tools = tools; this.workflows = workflows;
    }
    @GetMapping("/capabilities")
    public Map<String, Object> capabilities() {
        try { access.requireChat(); }
        catch (ApiException denied) { return Map.of("canChat", false, "available", false,
                "canUploadSalesOrder", false, "canUploadDocument", false, "workflows", List.of(), "canManagePermissions", false, "scopeSummary", "当前账号不能使用 AI 对话", "suggestions", List.of()); }
        var actor = access.requireChat();
        boolean available = ai.availability().available();
        var allowed = tools.available();
        var destinations = workflows.available().stream().map(value -> value.get("workflow")).toList();
        var catalog = allowed.stream().sorted(java.util.Comparator.comparing(com.uten.imp.application.port.AiChatToolPort::name))
                .map(tool -> Map.of("name", tool.name(), "title", tool.title(), "description", tool.description(), "domain", tool.domain())).toList();
        var result = new LinkedHashMap<String, Object>();
        result.put("canChat", true); result.put("available", available);
        result.put("canUploadSalesOrder", destinations.contains("SALES_ORDER"));
        result.put("canUploadDocument", !destinations.isEmpty()); result.put("workflows", destinations);
        result.put("canManagePermissions", tools.available("prepare_permission_grant").isPresent());
        result.put("scopeSummary", actor.isSuperAdmin() ? "超级管理员；业务保存、提交和审核仍由本人操作" : "仅限本人部门、现行功能权限和数据范围");
        result.put("suggestions", List.of("我能让你帮忙做什么？", "我的工作台有哪些待办？"));
        result.put("tools", catalog);
        result.put("catalogVersion", catalogVersion(catalog, destinations));
        return result;
    }
    @GetMapping("/page-suggestions")
    public Map<String, Object> pageSuggestions(@RequestParam(defaultValue = "") String pageRoute) {
        access.requireChat();
        if (pageRoute.length() > 240) throw new ApiException(ErrorCode.VALIDATION_FAILED);
        try {
            var page = pages.resolve(pageRoute, null);
            return Map.of("pageRoute", pageRoute, "pageTitle", page.map(AiChatPageGuideCatalog.PageGuide::title).orElse(""),
                    "suggestions", page.map(pages::suggestions).orElse(List.of()));
        } catch (ApiException deniedPage) {
            if (deniedPage.getCode() != ErrorCode.FORBIDDEN) throw deniedPage;
            return Map.of("pageRoute", pageRoute, "pageTitle", "", "suggestions", List.of());
        }
    }
    private String catalogVersion(Object catalog, Object destinations) {
        try {
            byte[] bytes = json.writer().with(com.fasterxml.jackson.databind.SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS)
                    .writeValueAsBytes(Map.of("tools", catalog, "workflows", destinations, "contract", 1));
            return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (java.security.NoSuchAlgorithmException | JsonProcessingException impossible) { throw new IllegalStateException(impossible); }
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
