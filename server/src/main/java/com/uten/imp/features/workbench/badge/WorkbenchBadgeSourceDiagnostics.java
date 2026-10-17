package com.uten.imp.features.workbench.badge;

import com.uten.imp.common.web.ErrorCode;
import org.slf4j.Logger;

import java.time.Duration;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.LongSupplier;

/**
 * 每个已登记来源的故障日志生命周期；不缓存计数，也不参与授权或 stale 判断。
 * 相同故障每十分钟提醒一次，原因改变和授权读取恢复会立即记录。
 */
final class WorkbenchBadgeSourceDiagnostics {

    static final long WARNING_INTERVAL_NANOS = Duration.ofMinutes(10).toNanos();

    private final Map<String, SourceState> states;
    private final LongSupplier nanoTime;
    private final Logger log;

    WorkbenchBadgeSourceDiagnostics(Collection<String> registeredSources, LongSupplier nanoTime, Logger log) {
        Map<String, SourceState> registered = new LinkedHashMap<>();
        registeredSources.forEach(key -> registered.put(key, new SourceState()));
        this.states = Map.copyOf(registered);
        this.nanoTime = nanoTime;
        this.log = log;
    }

    void failed(String source, ErrorCode code) {
        failed(source, "code:" + code.name(), code.name());
    }

    void failed(String source, Class<? extends RuntimeException> exceptionType) {
        failed(source, "exception:" + exceptionType.getName(), exceptionType.getName());
    }

    private void failed(String source, String reason, String label) {
        SourceState state = state(source);
        // 时间读取和日志也在同一来源的锁内，避免并发轮询重复告警或打乱恢复顺序。
        synchronized (state) {
            long now = nanoTime.getAsLong();
            if (!reason.equals(state.reason) || now - state.lastWarningNanos >= WARNING_INTERVAL_NANOS) {
                log.warn("工作台徽章来源 {} 本次未算出: {}", source, label);
                state.lastWarningNanos = now;
            }
            state.reason = reason;
            state.label = label;
        }
    }

    /** 仅在有权读取成功后调用；拒权、未请求此来源均不能作为恢复证据。 */
    void recovered(String source) {
        SourceState state = state(source);
        synchronized (state) {
            if (state.reason == null) return;
            log.info("工作台徽章来源 {} 已恢复，前次原因: {}", source, state.label);
            state.reason = null;
            state.label = null;
        }
    }

    private SourceState state(String source) {
        SourceState state = states.get(source);
        if (state == null) throw new IllegalArgumentException("徽章诊断来源未登记: " + source);
        return state;
    }

    private static final class SourceState {
        private String reason;
        private String label;
        private long lastWarningNanos;
    }
}
