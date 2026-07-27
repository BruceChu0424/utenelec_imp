package com.uten.imp.config;

import com.uten.imp.security.ExportRateLimitInterceptor;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/**
 * MVC 层配置：注册拦截器。
 *
 * <p>注：CORS / Spring Security 过滤器链在 {@code SecurityConfig}（Security Filter 层），
 * 本类只注册 MVC 拦截器（DispatcherServlet 内、Controller 前），互不干扰。
 */
@Configuration
public class WebMvcConfig implements WebMvcConfigurer {

    private final ExportRateLimitInterceptor exportRateLimitInterceptor;

    public WebMvcConfig(ExportRateLimitInterceptor exportRateLimitInterceptor) {
        this.exportRateLimitInterceptor = exportRateLimitInterceptor;
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        // 拦截所有模块的导出端点（/api/purchase/reports/export、/api/master/goods/export …）。
        // 导出端点均为 POST /export；非 POST 在拦截器内放行。
        registry.addInterceptor(exportRateLimitInterceptor)
                .addPathPatterns("/api/**/export");
    }
}
