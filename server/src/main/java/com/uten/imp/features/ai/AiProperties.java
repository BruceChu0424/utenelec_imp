package com.uten.imp.features.ai;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * 公共 AI 平台的部署开关与限额(uten.ai.*, ADR-133)。服务商、模型与密钥不在这里,
 * 由超管在「系统设置 → AI 服务」维护(ai_providers); 这里只放运维决定的边界。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.ai")
public class AiProperties {

    /** 是否允许把数据发给境内/境外服务商(本机部署 LOCAL 不受影响)。internal-test 强制 false。 */
    private boolean outboundEnabled = true;

    /** 是否允许配置与调用境外服务商(OpenAI/Claude/Gemini 等)。默认关闭: 需完成数据出境评估后由运维开启。 */
    private boolean allowOverseasProviders = false;

    /** 本机部署类服务商是否允许明文 http 访问内网地址(RFC1918/fc00::/7)。默认只允许 127.0.0.1/::1。 */
    private boolean allowLanHttp = false;

    /** 全进程同时进行的 AI 调用上限。 */
    private int maxConcurrentCalls = 4;

    /** 等待调用名额的最长秒数, 超时报「AI 正忙」。 */
    private int callPermitWaitSeconds = 30;

    /** 每天(上海时区)全部 AI 调用的 token 总额度; 0 表示不限。 */
    private long dailyTokenBudget = 3_000_000L;

    /** 单个识别任务最多调用 AI 的次数。 */
    private int maxCallsPerJob = 12;

    /** 每人同时进行(排队+处理中)的任务上限。 */
    private int maxActiveJobsPerUser = 2;

    /** 每人每天(上海时区)提交任务上限。 */
    private int maxJobsPerUserPerDay = 60;

    /** 全局排队任务上限(防积压)。 */
    private int maxPendingJobs = 100;

    /** 上传文件的框架硬上限(字节); 处理器声明的上限不能超过它。 */
    private long maxInputBytes = 15L * 1024 * 1024;

    /** 同一人同一文件同一参数在这么多分钟内重复提交, 直接复用已有任务。 */
    private int idempotencyWindowMinutes = 10;

    /** 后台处理线程数。 */
    private int jobWorkers = 2;

    /** 后台线程等待队列长度(只是唤醒加速, 真正的队列在数据库)。 */
    private int jobQueueCapacity = 8;

    /**
     * 处理中任务的租约秒数; 过期视为处理线程已死。阶段报告续租, AI 调用期间每隔租约的 1/4(最长 60 秒)续租一次。
     */
    private int jobLeaseSeconds = 600;

    /** 排队超过这么多分钟仍没人处理, 判失败并清空上传文件。 */
    private int pendingTimeoutMinutes = 30;

    /** 结果保留小时数(没被使用的结果到期清空)。 */
    private int resultRetentionHours = 48;

    /** 任务行保留天数。 */
    private int jobRetentionDays = 7;

    /** 调用技术记录保留天数。 */
    private int callLogRetentionDays = 180;

    /** 个人操作记忆(ADR-163)保留天数: 超过这么多天没再使用的记忆行由 AI 定时清理删除。 */
    private int operationMemoryRetentionDays = 90;
}
