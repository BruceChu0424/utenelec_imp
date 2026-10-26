package com.uten.imp.config;

import com.uten.imp.audit.UserOperationAuditInterceptor;
import com.uten.imp.common.report.ReportReadPlanInterceptor;
import com.uten.imp.common.report.MasterReadScopeInterceptor;
import com.uten.imp.security.ExportRateLimitInterceptor;
import com.uten.imp.security.ReadScopeVersionAuthority;
import com.uten.imp.security.SecurityContextCurrentUser;
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
    private final ReadScopeVersionAuthority readScopes;
    private final SecurityContextCurrentUser currentUser;

    public WebMvcConfig(
            ExportRateLimitInterceptor exportRateLimitInterceptor,
            UserOperationAuditInterceptor userOperationAuditInterceptor) {
        this(exportRateLimitInterceptor,userOperationAuditInterceptor,null,null);
    }
    @org.springframework.beans.factory.annotation.Autowired
    public WebMvcConfig(ExportRateLimitInterceptor exportRateLimitInterceptor,
            UserOperationAuditInterceptor userOperationAuditInterceptor,ReadScopeVersionAuthority readScopes,
            SecurityContextCurrentUser currentUser) {
        this.exportRateLimitInterceptor = exportRateLimitInterceptor;
        this.userOperationAuditInterceptor = userOperationAuditInterceptor;
        this.readScopes=readScopes;this.currentUser=currentUser;
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
        // 审计必须先进入拦截链；后续导出限流/并发闸门拒绝请求时，
        // 已进入的审计拦截器仍会在 afterCompletion 记录 429 结果。
        registry.addInterceptor(userOperationAuditInterceptor)
                .addPathPatterns("/api/**");
        registry.addInterceptor(new ReportReadPlanInterceptor(readScopes,currentUser))
                .addPathPatterns("/api/sales/reports/**", "/api/purchase/reports/**",
                        "/api/subcontract/reports/**", "/api/production/reports/**",
                        "/api/stock/reports/**", "/api/finance/reports/**");
        registry.addInterceptor(new com.uten.imp.common.report.NativeFacetCandidateInterceptor(readScopes,currentUser))
                .addPathPatterns(com.uten.imp.common.report.NativeFacetRoutes.paths().toArray(String[]::new));
        registry.addInterceptor(new MasterReadScopeInterceptor(readScopes,currentUser))
                .addPathPatterns("/api/master/**");
        registry.addInterceptor(new com.uten.imp.common.report.PurchasePrintReadScopeInterceptor(readScopes,currentUser))
                .addPathPatterns("/api/purchase/orders/*/print-data");
        registry.addInterceptor(new com.uten.imp.common.report.LegacyExportReadScopeInterceptor(readScopes,currentUser))
                .addPathPatterns("/api/**/export");
        // 拦截所有模块的导出端点及工资条 PDF 下载；这些端点均为 POST，
        // 非 POST 在拦截器内放行。
        registry.addInterceptor(exportRateLimitInterceptor)
                .addPathPatterns(
                        "/api/**/export",
                        "/api/report-export-jobs/*/download",
                        "/api/payroll/slips/*/download");
    }
}
