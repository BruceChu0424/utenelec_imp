package com.uten.imp.features.sales.shipment;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.application.port.CustomerShipmentInventoryPort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesMutationFootprintService;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/** Order shipments and direct customer shipments share storage, never permissions. */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class SalesShipmentAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "SALES_SHIPMENT";
    private final EntityManager em;
    private final SalesDocumentAccessPolicy access;
    private final SalesMutationFootprintService mutations;
    private final TaskClaimMutationGuardPort claims;
    private final CustomerShipmentInventoryPort inventory;

    @Override public String ownerType() { return OWNER_TYPE; }
    @Override public void requireCanView(UUID ownerId, AuthUser user) { readable(document(ownerId), user); }
    @Override public void requireCanManage(UUID ownerId, AuthUser user) { editable(document(ownerId), user); }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        editable(document(ownerId), user);
        mutations.lockShipment(ownerId, List.of());
        SalesShipment locked = em.find(SalesShipment.class, ownerId, LockModeType.PESSIMISTIC_WRITE);
        if (locked == null) throw missing();
        em.refresh(locked, LockModeType.PESSIMISTIC_WRITE);
        editable(locked, user);
        claims.requireNoActiveClaim(CustomerShipmentPolicy.CLAIM_TYPE, ownerId.toString());
        inventory.requireNoUnreleased(ownerId);
    }

    private SalesShipment document(UUID id) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定销售出货单");
        SalesShipment document = em.find(SalesShipment.class, id);
        if (document == null || document.isDeleted()) throw missing();
        return document;
    }
    private void readable(SalesShipment document, AuthUser user) {
        boolean finance = has(user, "sales_shipment_finance:view") && enteredFinanceFlow(document);
        if (document.isDeleted() || !(has(user, permission(document, "view")) || finance
                || has(user, "warehouse_sales_outbound:view"))) throw missing();
        if (finance) {
            access.requireReadable(document.getOwnerEmployeeId(), "销售出货单不存在", "sales_shipment_finance:view");
        } else {
            access.requireReadable(document.getOwnerEmployeeId(), "销售出货单不存在",
                    "sales_shipment:reject", "warehouse_sales_outbound:view");
        }
        if (!finance && !has(user, SalesPriceMasker.PERM)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "出货原件包含商业金额，需要销售价格查看权限");
        }
    }
    private void editable(SalesShipment document, AuthUser user) {
        readable(document, user);
        if (!has(user, permission(document, "edit"))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少对应销售出货编辑权限");
        }
        access.requireWritable(document.getOwnerEmployeeId(), "无权修改该销售出货单附件");
        boolean submitted = CustomerShipmentPolicy.salesConfirmed(document) && !document.isFinanceRejected();
        if (document.getStatus() == null || document.getStatus() != 0
                || document.isClosed() || document.isRejected() || "LEGACY".equals(document.getShipmentKind())
                || !SalesShipment.WORK_PENDING_PICK.equals(document.getWarehouseWorkStatus())
                || Short.valueOf((short) 1).equals(document.getFinanceAudit()) || submitted) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "仅待销售确认或财务退回的未关闭出货草稿可修改附件，确认和拣货后原件只读");
        }
    }
    private static String permission(SalesShipment document, String action) {
        return (CustomerShipmentPolicy.direct(document) ? "sales_other_shipment:" : "sales_shipment:") + action;
    }
    private static boolean enteredFinanceFlow(SalesShipment document) {
        return CustomerShipmentPolicy.salesConfirmed(document) || document.isFinanceRejected()
                || Short.valueOf((short) 1).equals(document.getFinanceAudit())
                || Short.valueOf((short) 1).equals(document.getStatus());
    }
    private static boolean has(AuthUser user, String permission) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(permission));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "销售出货单不存在"); }
}
