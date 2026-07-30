package com.uten.imp.audit;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.util.UUID;

/**
 * 显式审计写入（登录/改密/重置密码等非数据变更事件）。
 * 用 Propagation.REQUIRES_NEW 确保审计即便主流程回滚也落库（如登录失败）。
 * 数据变更类审计由 DB 触发器负责。
 */
@Service
public class AuditService {

    private final AuditLogRepository repo;

    public AuditService(AuditLogRepository repo) {
        this.repo = repo;
    }

    /** 显式指定操作人（登录/改密/logout 等场景；actor 由调用方给出）。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void logExplicit(UUID actorId, String actorAccount, String action,
                            String targetType, String targetId, String result) {
        AuditLog a = base(
                truncate(action, 120),
                truncate(targetType, 200),
                truncate(targetId, 1000),
                truncate(result, 500));
        a.setActorId(actorId);
        a.setActorAccount(truncate(actorAccount, 200));
        fillRequest(a);
        repo.save(a);
    }

    private AuditLog base(String action, String targetType, String targetId, String result) {
        AuditLog a = new AuditLog();
        a.setAction(action);
        a.setTargetType(targetType);
        a.setTargetId(targetId);
        a.setResult(result);
        return a;
    }

    private void fillRequest(AuditLog a) {
        HttpServletRequest req = currentRequest();
        if (req != null) {
            a.setIp(truncate(req.getRemoteAddr(), 64));
            a.setUserAgent(truncate(req.getHeader("User-Agent"), 1000));
        }
    }

    private HttpServletRequest currentRequest() {
        var attrs = RequestContextHolder.getRequestAttributes();
        return attrs instanceof ServletRequestAttributes sra ? sra.getRequest() : null;
    }

    private String truncate(String value, int maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength);
    }
}
