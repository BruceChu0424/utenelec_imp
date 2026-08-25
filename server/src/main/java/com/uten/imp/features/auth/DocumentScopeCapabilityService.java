package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.dto.DocumentScopeCapabilityDto;
import com.uten.imp.security.OwnerVisibility;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;

/** Resolves ordinary object-write scope for the current authenticated subject only. */
@Service
@RequiredArgsConstructor
public class DocumentScopeCapabilityService {

    private static final Map<String, String> VIEW_ALL_AUTHORITIES = Map.of(
            "sales", "sales:view:all",
            "finance", "finance:view:all",
            "purchase", "purchase:view:all",
            "subcontract", "subcontract:view:all",
            "production_plan", "production_plan:view:all",
            "stock_doc", "stock_doc:view:all");

    private final OwnerVisibility ownerVisibility;

    @Transactional(readOnly = true)
    public DocumentScopeCapabilityDto current(String requestedScope) {
        String scope = requestedScope == null ? "" : requestedScope.trim();
        String viewAllAuthority = VIEW_ALL_AUTHORITIES.get(scope);
        if (viewAllAuthority == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的数据范围");
        }
        var ownerScope = ownerVisibility.evaluate(scope, viewAllAuthority);
        return new DocumentScopeCapabilityDto(
                scope,
                ownerScope.seeAll(),
                ownerScope.writableOwners().stream()
                        .sorted()
                        .toList());
    }
}
