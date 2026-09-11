package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 仓库单据附件策略与 {@code StockDocService.detail} 同口径：对象范围（生产链按仓库任务
 * 范围、手工单按制单人范围）、状态门槛（红冲冻结）、更新变体行锁。
 */
class StockDocumentAttachmentAccessPolicyTest {

    private static final short DRAFT = 0;
    private static final short APPROVED = 1;
    private static final short REVERSED = -1;

    private final EntityManager em = mock(EntityManager.class);
    private final Query query = mock(Query.class);
    private final StockDocAccessPolicy access = mock(StockDocAccessPolicy.class);
    private final ProductionStockTaskAccessPolicy warehouseTasks =
            mock(ProductionStockTaskAccessPolicy.class);
    private final StockDocumentAttachmentAccessPolicy policy =
            new StockDocumentAttachmentAccessPolicy(em, access, warehouseTasks);
    private final UUID documentId = UUID.randomUUID();
    private final UUID makerId = UUID.randomUUID();

    @Test
    void otherDepartmentViewerCannotSeeProductionLinkedDocumentAttachments() {
        document(DRAFT, true);
        when(warehouseTasks.canAccessWarehouseTasks()).thenReturn(false);
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "仓库单据不存在"))
                .when(access).requireReadable(eq(makerId), anyString(), any(String[].class));
        AuthUser viewer = user("stock_doc:view");

        denied(ErrorCode.NOT_FOUND, () -> policy.requireCanView(documentId, viewer));
        denied(ErrorCode.NOT_FOUND, () -> policy.requireCanManage(documentId, viewer));
        verify(access, org.mockito.Mockito.atLeastOnce())
                .requireReadable(eq(makerId), anyString(), any(String[].class));
    }

    @Test
    void warehouseOperatorReadsProductionLinkedDocumentAcrossMakers() {
        document(APPROVED, true);
        when(warehouseTasks.canAccessWarehouseTasks()).thenReturn(true);

        assertDoesNotThrow(() -> policy.requireCanView(documentId, user("stock_doc:view", "stock_doc:issue")));
        verify(access, never()).requireReadable(any(), anyString(), any(String[].class));
    }

    @Test
    void reversedDocumentFreezesAttachmentsButStaysReadable() {
        document(REVERSED, true);
        when(warehouseTasks.canAccessWarehouseTasks()).thenReturn(true);
        AuthUser operator = user("stock_doc:view", "stock_doc:approve", "stock_doc:issue");

        assertDoesNotThrow(() -> policy.requireCanView(documentId, operator));
        denied(ErrorCode.CONFLICT, () -> policy.requireCanManage(documentId, operator));
        denied(ErrorCode.CONFLICT, () -> policy.requireCanManageForUpdate(documentId, operator));
        verify(warehouseTasks, never()).requireWarehouseTaskAccess(anyString());
    }

    @Test
    void draftUploadIsAllowedAndUpdateVariantLocksTheRow() {
        document(DRAFT, true);
        when(warehouseTasks.canAccessWarehouseTasks()).thenReturn(true);
        AuthUser operator = user("stock_doc:view", "stock_doc:approve", "stock_doc:issue");

        assertDoesNotThrow(() -> policy.requireCanManage(documentId, operator));
        assertDoesNotThrow(() -> policy.requireCanManageForUpdate(documentId, operator));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.times(2)).createNativeQuery(sql.capture());
        assertFalse(sql.getAllValues().get(0).contains("FOR UPDATE"), "普通校验不锁行");
        assertTrue(sql.getAllValues().get(1).trim().endsWith("FOR UPDATE"), "更新变体在行锁后重读状态");
        verify(warehouseTasks, org.mockito.Mockito.times(2)).requireWarehouseTaskAccess(anyString());
        verify(access, never()).requireWritable(any(), anyString(), any(String[].class));
    }

    @Test
    void approvedManualDocumentRequiresMakerWritableScope() {
        document(APPROVED, false);
        AuthUser operator = user("stock_doc:view", "stock_doc:issue");

        assertDoesNotThrow(() -> policy.requireCanManage(documentId, operator));
        verify(access).requireReadable(eq(makerId), anyString(), any(String[].class));
        verify(access).requireWritable(eq(makerId), anyString(), any(String[].class));
        verify(warehouseTasks, never()).requireWarehouseTaskAccess(anyString());

        doThrow(new ApiException(ErrorCode.FORBIDDEN, "无权"))
                .when(access).requireWritable(eq(makerId), anyString(), any(String[].class));
        denied(ErrorCode.FORBIDDEN, () -> policy.requireCanManage(documentId, operator));
    }

    @Test
    void viewerWithoutOperatorAuthorityCannotManage() {
        document(APPROVED, false);

        assertDoesNotThrow(() -> policy.requireCanView(documentId, user("stock_doc:view")));
        denied(ErrorCode.FORBIDDEN, () -> policy.requireCanManage(documentId, user("stock_doc:view")));
        verify(access, never()).requireWritable(any(), anyString(), any(String[].class));
    }

    @Test
    void missingViewPermissionOrOwnerHidesExistence() {
        denied(ErrorCode.NOT_FOUND, () -> policy.requireCanView(documentId, user()));
        denied(ErrorCode.NOT_FOUND, () -> policy.requireCanView(null, user("stock_doc:view")));
        verifyNoInteractions(em, access, warehouseTasks);

        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        denied(ErrorCode.NOT_FOUND, () -> policy.requireCanView(documentId, user("stock_doc:view")));
        assertEquals("STOCK_DOCUMENT", policy.ownerType());
    }

    private void document(short status, boolean productionLinked) {
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        // 单行 Object[]（List.of(Object[]) 会把数组当成 varargs 拆成三个元素）。
        List<Object[]> rows = Collections.singletonList(
                new Object[]{status, makerId, productionLinked});
        when(query.getResultList()).thenReturn(rows);
    }

    private static AuthUser user(String... permissions) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "warehouse-user",
                Set.of(), Set.of(permissions), false, true, false);
    }

    private static void denied(ErrorCode code, Runnable action) {
        assertEquals(code, assertThrows(ApiException.class, action::run).getCode());
    }
}
