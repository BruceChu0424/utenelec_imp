package com.uten.imp.features.ai.provider;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.gateway.AiCallLogService;
import com.uten.imp.features.ai.gateway.AiConnectionTester;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.StepUpExempt;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * AI 服务设置(ADR-133), 只有持有 authorization:manage 的超级管理员能用。
 *
 * <p>所有改配置的写入都要求再认证; 两个「用本次填写的密钥测试/取模型」的端点豁免再认证:
 * 它们必须带新填的密钥(不需要密钥的本机部署除外)、不读取已保存的密钥、不修改任何配置。
 * 用已保存的密钥测试/取模型走 {@code /providers/{id}/test|models}: 要求再认证, 只使用保存的地址。
 */
@RestController
@RequestMapping("/api/admin/ai")
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class AiProviderController {

    private final AiProviderService service;
    private final AiConnectionTester tester;
    private final AiCallLogService callLogs;
    private final AiProperties properties;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.audit.AuditDetailViewRecorder detailViews;

    public AiProviderController(AiProviderService service, AiConnectionTester tester, AiCallLogService callLogs,
                                AiProperties properties, SecurityContextCurrentUser currentUser,
                                com.uten.imp.audit.AuditDetailViewRecorder detailViews) {
        this.service = service;
        this.tester = tester;
        this.callLogs = callLogs;
        this.properties = properties;
        this.currentUser = currentUser;
        this.detailViews=detailViews;
    }

    @GetMapping("/providers")
    public List<?> list(@RequestParam(defaultValue="false") boolean includeDeleted,@RequestParam(defaultValue="false") boolean onlyDeleted) {
        return includeDeleted||onlyDeleted?service.listHistory(onlyDeleted):service.list();
    }
    public List<AiProviderDtos.ProviderView> list(){return service.list();}
    @GetMapping("/providers/history")
    public List<AiProviderDtos.ProviderHistoryView> listHistory(@RequestParam(defaultValue="false") boolean onlyDeleted){return service.listHistory(onlyDeleted);}
    @GetMapping("/providers/{id}/history")
    public AiProviderDtos.ProviderHistoryView history(@PathVariable UUID id,@RequestParam(required=false) Long beforeId,
            @RequestParam(defaultValue="50") int size){
        var result=service.history(id,beforeId,size);
        detailViews.record("view_ai_provider_history_detail","ai_providers",id,null,null,"AI 服务配置历史");return result;
    }

    @GetMapping("/presets")
    public AiProviderDtos.PresetsView presets() {
        return service.presets();
    }

    @GetMapping("/usage")
    public AiProviderDtos.UsageView usage(@RequestParam(defaultValue = "30") int days) {
        int window = Math.max(1, Math.min(180, days));
        List<AiProviderDtos.UsageRow> rows = callLogs.usage(window);
        long calls = 0;
        long ok = 0;
        long input = 0;
        long output = 0;
        long latencyWeighted = 0;
        for (AiProviderDtos.UsageRow row : rows) {
            calls += row.calls();
            ok += row.okCalls();
            input += row.inputTokens();
            output += row.outputTokens();
            latencyWeighted += row.averageLatencyMs() * row.calls();
        }
        AiProviderDtos.UsageRow total = new AiProviderDtos.UsageRow(null, null, calls, ok, input, output,
                calls == 0 ? 0 : Math.round((double) latencyWeighted / calls));
        return new AiProviderDtos.UsageView(window, rows, total, callLogs.todayTokens(),
                properties.getDailyTokenBudget());
    }

    @PostMapping("/providers")
    @RequiresStepUp
    public AiProviderDtos.ProviderView create(@RequestBody AiProviderDtos.ProviderRequest request) {
        return service.create(request, actor());
    }

    @PutMapping("/providers/{id}")
    @RequiresStepUp
    public AiProviderDtos.ProviderView update(@PathVariable UUID id,
                                              @RequestBody AiProviderDtos.ProviderRequest request) {
        return service.update(id, request, actor());
    }

    @DeleteMapping("/providers/{id}")
    @RequiresStepUp
    public void delete(@PathVariable UUID id, @RequestParam(required = false) Long version) {
        service.delete(id, version, actor());
    }

    @PostMapping("/providers/{id}/default")
    @RequiresStepUp
    public AiProviderDtos.ProviderView setDefault(@PathVariable UUID id,
                                                  @RequestBody(required = false) AiProviderDtos.VersionRequest body) {
        return service.setDefault(id, body == null ? null : body.version(), actor());
    }

    @PostMapping("/providers/{id}/enabled")
    @RequiresStepUp
    public AiProviderDtos.ProviderView setEnabled(@PathVariable UUID id,
                                                  @RequestBody AiProviderDtos.EnabledRequest body) {
        if (body == null || body.enabled() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请说明启用还是停用");
        }
        return service.setEnabled(id, body.enabled(), body.version(), actor());
    }

    @PostMapping("/providers/test")
    @StepUpExempt("仅使用本次请求中新填写的密钥做连接探测, 不读取已保存密钥, 不修改配置")
    public AiProviderDtos.TestResult testTyped(@RequestBody AiProviderDtos.ProbeRequest request) {
        return tester.test(service.probeRuntime(request));
    }

    @PostMapping("/providers/models")
    @StepUpExempt("仅使用本次请求中新填写的密钥获取模型列表, 不读取已保存密钥, 不修改配置")
    public AiProviderDtos.ModelsResult modelsTyped(@RequestBody AiProviderDtos.ProbeRequest request) {
        return tester.models(service.probeRuntime(request));
    }

    @PostMapping("/providers/{id}/test")
    @RequiresStepUp
    public AiProviderDtos.TestResult testStored(@PathVariable UUID id,
                                                @RequestBody(required = false) AiProviderDtos.StoredProbeRequest body) {
        long version = service.currentVersion(id);
        AiProviderRuntime runtime = service.storedRuntime(id, body);
        AiProviderDtos.TestResult result = tester.test(runtime);
        service.recordStoredTest(id, version, result.ok(), result.summary(), result.testedAt());
        return result;
    }

    @PostMapping("/providers/{id}/models")
    @RequiresStepUp
    public AiProviderDtos.ModelsResult modelsStored(@PathVariable UUID id,
                                                    @RequestBody(required = false) AiProviderDtos.StoredProbeRequest body) {
        return tester.models(service.storedRuntime(id, body));
    }

    private AuthUser actor() {
        return currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
    }
}
