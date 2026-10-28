package com.uten.imp.features.subcontract.short_delivery;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SubcontractShortDeliveryNameBatchTest {
    private final EntityManager em = mock(EntityManager.class);
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final SubcontractDocumentAccessPolicy access = mock(SubcontractDocumentAccessPolicy.class);
    private final EmployeeNameResolver names = mock(EmployeeNameResolver.class);
    private final SubcontractShortDeliveryService service = new SubcontractShortDeliveryService(
            jdbc, em, null, null, null, access, null, null, null, names, new ObjectMapper());
    private final UUID owner = UUID.randomUUID();

    @BeforeEach void scope() {
        when(access.nativeReadScope("c.owner_employee_id", "owners", "subcontract_order:view"))
                .thenReturn(new NativeReadScope("c.owner_employee_id IN (:owners)", "owners", Set.of(owner)));
    }

    @Test void namesComeFromOneAuthorizedPageBatchWhileAmountsOrderAndWriteScopeStayIntact() {
        UUID decider = UUID.randomUUID(), unknown = UUID.randomUUID();
        Object[] first = row(owner, decider), second = row(owner, unknown), third = row(null, null);
        Query rows = query(), count = query();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> call.<String>getArgument(0).startsWith("SELECT COUNT(*)") ? count : rows);
        when(rows.getResultList()).thenReturn(List.of(first, second, third));
        when(count.getSingleResult()).thenReturn(300L);
        when(names.namesOf(anyCollection())).thenReturn(Map.of(owner, "负责人", decider, "已离职审核员"));
        when(access.hasAuthority(SubcontractShortDeliveryService.DECIDE_AUTHORITY)).thenReturn(true);
        when(access.canWrite(owner)).thenReturn(false);

        var result = service.list("PENDING", "原文", null, null, null, null, 2, 3);

        verify(names).namesOf(Arrays.asList(owner, decider, owner, unknown, null, null));
        verify(names, never()).nameOf(any());
        verify(rows).setParameter("owners", Set.of(owner));
        verify(count).setParameter("owners", Set.of(owner));
        verify(rows).setParameter("offset", 3L);
        verify(rows).setParameter("limit", 3);
        assertThat(result.getItems()).extracting(SubcontractShortDeliveryContracts.CaseRow::id)
                .containsExactly((UUID) first[0], (UUID) second[0], (UUID) third[0]);
        assertThat(result.getItems()).extracting(SubcontractShortDeliveryContracts.CaseRow::ownerName)
                .containsExactly("负责人", "负责人", null);
        assertThat(result.getItems()).extracting(SubcontractShortDeliveryContracts.CaseRow::decidedByName)
                .containsExactly("已离职审核员", null, null);
        assertThat(result.getItems()).allSatisfy(item -> {
            assertThat(item.canDecide()).isFalse();
            assertThat(item.orderedQty()).isEqualByComparingTo("19.000001");
            assertThat(item.shortfallQty()).isEqualByComparingTo("0.000001");
            assertThat(item.decisionNote()).isEqualTo("0001. 原文备注");
        });
        assertThat(result.getTotal()).isEqualTo(300);
    }

    @Test void emptyOrDeniedDetailDoesNotResolveAnyIdentity() {
        Query rows = query(), count = query();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> call.<String>getArgument(0).startsWith("SELECT COUNT(*)") ? count : rows);
        when(rows.getResultList()).thenReturn(List.of());
        when(count.getSingleResult()).thenReturn(0L);
        assertThat(service.list("PENDING", "", null, null, null, null, 1, 20).getItems()).isEmpty();
        assertThatThrownBy(() -> service.detail(UUID.randomUUID())).isInstanceOf(ApiException.class);
        verifyNoInteractions(names, jdbc);
    }

    @Test void headersFilterRowsAndTotalBeforePagingWithoutChangingTheOwnerBoundary() {
        Query rows = query(), count = query();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> call.<String>getArgument(0).startsWith("SELECT COUNT(*)") ? count : rows);
        when(rows.getResultList()).thenReturn(List.of());
        when(count.getSingleResult()).thenReturn(201L);
        var result = service.list("PENDING", "", null, null, null, null, 2, 50,
                "shortfallQty", "desc", null, Map.of("search.shortfallQty", ">=0.0001", "search.goodsName", "毛坯", "f.severity", "SEVERE"));
        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(value -> assertThat(value).contains(
                "c.owner_employee_id IN (:owners)", "c.shortfall_qty >= :short_header_shortfallQty",
                "short_header_goodsName", "c.severity = :short_header_severity"));
        assertThat(sql.getAllValues().getFirst()).contains("ORDER BY c.shortfall_qty DESC NULLS LAST", "OFFSET :offset LIMIT :limit");
        for (Query query : List.of(rows, count)) {
            verify(query).setParameter("owners", Set.of(owner));
            verify(query).setParameter("short_header_shortfallQty", new BigDecimal("0.0001"));
            verify(query).setParameter("short_header_goodsName", "毛坯");
        }
        verify(rows).setParameter("offset", 50L);
        assertThat(result.getTotal()).isEqualTo(201L);
        assertThat(result.getTotalPages()).isEqualTo(5);
    }

    @Test @SuppressWarnings({"unchecked", "rawtypes"})
    void detailBatchesEventActorsTogetherWithHeaderNamesAndPreservesEverySnapshot() {
        UUID decider = UUID.randomUUID(), actor = UUID.randomUUID(), caseId = UUID.randomUUID();
        Query rows = query();
        when(em.createNativeQuery(anyString())).thenReturn(rows);
        when(rows.getResultList()).thenReturn(java.util.Collections.singletonList(row(owner, decider)));
        when(names.namesOf(anyCollection())).thenReturn(Map.of(owner, "负责人", decider, "判定员", actor, "历史操作者"));
        when(jdbc.query(anyString(), any(RowMapper.class), eq(caseId))).thenAnswer(call -> {
            RowMapper<?> mapper = call.getArgument(1);
            var result = new java.util.ArrayList<>();
            for (int i = 0; i < 300; i++) {
                ResultSet record = mock(ResultSet.class);
                when(record.getObject("id", UUID.class)).thenReturn(new UUID(0, i));
                when(record.getObject("actor_employee_id", UUID.class)).thenReturn(i == 299 ? null : actor);
                when(record.getString("event_type")).thenReturn("EVENT_" + i);
                when(record.getTimestamp("created_at")).thenReturn(Timestamp.from(Instant.parse("2026-01-01T00:00:00Z")));
                when(record.getString("event_snapshot")).thenReturn("{\"raw\":\"0001. 原文\",\"qty\":\"0.000001\"}");
                result.add(mapper.mapRow(record, i));
            }
            return result;
        });

        var result = service.detail(caseId);

        assertThat(result.row().ownerName()).isEqualTo("负责人");
        assertThat(result.row().decidedByName()).isEqualTo("判定员");
        assertThat(result.events()).hasSize(300);
        assertThat(result.events().getFirst().actorName()).isEqualTo("历史操作者");
        assertThat(result.events().getLast().actorName()).isNull();
        assertThat(result.events()).allSatisfy(event -> assertThat(event.snapshot())
                .containsEntry("raw", "0001. 原文").containsEntry("qty", "0.000001"));
        assertThat(result.events()).extracting(SubcontractShortDeliveryContracts.CaseEvent::eventType)
                .containsExactlyElementsOf(java.util.stream.IntStream.range(0, 300).mapToObj(i -> "EVENT_" + i).toList());
        verify(names).namesOf(argThat(ids -> ids.size() == 302 && ids.stream().filter(actor::equals).count() == 299
                && ids.contains(owner) && ids.contains(decider) && ids.contains(null)));
        verify(names, never()).nameOf(any());
    }

    private static Query query() { return mock(Query.class, RETURNS_SELF); }
    private static Object[] row(UUID owner, UUID decider) {
        Object[] row = new Object[39];
        row[0] = UUID.randomUUID(); row[1] = UUID.randomUUID(); row[2] = "ORDER"; row[3] = UUID.randomUUID();
        row[4] = 1; row[8] = "001"; row[9] = "原文物料";
        row[14] = new BigDecimal("19.000001"); row[17] = new BigDecimal("19"); row[18] = new BigDecimal("0.000001");
        row[20] = "SEVERE"; row[21] = "PENDING_OWNER"; row[22] = "PENDING_OWNER"; row[23] = false;
        row[26] = "0001. 原文备注"; row[27] = 1; row[28] = owner; row[29] = decider; row[38] = 9L;
        return row;
    }
}
