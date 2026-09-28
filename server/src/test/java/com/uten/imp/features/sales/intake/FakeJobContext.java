package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiCompletionRequest;
import com.uten.imp.application.port.AiCompletionPort.AiCompletionResult;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;
import com.uten.imp.application.port.AiJobHandler;

import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Function;

/** 识别任务上下文的测试替身: 记录进度与 AI 请求, AI 回复由测试脚本给出。 */
final class FakeJobContext implements AiJobHandler.AiJobContext {

    final UUID jobId = UUID.randomUUID();
    final Map<String, String> params = new LinkedHashMap<>();
    final List<String> stages = new ArrayList<>();
    final List<AiCompletionRequest> aiRequests = new ArrayList<>();
    AiJobHandler.AiJobInput input;
    boolean aiAllowed;
    boolean cancelled;
    int remainingCalls = 12;
    Function<AiCompletionRequest, String> ai = req -> {
        throw new AiCallException(AiErrorCategory.UNAVAILABLE, "AI 服务没有配置");
    };

    static FakeJobContext of(String fileName, String kind, byte[] bytes, String docType) {
        FakeJobContext ctx = new FakeJobContext();
        ctx.input = new AiJobHandler.AiJobInput(fileName, "application/octet-stream", kind, bytes.length, bytes, sha256(bytes));
        ctx.params.put("docType", docType);
        return ctx;
    }

    static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    @Override
    public UUID jobId() {
        return jobId;
    }

    @Override
    public String kind() {
        return SalesDocumentIntakeJobHandler.KIND;
    }

    @Override
    public Map<String, String> params() {
        return params;
    }

    @Override
    public AiJobHandler.AiJobInput input() {
        return input;
    }

    @Override
    public UUID submittedByUser() {
        return UUID.fromString("00000000-0000-0000-0000-000000000001");
    }

    @Override
    public UUID submittedByEmployee() {
        return null;
    }

    @Override
    public void progress(String stage, int percent) {
        stages.add(stage + ":" + percent);
    }

    @Override
    public boolean cancelled() {
        return cancelled;
    }

    @Override
    public int remainingAiCalls() {
        return remainingCalls;
    }

    @Override
    public AiCompletionResult completeJson(AiCompletionRequest req) {
        if (!aiAllowed || remainingCalls <= 0) {
            throw new AiCallException(AiErrorCategory.BLOCKED, "不能调用 AI");
        }
        remainingCalls--;
        aiRequests.add(req);
        String json = ai.apply(req);
        return new AiCompletionResult(json, "fake", "fake-model", 10, 10, 5);
    }

    @Override
    public boolean aiAllowed() {
        return aiAllowed;
    }

    /** 提示词里所有文字片段拼起来(断言没有泄露敏感信息用)。 */
    static String allText(AiCompletionRequest req) {
        StringBuilder sb = new StringBuilder(req.systemPrompt()).append('\n');
        for (AiCompletionPort.AiContentPart part : req.userParts()) {
            if (part instanceof AiCompletionPort.AiText t) {
                sb.append(t.text()).append('\n');
            }
        }
        return sb.toString();
    }
}
