package com.uten.imp.features.ai.job;

import java.util.UUID;

/** 新任务已入队; 事务提交后唤醒后台线程(没有后台线程的云端实例上无人监听, 由本地轮询接手)。 */
public record AiJobSubmittedEvent(UUID jobId) {
}
