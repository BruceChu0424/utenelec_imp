package com.uten.imp.features.ai.job;

import com.uten.imp.application.port.AiJobHandler;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * 按任务种类找处理器(ADR-133)。业务 feature 实现 {@link AiJobHandler} 并注册为 Bean 即自动接入;
 * 种类必须是大写下划线且全局唯一, 启动时校验, 重复即启动失败。
 */
@Component
public class AiJobHandlerRegistry {

    private static final Pattern KIND = Pattern.compile("^[A-Z][A-Z0-9_]{1,47}$");

    private final Map<String, AiJobHandler> handlers = new HashMap<>();

    public AiJobHandlerRegistry(List<AiJobHandler> handlers) {
        for (AiJobHandler handler : handlers) {
            String kind = handler.kind();
            if (kind == null || !KIND.matcher(kind).matches()) {
                throw new IllegalStateException("AI job handler kind must be UPPER_SNAKE (<= 48 chars): " + kind);
            }
            if (this.handlers.putIfAbsent(kind, handler) != null) {
                throw new IllegalStateException("Duplicate AI job handler kind: " + kind);
            }
        }
    }

    public Optional<AiJobHandler> find(String kind) {
        return kind == null ? Optional.empty() : Optional.ofNullable(handlers.get(kind));
    }
}
