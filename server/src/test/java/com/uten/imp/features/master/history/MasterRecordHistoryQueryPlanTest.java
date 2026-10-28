package com.uten.imp.features.master.history;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.DepartmentNameResolver;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

/** Executes the actual query builder; no database or copied SQL implementation. */
class MasterRecordHistoryQueryPlanTest {
  private final EntityManager em = mock(EntityManager.class);
  private final Query query = mock(Query.class, RETURNS_SELF);
  private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
  private final ClientAccessPolicy clients = mock(ClientAccessPolicy.class);
  private final OwnerVisibility owners = mock(OwnerVisibility.class);
  private final Map<String, Object> parameters = new LinkedHashMap<>();
  private String sql;
  private final MasterRecordHistoryService service = new MasterRecordHistoryService(
      em, new ObjectMapper(), current, null, clients, owners, null, null,
      Optional.empty(), Optional.empty(), null,
      mock(EmployeeNameResolver.class), mock(DepartmentNameResolver.class));

  MasterRecordHistoryQueryPlanTest() {
    when(em.createNativeQuery(anyString())).thenAnswer(call -> {
      sql = call.getArgument(0);
      return query;
    });
    when(query.setParameter(anyString(), any())).thenAnswer(call -> {
      parameters.put(call.getArgument(0), call.getArgument(1));
      return query;
    });
    when(query.getResultList()).thenReturn(List.of());
  }

  private void login(String... permissions) {
    when(current.get()).thenReturn(Optional.of(new AuthUser(
        UUID.randomUUID(), UUID.randomUUID(), "history-query-fixture",
        Set.of(permissions), false, true, false)));
  }

