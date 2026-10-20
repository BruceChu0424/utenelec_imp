package com.uten.imp.config;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.MapperFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.context.annotation.Bean;

/**
 * Jackson 2 databind 兼容 bean（自动配置形态）。
 *
 * <p>Spring Boot 4 的 JacksonAutoConfiguration 只提供 tools.jackson（Jackson 3）的
 * JsonMapper，但本服务端有约 200 处域持久化调用点与 248 处 DTO 字段级
 * {@code @JsonSerialize} 仍基于 databind 2，且若干安全过滤器在构造器注入
 * {@code com.fasterxml.jackson.databind.ObjectMapper}。Boot 3 时代该 bean 由
 * JacksonAutoConfiguration 提供并在 @WebMvcTest 等切片中同样可用；以自动配置
 * 注册可以在完整应用与所有测试切片中一并补齐，避免整类上下文启动失败。</p>
 *
 * <p>调校对齐 Boot 3 自动装配的 ObjectMapper 默认：注册 classpath 模块
 * （jsr310 等）、关 DEFAULT_VIEW_INCLUSION、关 FAIL_ON_UNKNOWN_PROPERTIES、
 * 关 WRITE_DATES_AS_TIMESTAMPS（日期输出 ISO-8601）、关
 * FAIL_ON_NULL_FOR_PRIMITIVES（databind 2.21 起默认翻严，前端可选布尔传 null
 * 会 400，保持升级前宽严行为）。</p>
 *
 * <p>技术债：Web 层消息转换器由
 * {@link Jackson2CompatibilityConfig} 钉回 MappingJackson2HttpMessageConverter；
 * Spring 7.1 移除该转换器前必须完成全站 Jackson 3 迁移并删除本兼容层。</p>
 */
@AutoConfiguration
public class Jackson2ObjectMapperAutoConfiguration {

    @Bean
    JsonMapper jackson2DomainObjectMapper() {
        return domainObjectMapper();
    }

    /** 供测试切片等无法走自动配置的上下文复用同一套调校。 */
    public static JsonMapper domainObjectMapper() {
        return JsonMapper.builder()
                .findAndAddModules()
                .disable(MapperFeature.DEFAULT_VIEW_INCLUSION)
                .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
                .disable(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES)
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
                .build();
    }
}
