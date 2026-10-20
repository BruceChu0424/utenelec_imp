package com.uten.imp.config;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.MapperFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.json.JsonMapper;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.MediaType;
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

    /**
     * MVC 消息转换器：摘掉 Boot 4 装配的 Jackson 3 转换器，把 Jackson 2 转换器放到
     * 队首。@JsonSerialize 自定义序列化器与既有线上 JSON 格式全部保持原样。
     * ObjectMapper bean 由 {@link Jackson2ObjectMapperAutoConfiguration} 以自动
     * 配置形态提供（@WebMvcTest 切片同样可用）。
     */
    @Bean
    WebMvcConfigurer jackson2WebMessageConverters(ObjectMapper jackson2DomainObjectMapper) {
        return new WebMvcConfigurer() {
            @Override
            public void extendMessageConverters(List<HttpMessageConverter<?>> converters) {
                converters.removeIf(JacksonJsonHttpMessageConverter.class::isInstance);
                converters.add(0, new MappingJackson2HttpMessageConverter(jackson2DomainObjectMapper) {
                    // springdoc 3 的 /v3/api-docs 返回预序列化的 byte[]（Jackson 3 产物）；
                    // 队首的 Jackson 2 转换器会把 byte[] 当普通对象编码成 base64 字符串。
                    // 拒收 byte[]，让其落回 ByteArrayHttpMessageConverter 原样输出。
                    @Override
                    public boolean canWrite(Class<?> clazz, MediaType mediaType) {
                        return !byte[].class.isAssignableFrom(clazz)
                                && super.canWrite(clazz, mediaType);
                    }

                    @Override
                    public boolean canWrite(java.lang.reflect.Type type, Class<?> clazz, MediaType mediaType) {
                        return !(type instanceof Class<?> concrete && byte[].class.isAssignableFrom(concrete))
                                && super.canWrite(type, clazz, mediaType);
                    }
                });
            }
        };
    }
}