  @Test
  void categoryCandidatesHaveThreeUnboundedIndexableBranchesThenApplyAllOriginalAclAndFilters() {
    login("goods:view");
    UUID category = UUID.randomUUID(), owner = UUID.randomUUID(), actor = UUID.randomUUID();
    ReflectionTestUtils.setField(service, "goodsOwnerScopeEnabled", true);
    when(owners.evaluate("goods", "goods:view:all"))
        .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(owner)));
    String keyword = "needle' OR true --";
    var filters = new MasterRecordHistoryService.Filters("EDIT", actor, "operator", keyword,
        "2026-10-01", "2026-11-01", 2, "BOM", "组装");
    assertTrue(service.search("goods", null, category, 444L, filters).entries().isEmpty());

    int main = sql.indexOf("SELECT h.id");
    assertTrue(main > 0, sql);
    String candidates = sql.substring(sql.indexOf("category_history_candidates(id)"), main);
    assertEquals(3, candidates.split("SELECT v.id FROM master_record_versions v", -1).length - 1);
    assertEquals(3, candidates.split("v.id<:cursor", -1).length - 1);
    assertEquals(2, candidates.split(" UNION ", -1).length - 1);
    assertTrue(candidates.contains("v.record_id=ANY(ARRAY(SELECT id FROM selected_categories))"));
    assertTrue(candidates.contains("v.category_id=ANY(ARRAY(SELECT id FROM selected_categories))"));
    assertTrue(candidates.contains("NULLIF(v.before_row->>'category_id','')::uuid=ANY(ARRAY(SELECT id FROM selected_categories))"));
    for (String forbidden : List.of("LIMIT", "UNION ALL", ":actor", ":action", ":keyword", "r.owner_employee_id")) {
      assertFalse(candidates.contains(forbidden), "Candidate identities must not be prematurely paged or joined: " + forbidden);
    }
    String finalPage = sql.substring(main);
    assertFalse(finalPage.contains("h.before_row::text"));
    assertFalse(finalPage.contains("h.after_row::text"));
    int joined = finalPage.indexOf("JOIN master_record_versions h ON h.id=candidate.id");
    int limited = finalPage.lastIndexOf("ORDER BY h.id DESC LIMIT :limit");
    assertTrue(joined >= 0 && limited > joined);
    for (String predicate : List.of("h.entity_type IN (:entities)", "h.id<:cursor", "newer.transaction_id=h.transaction_id",
        "newer.record_id=h.record_id", "h.action=:action", "h.actor_id=:actor", "ILIKE :actorKeyword",
        "ILIKE :summaryKeyword", "h.recorded_at>=:from", "h.recorded_at<:to",
        "NOT(r.is_category AND h.entity_type IN(:hiddenCategories))", "r.owner_employee_id IN(:goodsOwners)")) {
      int position = finalPage.indexOf(predicate);
      assertTrue(position > joined && position < limited, "Final ACL/filter lost or moved after page limit: " + predicate);
    }
    assertFalse(sql.contains(keyword), "Request text must stay a bound value");
    assertEquals(List.of("goods"), parameters.get("entities"));
    assertEquals(category, parameters.get("category"));
    assertEquals(444L, parameters.get("cursor"));
    assertEquals(3, parameters.get("limit"));
    assertEquals(Set.of(owner), parameters.get("goodsOwners"));
    assertEquals(List.of("goods"), parameters.get("hiddenCategories"));
    assertEquals(actor, parameters.get("actor"));
    assertEquals("BOM", parameters.get("sourceType"));
    verifyNoInteractions(clients);
  }

  @Test
  void clientCategoryFilteringKeepsItsOwnObjectAclBeforeTheFinalLimit() {
    login("client:view", "client_category:view");
    UUID owner = UUID.randomUUID();
    when(clients.nativeReadScope(eq("r"), any())).thenReturn(new ClientAccessPolicy.NativeReadScope(
        "r.owner_employee_id IN(:clientOwners)", "clientOwners", Set.of(owner), null, null));
    service.list("clients", null, UUID.randomUUID(), null);
    int join = sql.indexOf("JOIN master_record_versions h ON h.id=candidate.id");
    assertTrue(sql.indexOf("r.owner_employee_id IN(:clientOwners)") > join);
    assertTrue(sql.indexOf("r.owner_employee_id IN(:clientOwners)") < sql.lastIndexOf("LIMIT :limit"));
    assertTrue(sql.contains("FROM clients t"));
    assertTrue(sql.contains("FROM client_categories t"));
    assertFalse(sql.contains("FROM goods t"));
    assertFalse(sql.contains("FROM suppliers t"));
    assertEquals(Set.of(owner), parameters.get("clientOwners"));
  }

  @Test
  void allEntityReadOnlyJoinsTheDomainsAllowedByTheAuthenticatedPrincipal() {
    login("goods:view", "color:view");
    service.list("all", null, null, null);
    assertEquals(List.of("colors", "goods"), parameters.get("entities"));
    assertTrue(sql.contains("FROM goods t"));
    assertTrue(sql.contains("FROM material_categories t"));
    assertTrue(sql.contains("FROM colors t"));
    for (String table : List.of("clients", "client_categories", "suppliers", "accounts", "warehouses", "moulds")) {
      assertFalse(sql.contains("FROM " + table + " t"), "Unrequested domain must not be probed: " + table);
    }
    assertFalse(sql.contains("category_history_candidates"));
    verifyNoInteractions(clients);
  }

  @Test
  void individualNonCategoryObjectKeepsTheOriginalDirectHistoryBranch() {
    login("color:view");
    UUID record = UUID.randomUUID();
    service.list("colors", record, null, 100L);
    assertTrue(sql.startsWith("SELECT h.id"));
    assertTrue(sql.contains("FROM master_record_versions h JOIN LATERAL"));
    assertTrue(sql.contains("h.record_id=:record"));
    assertTrue(sql.endsWith("ORDER BY h.id DESC LIMIT :limit"));
    assertFalse(sql.contains("selected_categories"));
    assertEquals(record, parameters.get("record"));
    assertEquals(100L, parameters.get("cursor"));
    assertEquals(51, parameters.get("limit"));
  }

  @Test
  void unsupportedCategoryAndMissingDomainAuthorityNeverReachTheDatabase() {
    login("color:view");
    assertThrows(ApiException.class, () -> service.list("colors", null, UUID.randomUUID(), null));
    assertThrows(ApiException.class, () -> service.list("all", null, UUID.randomUUID(), null));
    assertThrows(ApiException.class, () -> service.list("goods", null, null, null));
    verifyNoInteractions(em);
  }

  @Test
  void forwardIndexAddsOnlyTheTypedPreviousCategoryLookupWithoutChangingHistoryRows() throws Exception {
    String ddl = Files.readString(Path.of("src/main/resources/db/migration/V966__master_record_history_category_candidates.sql"))
        .replaceAll("(?m)--.*$", "").replaceAll("\\s+", " ").strip().toLowerCase(Locale.ROOT);
    assertTrue(ddl.startsWith("create index if not exists ix_master_versions_before_category"));
    assertTrue(ddl.contains("on public.master_record_versions"));
    assertTrue(ddl.contains("entity_type"));
    assertTrue(ddl.contains("nullif(before_row->>'category_id', '')::uuid"));
    assertTrue(ddl.contains("id desc"));
    assertEquals(1, ddl.chars().filter(character -> character == ';').count());
    for (String mutation : List.of("update ", "delete ", "insert ", "truncate ", "drop ")) {
      assertFalse(ddl.contains(mutation), "A forward read index must not rewrite existing history: " + mutation);
    }
  }
}
