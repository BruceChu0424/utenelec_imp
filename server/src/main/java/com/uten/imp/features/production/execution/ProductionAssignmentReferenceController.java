package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.BusinessEmployeeReferenceAuthorizationPort;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/production/workshop-assignment-defaults")
@RequiredArgsConstructor
@PreAuthorize("isAuthenticated() and !principal.visitor")
public class ProductionAssignmentReferenceController {
    private static final Set<String> PURPOSES=Set.of("PRODUCTION_MATERIAL_OWNER",
            "PRODUCTION_PLAN_OWNER","PRODUCTION_SEGMENT_OWNER");
    private final BusinessEmployeeReferenceAuthorizationPort authorization;
    private final ProductionGoodsWorkshopPreferenceService preferences;

    @GetMapping
    public List<WorkshopAssignmentDefaultView> defaults(@RequestParam String purpose,
            @RequestParam Set<UUID> ids) {
        if(purpose==null || !PURPOSES.contains(purpose))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"生产指派引用场景无效");
        authorization.require(purpose);
        if(ids==null || ids.isEmpty() || ids.size()>RequestLimits.LOOKUP_IDS
                || ids.stream().anyMatch(java.util.Objects::isNull))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"车间ID数量必须为1-"+RequestLimits.LOOKUP_IDS);
        return preferences.findWorkshopAssignmentDefaults(ids);
    }
}
