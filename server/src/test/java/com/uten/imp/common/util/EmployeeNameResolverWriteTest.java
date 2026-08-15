package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Collections;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.lenient;

@ExtendWith(MockitoExtension.class)
class EmployeeNameResolverWriteTest {

    @Mock private EntityManager em;
    @Mock private Query query;

    private EmployeeNameResolver resolver;

    @BeforeEach
    void setUp() {
        resolver = new EmployeeNameResolver(em);
        lenient().when(em.createNativeQuery(anyString())).thenReturn(query);
        lenient().when(query.setMaxResults(org.mockito.ArgumentMatchers.anyInt())).thenReturn(query);
    }

    @Test
    void uuidIsAuthoritativeAndCanonicalShadowsAreReturned() {
        UUID id = UUID.randomUUID();
        when(query.setParameter("id", id)).thenReturn(query);
        when(query.getResultList()).thenReturn(rows(id, 17, "张三"));

        var result = resolver.resolveForWrite(id, 17, " 张三 ", "经办人");

        assertEquals(id, result.id());
        assertEquals(17, result.legacyId());
        assertEquals("张三", result.name());
    }

    @Test
    void uuidAndLegacyNameConflictIsRejected() {
        UUID id = UUID.randomUUID();
        when(query.setParameter("id", id)).thenReturn(query);
        when(query.getResultList()).thenReturn(rows(id, 17, "张三"));

        ApiException error = assertThrows(ApiException.class,
                () -> resolver.resolveForWrite(id, 17, "李四", "经办人"));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    @Test
    void legacyOnlyOldClientValueCannotCreateOnlineRelationship() {
        ApiException error = assertThrows(ApiException.class,
                () -> resolver.resolveForWrite(null, 23, null, "收货人"));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void nameOnlyOldClientValueCannotCreateOnlineRelationship() {
        ApiException error = assertThrows(ApiException.class,
                () -> resolver.resolveForWrite(null, null, "同名员工", "经办人"));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void absentOptionalReferenceStaysNullWithoutQueryingRows() {
        assertNull(resolver.resolveForWrite(null, null, "  ", "经办人"));
    }

    private static List<?> rows(UUID id, Integer legacyId, String name) {
        return Collections.singletonList(new Object[]{id, legacyId, name});
    }
}
