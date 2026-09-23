package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.StepUpService;
import org.aopalliance.intercept.MethodInterceptor;
import org.aopalliance.intercept.MethodInvocation;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.context.request.RequestAttributes;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

/**
 * {@link RequiresStepUp} 的执行者: 进入被标注的控制器方法时核销请求头里的再认证凭证 (ADR-110)。
 *
 * <p>以方法拦截器挂在控制器代理上 (见 {@link StepUpAdvisorConfig}), 顺序排在方法安全
 * ({@code @PreAuthorize}) 之后。因此一次请求依次经过: 参数绑定与 {@code @Valid} 校验 (不合法直接 400,
 * 凭证不动) → 权限判定 (无权直接 403 FORBIDDEN, 不会先弹密码框) → 核销凭证 → 业务。
 * 凭证缺失、过期、已用过或不属于当前会话一律 403 REAUTH_REQUIRED, 前端据此弹出统一的「重新输入密码」
 * 弹窗, 换到凭证后原样重发。核销是原子的一次性更新, 同一凭证并发重放只有一个成功。</p>
 *
 * <p>再认证服务按需解析: 基础设施拦截器在容器早期创建, 不能提前实例化整套认证服务。</p>
 */
public class StepUpInterceptor implements MethodInterceptor {

    /** 携带再认证凭证的请求头。 */
    public static final String HEADER = "X-Uten-Step-Up";

    private final ObjectProvider<StepUpService> stepUp;

    public StepUpInterceptor(ObjectProvider<StepUpService> stepUp) {
        this.stepUp = stepUp;
    }

    @Override
    public Object invoke(MethodInvocation invocation) throws Throwable {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication == null || !(authentication.getPrincipal() instanceof AuthUser principal)) {
            throw new ApiException(ErrorCode.UNAUTHORIZED);
        }
        stepUp.getObject().consume(principal, currentHeader());
        return invocation.proceed();
    }

    private static String currentHeader() {
        RequestAttributes attributes = RequestContextHolder.getRequestAttributes();
        if (attributes instanceof ServletRequestAttributes servlet) {
            return servlet.getRequest().getHeader(HEADER);
        }
        return null;
    }
}
