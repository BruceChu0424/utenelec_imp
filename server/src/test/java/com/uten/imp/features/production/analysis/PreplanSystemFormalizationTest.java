package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class PreplanSystemFormalizationTest {
    @Test void missingSystemCapabilityCannotReleaseAnOwnedReservation() {
        Fixture f = new Fixture(false);
        assertThatThrownBy(() -> f.service.consumePhysicalForFormalize(f.source, BigDecimal.ONE, null))
                .isInstanceOf(ApiException.class).hasMessageContaining("事务凭据");
        assertThat(f.writes).isEmpty();
        assertThat(f.sql).singleElement().asString().contains(
                "app.production_readiness_reconcile", "= 'v1'", "app.actor_id",
                "app.actor_account", "系统自动核对备料", "FALSE");
    }

    @Test void loggedInPersonCannotSelectNullSystemIdentityEvenWithMarker() {
        Fixture f = new Fixture(true);
        when(f.current.get()).thenReturn(Optional.of(mock(AuthUser.class)));
        assertThatThrownBy(() -> f.service.consumePhysicalForFormalize(f.source, BigDecimal.ONE, null))
                .isInstanceOf(ApiException.class).hasMessageContaining("登录人员");
        assertThat(f.sql).isEmpty();
    }

    @Test void explicitPersonMustMatchCurrentAuthenticatedPerson() {
        Fixture f = new Fixture(true);
        when(f.current.requireId()).thenReturn(UUID.randomUUID());
        assertThatThrownBy(() -> f.service.consumePhysicalForFormalize(f.source, BigDecimal.ONE, UUID.randomUUID()))
                .isInstanceOf(ApiException.class).hasMessageContaining("不一致");
        assertThat(f.sql).isEmpty();
    }

    @Test void ordinaryReservationReleaseStillRequiresLogin() {
        Fixture f = new Fixture(true);
        when(f.current.requireId()).thenThrow(new IllegalStateException("当前无登录用户"));
        assertThatThrownBy(() -> f.service.consumePhysicalForFormalize(f.source, BigDecimal.ONE))
                .isInstanceOf(IllegalStateException.class);
        assertThat(f.writes).isEmpty();
    }

    @Test void authorizedSystemReleaseRetainsQuantityAndSourcePredicates() {
        Fixture f = new Fixture(true);
        f.service.consumePhysicalForFormalize(f.source, BigDecimal.ONE, null);
        assertThat(f.writes).singleElement().satisfies(write -> {
            assertThat(write.sql).contains("owner_type = :ownerType", "status = :effective",
                    "qty - consumed_qty - released_qty >= :qty", "TRANSFERRED_TO_PLAN");
            assertThat(write.parameters).containsEntry("actorId", null)
                    .containsEntry("id", f.source).containsEntry("qty", BigDecimal.ONE);
        });
        verify(f.current, never()).requireId();
    }

    @Test void authorizedSystemFormalizePersistsOnlyFixedReasonWithNullActor() {
        Fixture f = new Fixture(true);
        UUID id = f.formalize(new BigDecimal("2"), true);
        assertThat(id).isNotNull();
        assertThat(f.writes).singleElement().satisfies(write ->
                assertThat(write.parameters).containsEntry("eventType", "FORMALIZE")
                        .containsEntry("systemReason", "AUTOMATIC_READINESS_RECHECK")
                        .containsEntry("actorId", null));
        verify(f.current, never()).requireId();
    }

    @Test void systemFormalizationCannotExceedActualSourceLot() {
        Fixture f = new Fixture(true);
        assertThatThrownBy(() -> f.formalize(new BigDecimal("3"), true))
                .isInstanceOf(ApiException.class).hasMessageContaining("exceeds");
        assertThat(f.writes).isEmpty();
    }

    @Test void ordinaryFormalizationRetainsPersonAndNoSystemReason() {
        Fixture f = new Fixture(false); UUID person = UUID.randomUUID();
        when(f.current.requireId()).thenReturn(person);
        f.formalize(BigDecimal.ONE, false);
        assertThat(f.writes).singleElement().satisfies(write -> {
            assertThat(write.parameters).containsEntry("actorId", person).doesNotContainKey("systemReason");
            assertThat(write.sql).doesNotContain("system_reason");
        });
        assertThat(f.sql).noneMatch(sql -> sql.contains("current_setting"));
    }

    private record Write(String sql, Map<String, Object> parameters) {}

    private static final class Fixture {
        final EntityManager em = mock(EntityManager.class);
        final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        final PreplanStockEntitlementService service = new PreplanStockEntitlementService(em, current, mock(TxSessionVars.class));
        final UUID lot = UUID.randomUUID(), group = UUID.randomUUID(), source = UUID.randomUUID(),
                analysis = UUID.randomUUID(), material = UUID.randomUUID(), goods = UUID.randomUUID(), warehouse = UUID.randomUUID(),
                pkg = UUID.randomUUID(), demand = UUID.randomUUID(), target = UUID.randomUUID();
        final List<String> sql = new ArrayList<>();
        final List<Write> writes = new ArrayList<>();

        Fixture(boolean authorized) {
            when(current.get()).thenReturn(Optional.empty());
            when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
                String statement = invocation.getArgument(0); sql.add(statement);
                Query query = mock(Query.class); Map<String,Object> parameters = new HashMap<>();
                when(query.setParameter(anyString(), any())).thenAnswer(call -> {
                    parameters.put(call.getArgument(0), call.getArgument(1)); return query;
                });
                when(query.getSingleResult()).thenReturn(authorized);
                when(query.executeUpdate()).thenAnswer(call -> {writes.add(new Write(statement, new HashMap<>(parameters))); return 1;});
                when(query.getResultList()).thenAnswer(call -> {
                    if (statement.contains("WHERE idempotency_key = :key")) {
                        Map<String,Object> p = writes.getLast().parameters;
                        return List.<Object[]>of(new Object[]{p.get("id"),p.get("eventGroupId"),p.get("reservationId"),
                                p.get("analysisId"),p.get("materialId"),p.get("eventType"),p.get("qty"),p.get("sourceEventId"),
                                p.get("reallocationId"),p.get("exactPegId"),p.get("receiptType"),p.get("receiptId"),
                                p.get("dispositionEventId"),p.get("stockDocumentId"),p.get("stockDocumentItemId"),
                                p.get("packageId"),p.get("demandId"),p.get("targetReservationId"),p.get("counterEventId")});
                    }
                    return List.<Object[]>of(new Object[]{lot,group,source,analysis,material,"ORIGIN_IQC",null,null,
                            new BigDecimal("2"),goods,null,warehouse});
                });
                return query;
            });
        }

        UUID formalize(BigDecimal qty, boolean system) {
            return system
                    ? service.appendFormalize(pkg,lot,source,analysis,material,qty,pkg,demand,target,"system-proof",null)
                    : service.appendFormalize(pkg,lot,source,analysis,material,qty,pkg,demand,target,"human-proof");
        }
    }
}
