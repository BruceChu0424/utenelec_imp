package com.uten.imp.features.attachment;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.ImportedDocumentLifecycleCapabilities;
import jakarta.persistence.EntityManager;
import java.util.UUID;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

/** Keep each owner's ACL/action/locking policy, then deny writes to an archived business ancestor. */
@Aspect
@Component
@Order(Ordered.LOWEST_PRECEDENCE - 10)
public class ImportedAttachmentOwnerWriteGuard {
    private final EntityManager em;

    public ImportedAttachmentOwnerWriteGuard(EntityManager em) { this.em = em; }

    // Upload/delete are separate methods in the file-library SPI. Matching their
    // names keeps that split intact without replacing the owner's implementation.
    @Around("target(com.uten.imp.application.port.AttachmentOwnerAccessPolicy) && ("
            + "execution(* requireCanManage*(..)) || execution(* requireCanUpload*(..)) || "
            + "execution(* requireCanDelete*(..)) || execution(* requireCanSelectAvatar(..)))")
    public Object requireCurrentOwner(ProceedingJoinPoint invocation) throws Throwable {
        Object result = invocation.proceed(); // Existing read/owner/price/action checks must run first.
        var policy = (AttachmentOwnerAccessPolicy) invocation.getTarget();
        Object[] arguments = invocation.getArgs();
        if (arguments.length == 0 || !(arguments[0] instanceof UUID ownerId)) return result;
        boolean imported = Boolean.TRUE.equals(em.createNativeQuery(
                "SELECT fn_imported_business_document(fn_imported_business_document_scope_table(:ownerType),:ownerId)")
                .setParameter("ownerType", policy.ownerType()).setParameter("ownerId", ownerId).getSingleResult());
        if (imported) throw new ApiException(ErrorCode.CONFLICT, ImportedDocumentLifecycleCapabilities.READ_ONLY_REASON);
        return result;
    }
}
