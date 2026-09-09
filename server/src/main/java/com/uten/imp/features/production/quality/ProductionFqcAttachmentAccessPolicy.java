package com.uten.imp.features.production.quality;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionView;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/** Inspection evidence is frozen at the first decision, including partial decisions. */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class ProductionFqcAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "PRODUCTION_QUALITY_INSPECTION";
    private final EntityManager em;
    private final ProductionFqcInspectionService inspections;
    private final ProductionFqcTaskAccessPolicy tasks;
    private final ProductionQualityMutationFootprintService mutations;

    @Override public String ownerType() { return OWNER_TYPE; }

    @Override public void requireCanView(UUID ownerId, AuthUser user) {
        readable(ownerId, user);
    }

    @Override public void requireCanManage(UUID ownerId, AuthUser user) {
        editable(ownerId, user);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        editable(ownerId, user);
        var guard = mutations.beginInspections(List.of(ownerId));
        List<?> locked = em.createNativeQuery("SELECT id FROM production_fqc_inspections WHERE id = :id FOR UPDATE")
                .setParameter("id", ownerId).getResultList();
        if (locked.size() != 1) throw missing();
        editable(ownerId, user);
        guard.verifyUnchanged();
    }

    private InspectionView readable(UUID id, AuthUser user) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "文件必须绑定生产质检任务");
        if (!has(user, ProductionFqcInspectionService.VIEW_AUTHORITY)) throw missing();
        return inspections.detail(id);
    }

    private void editable(UUID id, AuthUser user) {
        InspectionView value = readable(id, user);
        if (!has(user, ProductionFqcInspectionService.APPROVE_AUTHORITY)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少生产质检审批权限");
        }
        tasks.requireQualityPool("当前账号不在品质任务组织范围");
        if (!"PENDING".equals(value.status()) || value.passedQty().signum() != 0
                || value.failedQty().signum() != 0 || value.remainingQty().signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "已经登记检验结果，证据文件只读，不能替换或删除");
        }
    }

    private static boolean has(AuthUser user, String authority) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(authority));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "生产质检任务不存在"); }
}
