package com.uten.imp.features.ai.gateway;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;
import com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort;
import com.uten.imp.application.port.AiCompletionPort.AiText;
import com.uten.imp.features.ai.client.AiJsonExtractor;
import com.uten.imp.features.ai.client.AiProtocolClient;
import com.uten.imp.features.ai.client.AiReasoningParams;
import com.uten.imp.features.ai.provider.AiProviderDtos;
import com.uten.imp.features.ai.provider.AiProviderDtos.TestStep;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * 「测试连接」(ADR-133): 网络连通 / 密钥验证 / 模型可用 / JSON 输出 / (能调整时)思考程度, 每步带耗时与大白话建议。
 *
 * <ol>
 *   <li>先取模型列表(不耗 token): 连得上 = 网络通; 200 = 密钥有效; 列表里没有配置的模型只提示不判失败;
 *       服务商没有列表接口(404)就跳过, 直接用对话测试。</li>
 *   <li>再发一次很小的对话: {@code Reply in JSON: {"ok": true}}, 最多 512 个输出 token、关闭深度思考。
 *       预算要容得下思考型模型的思考块(智谱 Anthropic 端点收到 thinking disabled 也照样思考),
 *       64 会被偶尔吃光导致正文为空、JSON 步误报。
 *       成功 = 模型可用; 回复能解析出 ok=true 的 JSON = JSON 输出正常。</li>
 *   <li>这个配置能调整思考程度时(ADR-152), 再按 AI 对话的默认档「标准」带上思考参数发一次同样的小对话:
 *       服务商拒绝(400/404) = 这个模型不认思考参数, AI 对话会全部失败, 判失败并告诉管理员怎么改;
 *       超时、限流等没测完只提示。</li>
 * </ol>
 */
@Component
public class AiConnectionTester {

    static final String STEP_NETWORK = "NETWORK";
    static final String STEP_AUTH = "AUTH";
    static final String STEP_MODEL = "MODEL";
    static final String STEP_JSON = "JSON";
    static final String STEP_THINKING = "THINKING";
    /** AI 对话默认的思考程度(「标准」); 连接测试按它实测一次。 */
    static final AiReasoningEffort CHAT_DEFAULT_EFFORT = AiReasoningEffort.MEDIUM;
    private static final String PING_SYSTEM = "You are a connectivity check. Reply in JSON. " + AiGateway.JSON_INSTRUCTION;
    private static final String PING_USER = "Reply in JSON: {\"ok\": true}";

    private static final ObjectMapper JSON = new ObjectMapper();

    private final AiGateway gateway;
    private final Clock clock;

    public AiConnectionTester(AiGateway gateway, Clock clock) {
        this.gateway = gateway;
        this.clock = clock;
    }

