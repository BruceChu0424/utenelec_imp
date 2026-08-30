package com.uten.imp.audit;

import com.uten.imp.common.web.PageResponse;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.List;
import java.util.UUID;
import java.time.OffsetDateTime;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AuditActorDirectoryTest {

    @Test
    void peopleDirectoryPagesStaffAndVisitorsWithoutSensitiveVisitorColumns() {
        EntityManager entityManager = mock(EntityManager.class);
        Query data = mock(Query.class);
        Query count = mock(Query.class);
        Query activity = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(data, count, activity);
        UUID staffId = UUID.randomUUID();
        UUID visitorId = UUID.randomUUID();
        when(data.setParameter(anyString(), anyString())).thenReturn(data);
        when(count.setParameter(anyString(), anyString())).thenReturn(count);
        when(activity.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(activity);
        when(data.setFirstResult(0)).thenReturn(data);
        when(data.setMaxResults(20)).thenReturn(data);
        when(data.getResultList()).thenReturn(List.of(
                new Object[]{staffId, "staff", "13800000000", "张三", "财务部", "会计"},
                new Object[]{visitorId, "visitor", "V123456", "李访客", "外部访客", "访客"}));
        when(count.getSingleResult()).thenReturn(2L);
        when(activity.getResultList()).thenReturn(java.util.Collections.<Object>singletonList(
                new Object[]{staffId, OffsetDateTime.parse("2026-08-29T08:00:00+08:00")}));
        AuditActorDirectory directory = new AuditActorDirectory();
        ReflectionTestUtils.setField(directory, "entityManager", entityManager);

        PageResponse<AuditActorOption> result = directory.findActors("张", 1, 20);

        assertEquals(2, result.getItems().size());
        assertEquals("张三(13800000000)", result.getItems().get(0).displayName());
        assertEquals("staff", result.getItems().get(0).actorType());
        assertEquals("李访客(V123456)", result.getItems().get(1).displayName());
        assertEquals("visitor", result.getItems().get(1).actorType());
        assertEquals("外部访客", result.getItems().get(1).department());
        assertEquals(OffsetDateTime.parse("2026-08-29T08:00:00+08:00"),
                result.getItems().get(0).lastActivityAt());
        assertNull(result.getItems().get(1).lastActivityAt());
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(entityManager, org.mockito.Mockito.times(3)).createNativeQuery(sql.capture());
        String combined = String.join(" ", sql.getAllValues()).toLowerCase();
        assertTrue(combined.contains("visitor_accounts"));
        assertTrue(combined.contains("e.code as employee_code")
                        && combined.contains("directory.employee_code"),
                "staff code must participate in people-directory keyword search");
        assertTrue(!combined.contains("phone_enc") && !combined.contains("phone_hash"));
        assertTrue(!combined.contains("visitor.status"),
                "blocked/disabled historical people must remain selectable");
        assertTrue(!combined.contains("lateral"),
                "last activity must be batched for the selected page, never per user");
    }

    @Test
    void pageActorResolutionUnderstandsBothStaffAndVisitorUuids() {
        EntityManager entityManager = mock(EntityManager.class);
        Query staff = mock(Query.class);
        Query visitor = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(staff, visitor);
        when(staff.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(staff);
        when(visitor.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(visitor);
        UUID staffId = UUID.randomUUID();
        UUID visitorId = UUID.randomUUID();
        when(staff.getResultList()).thenReturn(java.util.Collections.<Object>singletonList(
                new Object[]{staffId, "staff01", "王员工", "采购部", "采购员"}));
        when(visitor.getResultList()).thenReturn(java.util.Collections.<Object>singletonList(
                new Object[]{visitorId, "V778899", "赵访客"}));
        AuditActorDirectory directory = new AuditActorDirectory();
        ReflectionTestUtils.setField(directory, "entityManager", entityManager);

        AuditActorDirectory.Resolution resolution = directory.resolve(
                List.of(staffId, visitorId),
                List.of("staff01", "V778899"));

        assertEquals("王员工(staff01)", resolution.forActor(staffId, null).displayName());
        assertEquals("赵访客(V778899)", resolution.forActor(visitorId, null).displayName());
        assertEquals("外部访客", resolution.forActor(visitorId, null).departmentName());
    }

    @Test
    void uuidActorNeverFallsBackToAReusedMutableAccount() {
        UUID historicalId = UUID.randomUUID();
        AuditActorDirectory.ActorProfile currentOwner =
                new AuditActorDirectory.ActorProfile(
                        "shared-account", "新账号人员", "新部门", "新岗位");
        AuditActorDirectory.Resolution resolution = new AuditActorDirectory.Resolution(
                java.util.Map.of(),
                java.util.Map.of("shared-account", currentOwner));

        assertNull(resolution.forActor(historicalId, "shared-account"));
        assertEquals(currentOwner, resolution.forActor(null, "shared-account"),
                "only legacy rows without UUID may use the mutable account fallback");

        AuditLog historical = new AuditLog();
        historical.setActorId(historicalId);
        historical.setActorAccount("shared-account");
        historical.setAction("http_get");
        AuditLogRow row = AuditLogRow.of(historical, new AuditEventInterpreter(), null);
        assertEquals("历史人员", row.getActorType());
        assertEquals("shared-account(档案不可用)", row.getActorDisplay());
    }
}
