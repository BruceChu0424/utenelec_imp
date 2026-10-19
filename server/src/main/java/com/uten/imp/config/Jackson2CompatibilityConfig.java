package com.uten.imp.config;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.MapperFeature;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Jackson 2 databind 兼容 bean。
 *
 * <p>Spring Boot 4 起 Web MVC 序列化切换到 Jackson 3（tools.jackson，由
 * spring-boot-jackson 自动装配提供 JsonMapper），容器不再注册
 * {@code com.fasterxml.jackson.databind.ObjectMapper}。本服务端有大量域持久化
 * 调用点（审计载荷、平台列 JSON、AI 快照等约 200 处）仍基于 Jackson 2 databind
 * （classpath 经 jjwt-jackson 传入），并按构造注入方式持有 ObjectMapper。
 * 这里补回一个按 Spring Boot 3 默认调校的 Jackson 2 ObjectMapper，保持这些
 * 注入点与反序列化宽严行为不变：</p>
 *
 * <ul>
 *   <li>FAIL_ON_UNKNOWN_PROPERTIES 关闭（Boot 3 默认，前端多传字段不炸）；</li>
 *   <li>DEFAULT_VIEW_INCLUSION 关闭（Boot 3 默认，与 @JsonView 语义一致）。</li>
 * </ul>
 *
 * <p>Web 层 JSON 输出由 Jackson 3 负责，两者互不影响。</p>
 */
@Configuration(proxyBeanMethods = false)
public class Jackson2CompatibilityConfig {

    @Bean
    JsonMapper jackson2DomainObjectMapper() {
        return JsonMapper.builder()
                .disable(MapperFeature.DEFAULT_VIEW_INCLUSION)
                .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
                .build();
    }
}
