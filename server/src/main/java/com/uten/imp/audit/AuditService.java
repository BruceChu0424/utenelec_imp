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
        AuditLog a = base(action, targetType, targetId, result);
        a.setActorId(actorId);
        a.setActorAccount(actorAccount);
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
            a.setIp(clientIp(req));
            a.setUserAgent(req.getHeader("User-Agent"));
        }
    }

    private HttpServletRequest currentRequest() {
        var attrs = RequestContextHolder.getRequestAttributes();
        return attrs instanceof ServletRequestAttributes sra ? sra.getRequest() : null;
    }

    private String clientIp(HttpServletRequest req) {
        String xff = req.getHeader("X-Forwarded-For");
        if (xff != null && !xff.isBlank()) {
            return xff.split(",")[0].trim();
        }
        return req.getRemoteAddr();
    }
}