    public AiProviderDtos.TestResult test(AiProviderRuntime runtime) {
        List<TestStep> steps = new ArrayList<>();
        OffsetDateTime testedAt = OffsetDateTime.now(clock);

        // 第 1 步: 模型列表(同时验证网络与密钥)。
        long started = System.nanoTime();
        boolean authConfirmed = false;
        try {
            List<String> models = gateway.listModels(runtime);
            long latency = elapsed(started);
            steps.add(new TestStep(STEP_NETWORK, "OK", "服务器能连上 AI 服务", latency));
            steps.add(new TestStep(STEP_AUTH, "OK", runtime.hasApiKey() ? "密钥有效" : "这个服务不需要密钥", latency));
            authConfirmed = true;
            if (!runtime.model().isBlank() && !models.isEmpty() && !models.contains(runtime.model())) {
                steps.add(new TestStep(STEP_MODEL, "WARN",
                        "模型列表里没有找到「" + runtime.model() + "」, 下面继续试着调用", null));
            }
        } catch (AiCallException e) {
            long latency = elapsed(started);
            switch (e.category()) {
                case NOT_FOUND, BAD_REQUEST -> steps.add(new TestStep(STEP_NETWORK, "OK",
                        "服务器能连上 AI 服务(这个服务商没有模型列表接口, 直接用对话测试)", latency));
                case AUTH -> {
                    steps.add(new TestStep(STEP_NETWORK, "OK", "服务器能连上 AI 服务", latency));
                    steps.add(new TestStep(STEP_AUTH, "FAILED", advice(e), latency));
                    return finish(steps, testedAt);
                }
                case QUOTA, RATE_LIMIT -> {
                    steps.add(new TestStep(STEP_NETWORK, "OK", "服务器能连上 AI 服务", latency));
                    steps.add(new TestStep(STEP_AUTH, "FAILED", advice(e), latency));
                    return finish(steps, testedAt);
                }
                default -> {
                    steps.add(new TestStep(STEP_NETWORK, "FAILED", advice(e), latency));
                    return finish(steps, testedAt);
                }
            }
        }
        if (runtime.model().isBlank()) {
            steps.add(new TestStep(STEP_MODEL, "SKIPPED", "还没有填写模型名称", null));
            return finish(steps, testedAt);
        }

        // 第 2 步: 很小的 JSON 对话。
        started = System.nanoTime();
        AiProtocolClient.ChatRequest ping = new AiProtocolClient.ChatRequest(PING_SYSTEM,
                List.of(new AiText(PING_USER, false)), null, null, 512);
        AiProtocolClient.ChatResponse response;
        try {
            response = gateway.probeChat(runtime, ping, "CONNECTION_TEST");
        } catch (AiCallException e) {
            long latency = elapsed(started);
            // 对话的结论取代「模型列表里没有」的提示, 每一步只留一个结果。
            steps.removeIf(step -> step.key().equals(STEP_MODEL) && step.status().equals("WARN"));
            if (e.category() == AiErrorCategory.AUTH && !authConfirmed) {
                steps.add(new TestStep(STEP_AUTH, "FAILED", advice(e), latency));
            } else if (e.category() == AiErrorCategory.NETWORK || e.category() == AiErrorCategory.TIMEOUT
                    || e.category() == AiErrorCategory.BLOCKED) {
                if (steps.stream().noneMatch(step -> step.key().equals(STEP_NETWORK))) {
                    steps.add(new TestStep(STEP_NETWORK, "FAILED", advice(e), latency));
                } else {
                    steps.add(new TestStep(STEP_MODEL, "FAILED", advice(e), latency));
                }
            } else {
                steps.add(new TestStep(STEP_MODEL, "FAILED", advice(e), latency));
            }
            return finish(steps, testedAt);
        }
        long latency = elapsed(started);
        if (!authConfirmed) {
            steps.add(new TestStep(STEP_AUTH, "OK", runtime.hasApiKey() ? "密钥有效" : "这个服务不需要密钥", latency));
        }
        steps.removeIf(step -> step.key().equals(STEP_MODEL) && step.status().equals("WARN"));
        steps.add(new TestStep(STEP_MODEL, "OK", "模型「" + runtime.model() + "」可以正常调用", latency));
        steps.add(jsonStep(response, latency));
        if (AiReasoningParams.supported(runtime)) {
            steps.add(thinkingStep(runtime));
        }
        return finish(steps, testedAt);
    }

