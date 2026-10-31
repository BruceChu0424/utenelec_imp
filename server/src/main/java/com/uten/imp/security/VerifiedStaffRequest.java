package com.uten.imp.security;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import java.util.UUID;

/** Request-local authority proven by JwtAuthFilter, never supplied by a body/header attribute. */
final class VerifiedStaffRequest {
    private VerifiedStaffRequest() {}
    private static final String ATTRIBUTE=VerifiedStaffRequest.class.getName();
    record Identity(UUID userId,UUID employeeId,UUID sessionId,long authVersion,long authorizationEpoch) {}

    static void clear(HttpServletRequest request) { request.removeAttribute(ATTRIBUTE); }

    static void bind(HttpServletRequest request,AuthUser user,Long version,Long epoch) {
        if(user.isVisitor() || user.getImpersonatedBy()!=null || user.getSessionId()==null || version==null || epoch==null) return;
        request.setAttribute(ATTRIBUTE,new Identity(user.getId(),user.getEmployeeId(),user.getSessionId(),version,epoch));
    }

    static Identity current() {
        if(RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes attributes
                && attributes.getRequest().getAttribute(ATTRIBUTE) instanceof Identity identity) return identity;
        return null;
    }
}
