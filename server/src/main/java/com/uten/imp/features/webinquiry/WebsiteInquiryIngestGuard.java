package com.uten.imp.features.webinquiry;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 官网询盘 ingest 入口守卫：共享密钥（常量时间比较）+ 简单固定窗口限流。
 *
 * <p>密钥配置 {@code uten.website.inquiry-ingest-token}；未配置时 fail closed（拒绝全部推送），
 * 与官网侧 {@code IMP_INGEST_TOKEN} 成对设置。该接口在 SecurityConfig 中 permitAll，
 * 因此本守卫是唯一的认证边界，不接受空密钥通过。
 */
@Component
public class WebsiteInquiryIngestGuard {

    /** 推送限流：每密钥每分钟最多 60 次（官网表单侧另有 IP 限流，这里防脚本直打）。 */
    private static final int WINDOW_LIMIT = 60;
    private static final long WINDOW_MILLIS = 60_000L;

    private final String configuredToken;
    private final Map<String, Window> windows = new ConcurrentHashMap<>();

    public WebsiteInquiryIngestGuard(
            @Value("${uten.website.inquiry-ingest-token:}") String configuredToken) {
        this.configuredToken = configuredToken == null ? "" : configuredToken.trim();
    }

    public boolean tokenValid(String presented) {
        if (configuredToken.isEmpty() || presented == null || presented.isEmpty()) {
            return false;
        }
        return MessageDigest.isEqual(
                configuredToken.getBytes(StandardCharsets.UTF_8),
                presented.getBytes(StandardCharsets.UTF_8));
    }

    public boolean allow(String key) {
        long now = System.currentTimeMillis();
        Window window = windows.computeIfAbsent(key, k -> new Window(now));
        synchronized (window) {
            if (now - window.startMillis >= WINDOW_MILLIS) {
                window.startMillis = now;
                window.count.set(0);
            }
            return window.count.incrementAndGet() <= WINDOW_LIMIT;
        }
    }

    private static final class Window {
        private long startMillis;
        private final AtomicInteger count = new AtomicInteger();

        private Window(long startMillis) {
            this.startMillis = startMillis;
        }
    }
}