    /**
     * 第 3 步: 带上 AI 对话默认档的思考参数再调一次。请求体与对话完全同一套写法(AiReasoningParams),
     * 所以这里通过 = 对话不会因为思考参数被服务商拒绝。
     */
    private TestStep thinkingStep(AiProviderRuntime runtime) {
        long started = System.nanoTime();
        AiProtocolClient.ChatRequest ping = new AiProtocolClient.ChatRequest(PING_SYSTEM,
                List.of(new AiText(PING_USER, false)), null, null,
                AiReasoningParams.maxOutputTokens(runtime, 512, CHAT_DEFAULT_EFFORT), CHAT_DEFAULT_EFFORT);
        try {
            gateway.probeChat(runtime, ping, "CONNECTION_TEST");
            return new TestStep(STEP_THINKING, "OK", "能按思考程度调用, AI 对话里的「思考程度」设置可以使用", elapsed(started));
        } catch (AiCallException e) {
            long latency = elapsed(started);
            if (e.category() == AiErrorCategory.BAD_REQUEST || e.category() == AiErrorCategory.NOT_FOUND) {
                return new TestStep(STEP_THINKING, "FAILED", "这个模型不接受思考程度参数(" + e.getMessage()
                        + "), AI 对话会因此全部失败。请在高级设置里把「思考参数写法」改为「不发送」, 或换一个支持的模型",
                        latency);
            }
            return new TestStep(STEP_THINKING, "WARN", "思考程度没有测完: " + advice(e), latency);
        }
    }

    /** 获取模型列表(页面「获取模型」按钮)。拿不到时给出原因, 页面仍允许手填。 */
    public AiProviderDtos.ModelsResult models(AiProviderRuntime runtime) {
        try {
            List<String> models = gateway.listModels(runtime).stream().sorted().toList();
            return new AiProviderDtos.ModelsResult(models,
                    models.isEmpty() ? "服务商没有返回模型, 请手动填写模型名称" : null);
        } catch (AiCallException e) {
            if (e.category() == AiErrorCategory.NOT_FOUND) {
                return new AiProviderDtos.ModelsResult(List.of(), "这个服务商没有模型列表接口, 请手动填写模型名称");
            }
            return new AiProviderDtos.ModelsResult(List.of(), advice(e));
        }
    }

    private TestStep jsonStep(AiProtocolClient.ChatResponse response, long latency) {
        try {
            JsonNode node = JSON.readTree(AiJsonExtractor.extractObject(response.content()));
            if (node.path("ok").asBoolean(false)) {
                return new TestStep(STEP_JSON, "OK", "能按要求输出 JSON, 可以用来识别客户文件", latency);
            }
            return new TestStep(STEP_JSON, "WARN",
                    "返回了 JSON 但内容和要求不一致, 识别客户文件可能不稳定", latency);
        } catch (AiCallException | java.io.IOException e) {
            return new TestStep(STEP_JSON, "FAILED",
                    "服务能用, 但没有按要求返回 JSON; 可以在高级设置里换一种 JSON 输出方式或换一个模型", latency);
        }
    }

    private static AiProviderDtos.TestResult finish(List<TestStep> steps, OffsetDateTime testedAt) {
        boolean failed = steps.stream().anyMatch(step -> step.status().equals("FAILED"));
        String summary;
        if (failed) {
            TestStep first = steps.stream().filter(step -> step.status().equals("FAILED")).findFirst().orElseThrow();
            summary = first.message();
        } else if (steps.stream().anyMatch(step -> step.status().equals("WARN"))) {
            summary = "连接成功, 但有需要注意的地方";
        } else if (steps.stream().anyMatch(step -> step.status().equals("SKIPPED"))) {
            summary = "连接成功, 还没有测试模型";
        } else {
            summary = "连接成功";
        }
        boolean ok = !failed && steps.stream().noneMatch(step -> step.status().equals("SKIPPED"));
        return new AiProviderDtos.TestResult(ok, summary, List.copyOf(steps), testedAt);
    }

    /** 大白话建议: 在分类消息后补充下一步怎么做。 */
    static String advice(AiCallException e) {
        String base = e.getMessage() == null ? "AI 调用失败" : e.getMessage();
        return switch (e.category()) {
            case AUTH -> base + "。请到服务商后台重新复制密钥; 通义、Kimi 的密钥还要和账号所在区域一致";
            case NOT_FOUND -> base + "。请核对接口地址(例如是否少了 /v1)和模型名称";
            case QUOTA -> base + "。请到服务商后台充值";
            default -> base;
        };
    }

    private static long elapsed(long started) {
        return TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
    }
}
