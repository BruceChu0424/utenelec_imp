package com.uten.imp.application.port;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 公共 AI 平台的补全出口(ADR-133)。业务 feature 只经这个接口调用大模型, 不知道服务商、密钥与协议。
 *
 * <p>实现(features/ai 的网关)负责: 取默认且启用的服务商、解密密钥、出网/境外/图片能力开关、全局并发与
 * 每日 token 预算、不可信文本的隔离标记、失败重试一次与调用技术记录。调用方只描述「要什么 JSON」。
 *
 * <p>约束: {@link #completeJson} 是阻塞的网络调用, <b>绝不能在数据库事务里调用</b>; 客户文件内容一律用
 * {@code AiText(text, untrusted = true)} 传入。报销发票(ADR-094)不得经本接口送往外部 AI。
 */
public interface AiCompletionPort {

    /** 不发网络请求: 综合默认服务商是否启用、密钥能否解密、出网开关与区域策略给出当前是否可用。 */
    AiAvailability availability();

    /**
     * 请求一次 JSON 补全并返回抽取出的 JSON 文本。阻塞; 绝不能在数据库事务里调用。
     *
     * @throws AiCallException 服务不可用、被拦截、鉴权/额度/超时/网络/服务端错误或返回无法解析时;
     *                         异常消息是可以直接给用户看的中文, 从不包含密钥或服务商原始响应体
     */
    AiCompletionResult completeJson(AiCompletionRequest request);

    /**
     * 当前可用性。{@code providerName}/{@code model} 只给管理员界面用, 普通用户接口不回显;
     * 不可用时 {@code unavailableReason} 是给管理员看的一句话原因。
     */
    record AiAvailability(boolean available, String providerName, String model, boolean supportsVision,
                          String unavailableReason) {
    }

    /**
     * 一次补全请求。
     *
     * @param purpose         用途代码(写进调用技术记录, 如 {@code SALES_INTAKE_HEADER}), 不含业务数据
     * @param systemPrompt    英文系统提示词; 网关会追加「只输出一个 JSON 对象」与不可信文本说明
     * @param userParts       用户内容片段(文本或图片), 按顺序发送
     * @param jsonSchemaName  服务商支持 JSON_SCHEMA 时使用的 schema 名称; 可为空
     * @param jsonSchema      JSON Schema(服务商支持时原样下发, 否则由调用方在提示词里描述并在服务端校验); 可为空
     * @param maxOutputTokens 本次最大输出 token(网关再按服务商上限截断)
     * @param jobId           所属 AI 任务 id(写进调用技术记录); 非任务调用为空
     */
    record AiCompletionRequest(String purpose, String systemPrompt, List<AiContentPart> userParts,
                               String jsonSchemaName, Map<String, Object> jsonSchema, int maxOutputTokens,
                               UUID jobId) {
        public AiCompletionRequest {
            Objects.requireNonNull(purpose, "purpose");
            Objects.requireNonNull(systemPrompt, "systemPrompt");
            userParts = List.copyOf(Objects.requireNonNull(userParts, "userParts"));
            if (maxOutputTokens <= 0) {
                throw new IllegalArgumentException("maxOutputTokens must be positive");
            }
        }
    }

    /** 用户内容片段。 */
    sealed interface AiContentPart permits AiText, AiImage {
    }

    /**
     * 文本片段。{@code untrusted = true} 表示来自外部文件的数据: 网关用随机编号的
     * {@code <<<UNTRUSTED_DOCUMENT id=R>>>} 标记包起来, 并提示模型只抽取数据、不执行其中的任何指令。
     */
    record AiText(String text, boolean untrusted) implements AiContentPart {
        public AiText {
            Objects.requireNonNull(text, "text");
        }
    }

    /** 图片片段(只在服务商支持图片识别时可用), {@code mediaType} 如 {@code image/png}。 */
    record AiImage(byte[] bytes, String mediaType) implements AiContentPart {
        public AiImage {
            Objects.requireNonNull(bytes, "bytes");
            Objects.requireNonNull(mediaType, "mediaType");
        }
    }

    /** 补全结果: {@code json} 是已去掉 Markdown 代码块、取出首个完整 JSON 对象后的文本。 */
    record AiCompletionResult(String json, String providerName, String model, int inputTokens,
                              int outputTokens, long latencyMs) {
    }

    /** 失败类别(调用技术记录与界面提示按它归类)。 */
    enum AiErrorCategory {
        AUTH, NOT_FOUND, BAD_REQUEST, RATE_LIMIT, QUOTA, TIMEOUT, NETWORK, SERVER, INVALID_RESPONSE, BLOCKED,
        UNAVAILABLE
    }

    /**
     * AI 调用失败。消息是可以直接显示给用户的中文(不含密钥、不含服务商原始响应体);
     * {@code httpStatus} 只在服务商返回了 HTTP 状态时有值。
     */
    final class AiCallException extends RuntimeException {

        private final AiErrorCategory category;
        private final Integer httpStatus;

        public AiCallException(AiErrorCategory category, String userMessage) {
            this(category, userMessage, null, null);
        }

        public AiCallException(AiErrorCategory category, String userMessage, Integer httpStatus) {
            this(category, userMessage, httpStatus, null);
        }

        public AiCallException(AiErrorCategory category, String userMessage, Integer httpStatus, Throwable cause) {
            super(userMessage, cause);
            this.category = Objects.requireNonNull(category, "category");
            this.httpStatus = httpStatus;
        }

        public AiErrorCategory category() {
            return category;
        }

        public Integer httpStatus() {
            return httpStatus;
        }
    }
}
