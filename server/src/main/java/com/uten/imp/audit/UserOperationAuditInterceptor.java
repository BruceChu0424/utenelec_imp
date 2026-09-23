package com.uten.imp.audit;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.core.annotation.AnnotatedElementUtils;
import org.springframework.stereotype.Component;
import org.springframework.web.method.HandlerMethod;
import org.springframework.web.servlet.HandlerInterceptor;
import org.springframework.web.servlet.HandlerMapping;

import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

/**
 * Records API operations that reach Spring MVC. {@link AuditRequestContextFilter}
 * fills the requests rejected earlier in the filter/dispatcher chain.
 *
 * <p>ADR-105 口径:
 * <ul>
 *   <li>写请求(POST/PUT/PATCH/DELETE)从处理它的控制器方法推导一条语义业务事件
 *       (「资源.方法」+ 路径里的对象编号), 取代通用 http 行; 业务服务已经写了显式业务事件的
 *       请求不再重复, 声明了 {@link AuditAutomaticWrite} 的会话维护写入成功时不记;</li>
 *   <li>成功的读取默认不记, 只有声明了 {@link AuditedRead} 的端点留请求行;</li>
 *   <li>失败的请求一律留痕。</li>
 * </ul>
 * 请求体一律不进审计, 避免复制凭证与个人信息。
 */
@Slf4j
@Component
public class UserOperationAuditInterceptor implements HandlerInterceptor {

    private final SecurityContextCurrentUser currentUser;
    private final AuditService auditService;

    public UserOperationAuditInterceptor(
            SecurityContextCurrentUser currentUser,
            AuditService auditService) {
        this.currentUser = currentUser;
        this.auditService = auditService;
    }

    @Override
    public boolean preHandle(
            HttpServletRequest request,
            HttpServletResponse response,
            Object handler) {
        AuditRequestContext.ensureRequestId(request);
        if (AuditRequestContext.shouldAuditOperation(request)
                && !(request.getAttribute(
                        AuditRequestContext.OPERATION_START_NANOS_ATTRIBUTE) instanceof Long)) {
            request.setAttribute(
                    AuditRequestContext.OPERATION_START_NANOS_ATTRIBUTE,
                    System.nanoTime());
        }
        return true;
    }

    @Override
    public void afterCompletion(
            HttpServletRequest request,
            HttpServletResponse response,
            Object handler,
            Exception exception) {
        Object started = request.getAttribute(
                AuditRequestContext.OPERATION_START_NANOS_ATTRIBUTE);
        if (!(started instanceof Long startNanos)) {
            return;
        }
        logSafely(
                request,
                response,
                handler,
                currentUser.get().orElse(null),
                startNanos,
                exception != null);
    }

    private void logSafely(
            HttpServletRequest request,
            HttpServletResponse response,
            Object handler,
            AuthUser user,
            long startNanos,
            boolean requestFailed) {
        int status = response.getStatus();
        if (requestFailed && status < 400) {
            status = HttpServletResponse.SC_INTERNAL_SERVER_ERROR;
        }
        boolean failed = requestFailed || status >= 400;
        long durationMillis = Math.max(
                0,
                TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNanos));
        String method = request.getMethod().toUpperCase(Locale.ROOT);
        String path = request.getRequestURI();
        UUID actorId = user == null ? null : user.getId();
        String actorAccount = user == null ? null : user.getLoginAccount();
        try {
            if (handler instanceof HandlerMethod handlerMethod
                    && !AuditRequestContext.isRead(request)
                    && AuditRequestContext.shouldAuditOperation(request)) {
                logWrite(request, handlerMethod, failed, status, durationMillis,
                        method, path, actorId, actorAccount);
                return;
            }
            boolean auditedRead = handler instanceof HandlerMethod handlerMethod
                    && isAuditedRead(handlerMethod);
            if (!AuditRequestContext.shouldRecordOperation(request, status, requestFailed, auditedRead)) {
                AuditRequestContext.markOperationRecorded(request);
                return;
            }
            auditService.logHttpOperation(
                    actorId,
                    actorAccount,
                    method,
                    path,
                    AuditRequestContext.routeGroup(path),
                    status,
                    durationMillis);
            AuditRequestContext.markOperationRecorded(request);
        } catch (RuntimeException auditFailure) {
            // The response has already been produced; an audit sink outage must
            // be observable, but must not corrupt the completed business reply.
            log.error("Failed to persist user-operation audit metadata", auditFailure);
        }
    }

    private void logWrite(
            HttpServletRequest request,
            HandlerMethod handler,
            boolean failed,
            int status,
            long durationMillis,
            String method,
            String path,
            UUID actorId,
            String actorAccount) {
        if (Boolean.TRUE.equals(request.getAttribute(
                AuditRequestContext.OPERATION_RECORDED_ATTRIBUTE))) {
            return;
        }
        // 失败只在已经独立提交了失败类显式事件(如登录失败)时才算有了说明; 先写了成功类事件
        // (如导出开始前的导出记录)随后失败的, 照样补一条失败的语义事件。
        boolean alreadyExplained = failed
                ? AuditRequestContext.durableFailureRecorded(request)
                : AuditRequestContext.meaningfulEventRecorded(request)
                        || handler.hasMethodAnnotation(AuditAutomaticWrite.class);
        if (alreadyExplained) {
            AuditRequestContext.markOperationRecorded(request);
            return;
        }
        Class<?> controller = handler.getBeanType();
        auditService.logSemanticOperation(
                actorId,
                actorAccount,
                AuditActionNames.semanticAction(controller, handler.getMethod().getName()),
                AuditActionNames.resourceCode(controller),
                targetId(request),
                method,
                path,
                status,
                durationMillis);
        AuditRequestContext.markOperationRecorded(request);
    }

    private static boolean isAuditedRead(HandlerMethod handler) {
        return handler.hasMethodAnnotation(AuditedRead.class)
                || AnnotatedElementUtils.hasAnnotation(handler.getBeanType(), AuditedRead.class);
    }

    /** 路径变量里的对象编号: 优先 id, 其次唯一的 *Id 变量, 再次唯一的路径变量。 */
    static String targetId(HttpServletRequest request) {
        Object attribute = request.getAttribute(HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE);
        if (!(attribute instanceof Map<?, ?> variables) || variables.isEmpty()) {
            return null;
        }
        Object id = variables.get("id");
        if (id != null) {
            return id.toString();
        }
        String candidate = null;
        int idLike = 0;
        for (Map.Entry<?, ?> entry : variables.entrySet()) {
            String name = String.valueOf(entry.getKey());
            if (name.endsWith("Id") || name.endsWith("_id")) {
                idLike++;
                candidate = String.valueOf(entry.getValue());
            }
        }
        if (idLike == 1) {
            return candidate;
        }
        return variables.size() == 1 ? String.valueOf(variables.values().iterator().next()) : null;
    }
}
