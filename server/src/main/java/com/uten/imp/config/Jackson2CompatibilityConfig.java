package com.uten.imp.config;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.MapperFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.converter.HttpMessageConverter;
import org.springframework.http.converter.json.JacksonJsonHttpMessageConverter;
import org.springframework.http.converter.json.MappingJackson2HttpMessageConverter;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

import java.util.List;

/**
 * Jackson 2 全站兼容层（Web 层 + 域持久化）。
 *
 * <p>Spring Boot 4 默认把 Web MVC 序列化切到 Jackson 3（tools.jackson），但本服务端有
 * 大量 databind 2 资产：约 200 处域持久化调用点、248 处 DTO 字段级
 * {@code @JsonSerialize}（ExactDecimalText 精确小数文本、ToStringSerializer 长整型、
 * 物料分析 sparse 投影自定义序列化器等）——Jackson 3 不读 databind 2 的序列化器注解，
 * 直接升级会让这些 API 的线上格式静默变形。因此本批次把 Web 层显式钉回
 * MappingJackson2HttpMessageConverter（共享下方按 Boot 3 默认调校的 ObjectMapper），
 * Jackson 3 仅保留给框架内部（actuator 等）。</p>
 *
 * <p>技术债说明：MappingJackson2HttpMessageConverter 在 Spring Framework 7 已标记
 * 待删除；Spring 7.1 移除前必须完成全站 Jackson 3 迁移（序列化器镜像 + 双注解），
 * 届时删除本配置即可。</p>
 */
@Configuration(proxyBeanMethods = false)
@SuppressWarnings("removal")
public class Jackson2CompatibilityConfig {

    @Bean
    JsonMapper jackson2DomainObjectMapper() {
        // 对齐 Boot 3 自动装配 ObjectMapper 的三件事：注册 classpath 上的模块
        // （jsr310 日期/时长等，漏了会 500：OffsetDateTime not supported）、
        // 关 DEFAULT_VIEW_INCLUSION 与 FAIL_ON_UNKNOWN_PROPERTIES（Boot 3 默认）、
        // 关 WRITE_DATES_AS_TIMESTAMPS（Boot 3 默认日期输出 ISO-8601 字符串）。
        return JsonMapper.builder()
                .findAndAddModules()
                .disable(MapperFeature.DEFAULT_VIEW_INCLUSION)
                .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
                .disable(com.fasterxml.jackson.databind.SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
                .build();
    }

    /**
     * MVC 消息转换器：摘掉 Boot 4 装配的 Jackson 3 转换器，把 Jackson 2 转换器放到
     * 队首。@JsonSerialize 自定义序列化器与既有线上 JSON 格式全部保持原样。
     */
    @Bean
    WebMvcConfigurer jackson2WebMessageConverters(ObjectMapper jackson2DomainObjectMapper) {
        return new WebMvcConfigurer() {
            @Override
            public void extendMessageConverters(List<HttpMessageConverter<?>> converters) {
                converters.removeIf(JacksonJsonHttpMessageConverter.class::isInstance);
                converters.add(0, new MappingJackson2HttpMessageConverter(jackson2DomainObjectMapper));
            }
        };
    }
}
