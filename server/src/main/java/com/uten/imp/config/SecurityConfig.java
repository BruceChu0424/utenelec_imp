package com.uten.imp.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditRequestContextFilter;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.SecurityProperties;
import com.uten.imp.security.JwtAuthFilter;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.MediaType;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.argon2.Argon2PasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;
import org.springframework.web.filter.CorsFilter;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.List;
import lombok.extern.slf4j.Slf4j;

/**
 * 安全配置：无状态 JWT、CSRF 关闭（JWT 走 Authorization 头）、CORS 严格白名单、方法级 @PreAuthorize。
 * permitAll：登录/刷新/健康检查/文档；其余 authenticated（含 change-password，首登用户的 CHANGE_PASSWORD 权限可通过）。
 *
 * <p>{@link #filterChain} 显式配置 {@code AuthenticationEntryPoint}：未认证/匿名请求（含 access token
 * 过期、缺失、伪造）统一返回 <b>401 + ApiError(UNAUTHORIZED)</b>。否则 Spring 默认用
 * {@code Http403ForbiddenEntryPoint} 返 403，会被前端 AuthInterceptor 当成「无权限」（它只在 401 时刷新 token），
 * 导致 access token 每次过期都误显「无权限」、需重登才恢复。业务接口本就要求登录，401 语义更正确。
 * 「已认证但权限不足」仍由 {@code GlobalExceptionHandler.handleAccessDenied} 返 403 FORBIDDEN，不变。
 */
@Configuration
@EnableMethodSecurity(prePostEnabled = true)
@Slf4j
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http,
                                           AuditRequestContextFilter auditContextFilter,
                                           JwtAuthFilter jwtAuthFilter,
                                           SecurityProperties securityProps,
                                           ObjectMapper objectMapper,
                                           AuditService auditService) throws Exception {
        String[] publicPaths = securityProps.isSwaggerEnabled()
                ? new String[]{
                        "/api/auth/login",
                        "/api/auth/refresh",
                        "/api/visitor/auth/**",
                        "/actuator/health",
                        "/swagger-ui/**",
                        "/swagger-ui.html",
                        "/v3/api-docs/**"
                }
                : new String[]{
                        "/api/auth/login",
                        "/api/auth/refresh",
                        "/api/visitor/auth/**",
                        "/actuator/health"
                };
        http
                .csrf(AbstractHttpConfigurer::disable)
                .httpBasic(AbstractHttpConfigurer::disable)
                .formLogin(AbstractHttpConfigurer::disable)
                .logout(AbstractHttpConfigurer::disable)
                .requestCache(AbstractHttpConfigurer::disable)
                .rememberMe(AbstractHttpConfigurer::disable)
                .cors(cors -> cors.configurationSource(corsConfigurationSource(securityProps)))
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(a -> a
                        .requestMatchers(publicPaths).permitAll()
                        .anyRequest().authenticated()
                )
                .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter.class)
                // CORS can reject an invalid Origin before JWT/MVC. The audit
                // filter must wrap that rejection so the resulting 403 is not lost.
                .addFilterBefore(auditContextFilter, CorsFilter.class)
                // 未认证/匿名（access token 过期、缺失、伪造）→ 401 + ApiError(UNAUTHORIZED)，
                // 让前端 AuthInterceptor 识别 401 后自动 refresh 续期（用户无感），而非被默认
                // Http403ForbiddenEntryPoint 返 403 误判成「无权限」。
                .exceptionHandling(e -> e.authenticationEntryPoint((req, resp, ex) -> {
                    try {
                        auditService.logSecurityEvent(
                                req, null, null,
                                "access_denied", "unauthorized", 401);
                    } catch (RuntimeException auditFailure) {
                        log.error("Failed to persist authentication-denied audit event", auditFailure);
                    }
                    resp.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
                    resp.setContentType(MediaType.APPLICATION_JSON_VALUE);
                    resp.setCharacterEncoding(StandardCharsets.UTF_8.name());
                    resp.getWriter().write(objectMapper.writeValueAsString(
                            ApiError.of(ErrorCode.UNAUTHORIZED, null)));
                }));

        if (securityProps.isRequireHttps()) {
            http.redirectToHttps(Customizer.withDefaults());
        }
        return http.build();
    }

    /** Argon2id 密码哈希（OWASP 参数：内存 19456 KiB、迭代 2、并行 1、盐 16、哈希 32 字节）。 */
    @Bean
    public PasswordEncoder passwordEncoder() {
        return new Argon2PasswordEncoder(16, 32, 1, 19456, 2);
    }

    @Bean
    public CorsConfigurationSource corsConfigurationSource(SecurityProperties securityProps) {
        CorsConfiguration cfg = new CorsConfiguration();
        List<String> origins = java.util.Arrays
                .stream(securityProps.getCorsAllowedOrigins().split(","))
                .map(String::trim)
                .filter(origin -> !origin.isBlank())
                .toList();
        if (origins.isEmpty()) {
            throw new IllegalStateException("uten.security.cors-allowed-origins must not be empty");
        }
        origins.forEach(SecurityConfig::validateCorsOrigin);
        cfg.setAllowedOrigins(origins);
        cfg.setAllowedMethods(List.of("GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"));
        cfg.setAllowedHeaders(List.of(
                "Authorization",
                "Content-Type",
                "Accept",
                AuditDeviceContext.HEADER_CLIENT_EVENT_ID,
                AuditDeviceContext.HEADER_DEVICE_CONTEXT));
        cfg.setExposedHeaders(List.of(
                "Content-Disposition",
                AuditRequestContext.RESPONSE_REQUEST_ID_HEADER,
                AuditDeviceContext.HEADER_CLIENT_EVENT_ID));
        // Authentication is carried only in an explicit Bearer header, never cookies.
        cfg.setAllowCredentials(false);
        cfg.setMaxAge(3600L);
        UrlBasedCorsConfigurationSource src = new UrlBasedCorsConfigurationSource();
        src.registerCorsConfiguration("/**", cfg);
        return src;
    }

    private static void validateCorsOrigin(String origin) {
        URI uri;
        try {
            uri = URI.create(origin);
        } catch (IllegalArgumentException ex) {
            throw new IllegalStateException("Invalid CORS origin: " + origin, ex);
        }
        boolean validScheme = "https".equalsIgnoreCase(uri.getScheme())
                || "http".equalsIgnoreCase(uri.getScheme());
        boolean originOnly = uri.getHost() != null
                && uri.getUserInfo() == null
                && (uri.getPath() == null || uri.getPath().isEmpty())
                && uri.getQuery() == null
                && uri.getFragment() == null;
        if ("*".equals(origin) || !validScheme || !originOnly) {
            throw new IllegalStateException(
                    "CORS entries must be explicit HTTP(S) origins without paths: " + origin);
        }
    }
}
