package com.uten.imp.application.port;

import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * AI 识别任务的业务处理器(ADR-133)。公共任务框架(features/ai/job)负责上传、排队、认领、进度、取消、
 * 租约与清理; 业务 feature 只实现本接口并注册为 Spring Bean, 用 {@link #kind()} 区分。
 *
 * <p>调用顺序(提交): 找处理器(找不到 404) → {@link #authorizeSubmit} → 每人限额 → 按
 * {@link #maxInputBytes()} 有界读取上传内容 → 文件类型嗅探({@link #acceptedKinds()}) →
 * {@link #validateInput} → 幂等复用 → 入队。读取结果时每次都重新 {@link #authorizeRead} 并经
 * {@link #filterResultForReader} 过滤。{@link #process} 在后台线程、无事务、以提交人恢复出的权限运行。
 *
 * <p>授权失败抛 {@link com.uten.imp.common.web.ApiException}(403/400); 处理中抛出的 ApiException 以其消息
 * 作为失败原因展示给用户, 其它异常一律显示「识别失败, 请稍后重试」(堆栈只记服务端日志)。需要前端区分失败原因时,
 * 在 ApiException 的 fieldErrors 里放 {@code field = "errorCode"}、{@code message = 业务码}(大写下划线,
 * 不超过 48 字符, 如 AI_REQUIRED), 框架把它写进任务的 errorCode; 没有时 errorCode 为 ApiException 的错误类别名。
 *
 * <p>阶段名(progress 的 stage)用大写下划线; 框架的坏文件判定只认 {@code READING}/{@code PARSING}/{@code LAYOUT}
 * 为「还在读文件」阶段(租约过期停在这些阶段即判「文件无法解析」、不重试), 处理器应在解析整个文件时报这些阶段,
 * 解析完成后再报后续阶段(如 EXTRACTING、MATCHING_GOODS、MATCHING_CLIENT、PRICING、DONE)。
 * 用户取消时处理器可以直接返回空结果, 框架按「已取消」结束, 不保存结果。
 */
public interface AiJobHandler {

    /** 任务种类, 如 {@code SALES_DOCUMENT_INTAKE}(大写下划线, 不超过 48 字符)。 */
    String kind();

    /** 读取上传内容<b>之前</b>校验提交人权限与参数; 不通过抛 ApiException 403/400。 */
    void authorizeSubmit(Map<String, String> params);

    /** 有界读取与文件类型嗅探之后校验输入(类型、大小、参数引用的主档是否可见等)。 */
    void validateInput(Map<String, String> params, AiJobInput input);

    /** 允许的最大上传字节数(框架有界读取, 超出即 413)。 */
    long maxInputBytes();

    /** 接受的文件类型(DocumentKind 名称: XLSX/XLS/CSV/PDF/PNG/JPEG/WEBP)。 */
    Set<String> acceptedKinds();

    /** 每次读取任务结果都重新校验(提交人后来失去权限就读不到); 不通过抛 ApiException。 */
    void authorizeRead(Map<String, String> params);

    /** 按当前读者的权限过滤结果(例如失去价格查看权限时去掉标价与折扣); 不得修改入参。 */
    Map<String, Object> filterResultForReader(Map<String, Object> result);

    /**
     * 后台处理: 工作线程上执行, 没有数据库事务(需要读写时由实现自己开短事务), 安全上下文是提交人
     * 恢复出的主体。返回值作为任务结果保存(JSON 对象)。
     */
    Map<String, Object> process(AiJobContext ctx) throws Exception;

    /**
     * 上传内容。
     *
     * @param fileName    原始文件名(已解码)
     * @param contentType 客户端声明的类型(只作参考, 以嗅探结果 {@code kind} 为准)
     * @param kind        嗅探出的 DocumentKind 名称
     * @param size        字节数
     * @param bytes       文件内容
     * @param sha256      内容 SHA-256, 64 位小写十六进制(与 ai_jobs.input_sha256 同口径)
     */
    record AiJobInput(String fileName, String contentType, String kind, long size, byte[] bytes, String sha256) {
        public AiJobInput {
            Objects.requireNonNull(fileName, "fileName");
            Objects.requireNonNull(kind, "kind");
            Objects.requireNonNull(bytes, "bytes");
            Objects.requireNonNull(sha256, "sha256");
        }
    }

    /** 处理期间框架提供给处理器的上下文。 */
    interface AiJobContext {

        UUID jobId();

        String kind();

        Map<String, String> params();

        AiJobInput input();

        UUID submittedByUser();

        /** 提交人绑定的员工 id; 账号未绑定员工时为空。 */
        UUID submittedByEmployee();

        /** 报告阶段与进度(0-100): 短的独立事务; 任务行已被清库/清理删除时静默返回。 */
        void progress(String stage, int percent);

        /** 用户已请求取消, 或系统正在排水准备清空业务数据; 处理器应在阶段之间检查并尽快返回。 */
        boolean cancelled();

        /** 本任务剩余的 AI 调用次数(uten.ai.max-calls-per-job, 默认 12)。 */
        int remainingAiCalls();

        /**
         * 经公共 AI 平台发起一次 JSON 补全, 计入本任务调用次数。次数用完或提交人没有 {@code ai:use} 时抛
         * {@link AiCompletionPort.AiCallException}(BLOCKED)。阻塞调用, 不得在事务中调用。
         */
        AiCompletionPort.AiCompletionResult completeJson(AiCompletionPort.AiCompletionRequest req);

        /** 提交人持有 {@code ai:use} 且 AI 服务当前可用。为 false 时处理器只走固定规则。 */
        boolean aiAllowed();
    }
}
