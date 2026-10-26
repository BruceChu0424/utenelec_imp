package com.uten.imp.common.export;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import java.util.*;

/** Request-owned minimum proof of platform columns actually projected by the server. */
public final class ExportProjectionPublication {
    private ExportProjectionPublication() { }
    private static final String ATTRIBUTE=ExportProjectionPublication.class.getName()+".selected";
    private static final class Selected {
        final Map<String,Set<UUID>> scopes=new LinkedHashMap<>();
    }

    static void record(String allowedScope,List<UUID> ids) {
        if(ids.isEmpty() || !(RequestContextHolder.getRequestAttributes() instanceof ServletRequestAttributes attributes))return;
        HttpServletRequest request=attributes.getRequest();
        synchronized(request) {
            var value=request.getAttribute(ATTRIBUTE);
            Selected selected=value instanceof Selected existing?existing:new Selected();
            Set<UUID> previous=selected.scopes.getOrDefault(allowedScope,Set.of());
            Set<UUID> frozen=new LinkedHashSet<>(previous);frozen.addAll(List.copyOf(ids));
            int total=selected.scopes.values().stream().mapToInt(Set::size).sum()-previous.size()+frozen.size();
            if(total>160)throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"导出扩展列最多160列");
            selected.scopes.put(allowedScope,frozen);
            request.setAttribute(ATTRIBUTE,selected);
        }
    }

    /** Called after the domain proof, before response headers or bytes are published. */
    public static void verify(HttpServletRequest request,ExportProjectionAccessGuard guard) {
        List<TableColumnProjection> selected=new ArrayList<>();
        synchronized(request) {
            var value=request.getAttribute(ATTRIBUTE);
            // Retire before checking: an error dispatch cannot re-enter this publication.
            request.removeAttribute(ATTRIBUTE);
            if(!(value instanceof Selected actual))return;
            actual.scopes.forEach((scope,ids)->selected.add(new TableColumnProjection(null,scope,
                    ids.stream().map(id->new TableColumnProjection.Column("platform:"+id,null,null,null,null)).toList())));
        }
        Objects.requireNonNull(guard,"HTTP projection publication guard is required");
        for(var projection:selected)guard.verify(projection,projection.scope());
    }
}
