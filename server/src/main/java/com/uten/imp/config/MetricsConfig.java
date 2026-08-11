package com.uten.imp.config;

import io.micrometer.core.instrument.config.MeterFilter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * 规范化 {@code http.server.requests}（及 {@code http.client.requests}）的 {@code uri}
 * 标签：把路径中的 UUID 段、纯数字 id 段折叠为 {@code {id}}，避免每个不同 id 生成独立 tag
 * 触发 Spring Boot 内置的 uri 标签上限（默认 100）—— 超限后 OnceLoggingDenyMeterFilter
 * 会拒绝后续 tag 并刷一条 "Reached the maximum number of 'uri' tags ..." 警告（纯噪音，不影响业务）。
 *
 * <p>控制器路径模式（如 {@code /api/x/{id}}）本就被 Spring 规范化为模板，此处主要兜底那些
 * 以原始路径上报的请求（如未匹配的 SPA 深链 404）。
 */
@Configuration
public class MetricsConfig {

    private static final String URI_TAG = "uri";

    @Bean
    MeterFilter uriNormalizingMeterFilter() {
        return MeterFilter.replaceTagValues(URI_TAG, value -> {
            if (value == null || value.isEmpty()) {
                return value;
            }
            // 保留常见常量（Spring 对 404/重定向/根 已给的稳定 tag）。
            switch (value) {
                case "NOT_FOUND", "REDIRECTION", "root", "UNKNOWN", "none" -> {
                    return value;
                }
                default -> {
                    // 先折叠 UUID，再折叠纯数字段（含负号外的整数）。
                    return value
                            .replaceAll(
                                    "/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                                    "/{id}")
                            .replaceAll("/\\d+(?=/|$)", "/{id}");
                }
            }
        });
    }
}
