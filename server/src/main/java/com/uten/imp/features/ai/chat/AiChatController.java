package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.audit.AuditAutomaticWrite;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.job.AiJobService;
import com.uten.imp.features.ai.job.AiJobView;
import com.uten.imp.security.AiChatAccessPolicy;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

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
    private final AiChatSettingsService settings;
    private final AiChatJobHandler handler;
    /** Turns shown when a conversation is restored (the model sees at most the memory setting). */
    static final int RESTORED_TURNS = 20;
    public AiChatController(AiJobService jobs, AiChatAccessPolicy access, AiChatEvidence evidence,
                            AiCompletionPort ai, AiChatPageGuideCatalog pages, ObjectMapper json, AiChatToolRegistry tools,
                            AiDocumentWorkflows workflows, AiChatSettingsService settings, AiChatJobHandler handler) {
        this.jobs = jobs; this.access = access; this.evidence = evidence; this.ai = ai; this.pages = pages; this.json = json; this.tools = tools; this.workflows = workflows;
        this.settings = settings; this.handler = handler;
    }
    @GetMapping("/capabilities")
    public Map<String, Object> capabilities() {
        try { access.requireChat(); }
        catch (ApiException denied) { return Map.of("canChat", false, "available", false,
                "canUploadSalesOrder", false, "canUploadDocument", false, "workflows", List.of(), "canManagePermissions", false, "scopeSummary", "当前账号不能使用 AI 对话", "suggestions", List.of()); }
        var actor = access.requireChat();
        var availability = ai.availability();
        boolean available = availability.available();
        var allowed = tools.available();
        var destinations = workflows.available().stream().map(value -> value.get("workflow")).toList();
        var catalog = allowed.stream().sorted(java.util.Comparator.comparing(com.uten.imp.application.port.AiChatToolPort::name))
                .map(tool -> Map.of("name", tool.name(), "title", tool.title(), "description", tool.description(), "domain", tool.domain())).toList();
        var result = new LinkedHashMap<String, Object>();
        result.put("canChat", true); result.put("available", available);
        result.put("canUploadSalesOrder", destinations.contains("SALES_ORDER"));
        // Recognizing a file needs only chat access; what it may lead to is filtered per answer.
        result.put("canUploadDocument", true); result.put("workflows", destinations);
        result.put("canManagePermissions", tools.available("prepare_permission_grant").isPresent());
        // ADR-153: the assistant's scope is stated up front (platform use, business rules, permitted data).
        result.put("scopeSummary", (actor.isSuperAdmin()
                ? "超级管理员；我提出的操作要你在确认卡上确认后才执行，业务校验照旧"
                : "仅限本人部门、现行功能权限和数据范围；我提出的操作要你确认后才执行")
                + "。我只解答平台怎么用、业务规则和你有权限看的数据，不处理代码、服务器、命令或密码");
        result.put("suggestions", List.of("我能让你帮忙做什么？", "我的工作台有哪些待办？"));
        result.put("tools", catalog);
        result.put("catalogVersion", catalogVersion(catalog, destinations));
        // ADR-152: the account's chat settings and whether the current AI service can adjust thinking depth.
        result.put("settings", settings.current().toJson());
        result.put("reasoningEffortSupported", availability.supportsReasoningEffort());
        return result;
    }

    /**
     * ADR-152: change one or more chat settings (only whitelisted fields and values; 422 otherwise). Settings
     * are personal preferences, so the write is not a business audit event.
     */
    @AuditAutomaticWrite("AI 对话设置是个人偏好(ADR-152)")
    @PatchMapping("/settings")
    public Map<String, Object> updateSettings(@RequestBody JsonNode change) {
        access.requireChat();
        var saved = settings.update(change);
        return Map.of("settings", saved.toJson(), "reasoningEffortSupported", ai.availability().supportsReasoningEffort());
    }

    /**
     * ADR-152: the caller's own conversation to show after a page refresh (the client asks when the chat panel
     * is first opened): the given one, or the latest. Each turn is re-read like any history read with one
     * memoized check per request (identity, domain, tool, page and knowledge); a turn that no longer passes is
     * counted in {@code hiddenTurns} instead of shown, and a tool answer whose quoted data changed comes back
     * as its question with {@code dataChanged: true} and no reply.
     */
    @GetMapping("/conversations/current")
    public Map<String, Object> conversation(@RequestParam(required = false) UUID conversationId) {
        var actor = access.requireChat();
        UUID id = conversationId != null ? conversationId : jobs.latestConversation(AiChatJobHandler.KIND, actor).orElse(null);
        Map<String, Object> view = new LinkedHashMap<>();
        view.put("conversationId", id == null ? null : id.toString());
        List<Map<String, Object>> turns = List.of();
        int hidden = 0;
        if (id != null) {
            var stored = new ArrayList<>(jobs.conversationResults(AiChatJobHandler.KIND, actor, id, RESTORED_TURNS));
            java.util.Collections.reverse(stored);
            var restored = handler.restore(stored);
            turns = restored.turns();
            hidden = restored.hidden();
        }
        view.put("turns", turns);
        view.put("hiddenTurns", hidden);
        return view;
    }

    /**
     * ADR-152: clear the caller's own conversation records. They are archived (no longer restored or carried
     * into new questions); usage records kept for administrators are not affected.
     */
    @DeleteMapping("/conversations")
    public Map<String, Object> clearConversations() {
        var actor = access.requireChat();
        return Map.of("cleared", jobs.archiveConversations(AiChatJobHandler.KIND, actor, "AI_CHAT_CLEARED_BY_USER"));
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
        // The stored job input keeps only the sanitized snapshot; it is cleared when the job ends.
        AiChatRequest checked = AiChatJobHandler.validated(request);
        // A question without a conversation starts a new one; its id comes back in the result.
        if (checked.conversationId() == null) checked = checked.withConversation(UUID.randomUUID());
        AiChatSettings current = settings.current();
        // Page reading switched off: nothing from the page is stored or sent, whatever the client attached.
        if (!current.pageAware()) checked = checked.withoutPage();
        if (checked.pageContext() != null) {
            try {
                pages.resolve(checked.pageContext().route(), checked.pageContext().fieldKey());
            } catch (ApiException denied) {
                // A page outside the user's chat departments: the question is answered without it, nothing of it is stored.
                checked = AiChatJobHandler.withoutUnreadablePage(checked, denied);
            }
        }
        Map<String, Object> input = new LinkedHashMap<>();
        input.put("request", checked); input.put("access", evidence.stamp());
        // Settings are read here on the server, once per question; the client never supplies them.
        input.put("settings", current.toJson());
        try {
            return ResponseEntity.status(HttpStatus.ACCEPTED).body(jobs.submitStructured(AiChatJobHandler.KIND,
                    Map.of(), json.writeValueAsBytes(input), actor));
        } catch (JsonProcessingException impossible) { throw new ApiException(ErrorCode.VALIDATION_FAILED); }
    }
}
