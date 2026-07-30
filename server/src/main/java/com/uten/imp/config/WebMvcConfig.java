package com.uten.imp.config;

import com.uten.imp.audit.UserOperationAuditInterceptor;
import com.uten.imp.security.ExportRateLimitInterceptor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.LocaleResolver;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;
import org.springframework.web.servlet.i18n.AcceptHeaderLocaleResolver;

import java.util.Locale;

/**
 * MVC 层配置：注册拦截器。
 *
 * <p>注：CORS / Spring Security 过滤器链在 {@code SecurityConfig}（Security Filter 层），
 * 本类只注册 MVC 拦截器（DispatcherServlet 内、Controller 前），互不干扰。
 */
@Configuration
public class WebMvcConfig implements WebMvcConfigurer {

    private final ExportRateLimitInterceptor exportRateLimitInterceptor;
    private final UserOperationAuditInterceptor userOperationAuditInterceptor;

    public WebMvcConfig(
            ExportRateLimitInterceptor exportRateLimitInterceptor,
            UserOperationAuditInterceptor userOperationAuditInterceptor) {
        this.exportRateLimitInterceptor = exportRateLimitInterceptor;
        this.userOperationAuditInterceptor = userOperationAuditInterceptor;
    }

    /**
     * 无 Accept-Language 时按简体中文返回校验消息；显式请求其他语言的客户端仍可覆盖。
     */
    @Bean
    public LocaleResolver localeResolver() {
        AcceptHeaderLocaleResolver resolver = new AcceptHeaderLocaleResolver();
        resolver.setDefaultLocale(Locale.SIMPLIFIED_CHINESE);
        return resolver;
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        // 拦截所有模块的导出端点及工资条 PDF 下载；这些端点均为 POST，
        // 非 POST 在拦截器内放行。
        registry.addInterceptor(exportRateLimitInterceptor)
                .addPathPatterns(
                        "/api/**/export",
                        "/api/payroll/slips/*/download");
        registry.addInterceptor(userOperationAuditInterceptor)
                .addPathPatterns("/api/**")
                .excludePathPatterns(
                        "/api/auth/login",
                        "/api/auth/refresh",
                        "/api/visitor/auth/**");
    }
}
