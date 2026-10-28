package com.uten.imp.features.master.history;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.util.DepartmentNameResolver;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.goods.history.GoodsOperationHistoryService;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.lifecycle.MasterReferenceGuard;
import com.uten.imp.features.master.warehouse.WarehouseMasterRules;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.*;
import java.util.*;
import java.util.function.Supplier;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MasterRecordHistoryPostgresTest {
  static MigratedSchemaBaseline.ScopedDatabase database;
  static EntityManagerFactory factory;
  EntityManager em;
  UUID actor;
  SecurityContextCurrentUser current;
  MasterRecordHistoryService service;
  TxSessionVars tx;
  ClientAccessPolicy clientPolicy;
  MasterOperationHistoryService history;
  GoodsOperationHistoryService goodsHistory;
  BusinessEventPublisher events;

  @BeforeAll
  static void start() throws Exception {
    database = MigratedSchemaBaseline.openDatabase("master_record_history");
    var bean = new LocalContainerEntityManagerFactoryBean();
    bean.setDataSource(
        new DriverManagerDataSource(
            database.getJdbcUrl(), database.getUsername(), database.getPassword()));
    bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
    bean.setPackagesToScan("com.uten.imp.security");
    bean.setJpaPropertyMap(
        Map.of("hibernate.hbm2ddl.auto", "none", "hibernate.generate_statistics", "true"));
    bean.afterPropertiesSet();
    factory = bean.getObject();
  }

  @AfterAll
  static void stop() throws Exception {
    if (factory != null) factory.close();
    if (database != null) database.close();
  }

  @BeforeEach
  void prepare() {
    actor = UUID.randomUUID();
    em = factory.createEntityManager();
    current = mock(SecurityContextCurrentUser.class);
    login(Set.of(), true);
    when(current.requireId()).thenAnswer(call -> actor);
    tx = mock(TxSessionVars.class);
    doAnswer(
            call -> {
              provenance();
              return null;
            })
        .when(tx)
        .bind();
    var access = mock(MasterObjectAccess.class);
    when(access.readableLabelOwner(anyString())).thenReturn(owner -> true);
    clientPolicy = mock(ClientAccessPolicy.class);
    when(clientPolicy.canRead(any(UUID.class), nullable(UUID.class), any())).thenReturn(true);
    when(clientPolicy.canWrite(any(UUID.class), nullable(UUID.class), any())).thenReturn(true);
    when(clientPolicy.nativeReadScope(anyString(), any()))
        .thenReturn(new ClientAccessPolicy.NativeReadScope("1=1", null, Set.of(), null, null));
    history =
        new MasterOperationHistoryService(
            em,
            new ObjectMapper(),
            current,
            tx,
            clientPolicy,
            new MasterReferenceGuard(em, access),
            new WarehouseMasterRules(em));
    events = mock(BusinessEventPublisher.class);
    goodsHistory =
        new GoodsOperationHistoryService(
            em,
            new ObjectMapper(),
            current,
            tx,
            new MasterReferenceGuard(em, access),
            mock(OwnerVisibility.class),
            events);
    service =
        new MasterRecordHistoryService(
            em,
            new ObjectMapper(),
            current,
            tx,
            clientPolicy,
            mock(OwnerVisibility.class),
            history,
            goodsHistory,
            Optional.empty(),
            Optional.empty(),
            events,
            new EmployeeNameResolver(em),
            new DepartmentNameResolver(em));
  }

  @AfterEach
  void close() {
    if (em.getTransaction().isActive()) em.getTransaction().rollback();
    em.close();
  }

  @Test
  void customerFinancialVersionRestoreRequiresCurrentFinancePermission() {
    UUID client=UUID.randomUUID();
    inTx(()->{
      em.createNativeQuery("INSERT INTO clients(id,code,name,status,credit_floor,code_sequence) VALUES(:id,:code,'financial history customer','使用',100,(SELECT coalesce(max(code_sequence),0)+1 FROM clients))")
          .setParameter("id",client).setParameter("code","H-"+client).executeUpdate();
      return null;
    });
    inTx(()->{
      provenance();
      em.createNativeQuery("UPDATE clients SET credit_floor=200 WHERE id=:id")
          .setParameter("id",client).executeUpdate();
      return null;
    });
    login(Set.of("client:view","client:edit"),false);
    var revision=service.detail("clients",historyNumber(service.list("clients",client,null,null).entries().getFirst().id()));
    assertFalse(revision.canRestoreBefore());
    assertTrue(revision.blockedReason().contains("财务"));
    assertThrows(ApiException.class,()->inTx(()->{
      service.restore("clients",historyNumber(revision.id()),revision.expectedHead(),true);
      return null;
    }));
    assertEquals("true",value("SELECT (credit_floor=200)::text FROM clients WHERE id=:id",client));
    login(Set.of("client:view","client:edit","client:finance"),false);
    var permitted=service.detail("clients",historyNumber(revision.id()));
    assertTrue(permitted.canRestoreBefore(),permitted.blockedReason());
    inTx(()->{
      service.restore("clients",historyNumber(permitted.id()),permitted.expectedHead(),true);
      return null;
    });
    assertEquals("true",value("SELECT (credit_floor=100)::text FROM clients WHERE id=:id",client));
  }

  @Test
  void anotherActorCanReadTheExactDiffAndRestoreAnOlderVersionAsANewFact() {
    UUID id = color("original");
    edit(id, "first");
    var first = entry(id);
    edit(id, "second");
    actor = UUID.randomUUID();
    login(Set.of("color:view", "color:edit"), false);
    var history = service.list("colors", id, null, null);
    assertEquals(3, history.entries().size());
    var older =
        detail(
            "colors",
            history.entries().stream()
                .filter(e -> e.id().equals(first.id()))
                .findFirst()
                .orElseThrow());
    assertTrue(
        older.changes().stream()
            .anyMatch(
                c ->
                    c.field().equals("name")
                        && c.beforeValue().equals("original")
                        && c.afterValue().equals("first")));
    inTx(
        () -> {
          service.restore("colors", historyNumber(older.id()), older.expectedHead(), true);
          return null;
        });
    assertEquals("original", value("SELECT name FROM colors WHERE id=:id", id));
    assertEquals("RESTORE", entry(id).action());
    assertEquals("operator-" + actor, entry(id).actorName());
    verifyNoInteractions(events);
  }

  @Test
  void viewPermissionDoesNotPermitRestoreAndAStaleHeadNeverOverwritesNewChanges() {
    UUID id = color("original");
    edit(id, "first");
    var first = entry(id);
    login(Set.of("color:view"), false);
    assertFalse(entry(id).canRestoreBefore());
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore("colors", historyNumber(first.id()), first.expectedHead(), true);
                  return null;
                }));
    login(Set.of("color:view", "color:edit"), false);
    edit(id, "later");
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore("colors", historyNumber(first.id()), first.expectedHead(), true);
                  return null;
                }));
    assertEquals("later", value("SELECT name FROM colors WHERE id=:id", id));
  }

  @Test
  void returningToBeforeCreationSoftDeletesTheNewIdentityAndRequiresCurrentDeletePermission() {
    UUID id = color("new identity");
    var creation = entry(id);
    assertEquals("CREATE", creation.action());
    assertTrue(creation.canRestoreBefore(), creation.blockedReason());
    login(Set.of("color:view", "color:edit"), false);
    var denied = service.detail("colors", historyNumber(creation.id()));
    assertFalse(denied.canRestoreBefore());
    assertTrue(denied.blockedReason().contains("删除权限"));
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore(
                      "colors", historyNumber(denied.id()), denied.expectedHead(), true);
                  return null;
                }));
    assertEquals("false", value("SELECT is_deleted::text FROM colors WHERE id=:id", id));
    login(Set.of("color:view", "color:edit", "color:delete"), false);
    var allowed = service.detail("colors", historyNumber(creation.id()));
    assertTrue(allowed.canRestoreBefore(), allowed.blockedReason());
    inTx(
        () -> {
          service.restore("colors", historyNumber(allowed.id()), allowed.expectedHead(), true);
          return null;
        });
    assertEquals("true", value("SELECT is_deleted::text FROM colors WHERE id=:id", id));
    assertEquals("RESTORE", entry(id).action());
  }

  @Test
  void deletingANewGoodsVersionDoesNotInventAMissingToNullPriceOrCostChange() {
    UUID id = goods("created without financial values");
    login(Set.of("goods:view", "goods:edit", "goods:delete"), false);
    var creation = detail("goods", service.list("goods", id, null, null).entries().getFirst());
    assertTrue(creation.canRestoreBefore(), creation.blockedReason());
    inTx(
        () -> {
          service.restore("goods", historyNumber(creation.id()), creation.expectedHead(), true);
          return null;
        });
    assertEquals("true", value("SELECT is_deleted::text FROM goods WHERE id=:id", id));
  }

  @Test
  void creationDifferencesSkipEmptyAndTechnicalValuesAndUseBusinessFieldLabels() {
    UUID category = UUID.randomUUID(), client = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO client_categories(id,code,name) VALUES(:id,:code,'history customer"
                      + " group')")
              .setParameter("id", category)
              .setParameter("code", "C-" + category)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO"
                      + " clients(id,code,name,category_id,code_sequence,client_rank,client_xz,credit)"
                      + " VALUES(:id,:code,'clear customer',:category,(SELECT"
                      + " COALESCE(max(code_sequence),0)+1 FROM clients),'A','内销',500)")
              .setParameter("id", client)
              .setParameter("code", "K-" + client)
              .setParameter("category", category)
              .executeUpdate();
          return null;
        });
    var created =
        detail("clients", service.list("clients", client, null, null).entries().getFirst());
    assertTrue(
        created.changes().stream()
            .noneMatch(c -> c.beforeValue().isBlank() && c.afterValue().isBlank()));
    assertTrue(
        created.changes().stream()
            .noneMatch(
                c ->
                    Set.of("access_version", "version", "code_sequence", "path")
                        .contains(c.field())));
    assertTrue(
        created.changes().stream()
            .anyMatch(c -> c.field().equals("client_rank") && c.label().equals("客户等级")));
    assertTrue(
        created.changes().stream()
            .anyMatch(c -> c.field().equals("client_xz") && c.label().equals("客户性质")));
    assertTrue(
        created.changes().stream()
            .anyMatch(c -> c.field().equals("credit") && c.label().equals("信用额度")));
    assertTrue(
        created.changes().stream()
            .noneMatch(c -> c.label().contains("_") || c.label().equals(c.field())));
  }

  @Test
  void accountReceiptAndPaymentTotalsRequireTheBalanceViewPermission() {
    UUID account = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO accounts(id,code,name,status) VALUES(:id,:code,'private"
                      + " totals','禁用')")
              .setParameter("id", account)
              .setParameter("code", "A-" + account)
              .executeUpdate();
          return null;
        });
    inTx(
        () -> {
          em.createNativeQuery(
                  "UPDATE accounts SET"
                      + " receipts_total=765432,payments_total=654321,balance_current=111111 WHERE"
                      + " id=:id")
              .setParameter("id", account)
              .executeUpdate();
          return null;
        });
    login(Set.of("account:view"), false);
    var masked =
        detail("accounts", service.list("accounts", account, null, null).entries().getFirst());
    assertTrue(masked.changes().isEmpty());
    login(Set.of("account:view", "account:balance:view"), false);
    var visible = service.detail("accounts", historyNumber(masked.id()));
    assertTrue(
        visible.changes().stream()
            .anyMatch(c -> c.field().equals("receipts_total") && c.label().equals("累计收款")));
    assertTrue(
        visible.changes().stream()
            .anyMatch(c -> c.field().equals("payments_total") && c.label().equals("累计付款")));
  }

  @Test
  void accountHistoryUsesItsOwnCurrencyAndSubjectLabelsWithoutExposingTheirDirectories() {
    UUID account = UUID.randomUUID(), style = UUID.randomUUID(), currency = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO payment_styles(id,code,name,category,status)"
                      + " VALUES(:id,:code,'historic subject','ACCOUNT','使用')")
              .setParameter("id", style)
              .setParameter("code", "P-" + style)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO currencies(id,code,name,exchange_rate,status)"
                      + " VALUES(:id,:code,'display currency',1,'使用')")
              .setParameter("id", currency)
              .setParameter("code", "C-" + currency)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO accounts(id,code,name,status,style_id,currency_id)"
                      + " VALUES(:id,:code,'own account','禁用',:style,:currency)")
              .setParameter("id", account)
              .setParameter("code", "A-" + account)
              .setParameter("style", style)
              .setParameter("currency", currency)
              .executeUpdate();
          return null;
        });
    login(Set.of("account:view"), false);
    var created =
        detail("accounts", service.list("accounts", account, null, null).entries().getFirst());
    assertTrue(
        created.changes().stream()
            .anyMatch(
                c -> c.field().equals("style_id") && c.afterValue().contains("historic subject")));
    assertTrue(
        created.changes().stream()
            .anyMatch(
                c ->
                    c.field().equals("currency_id")
                        && c.afterValue().contains("display currency")));
    assertThrows(ApiException.class, () -> service.list("currencies", null, null, null));
    assertThrows(ApiException.class, () -> service.list("payment-styles", null, null, null));
  }

  @Test
  void aCustomerOwnerUsesTheExistingPublicEmployeeNameProjection() {
    UUID employee = UUID.randomUUID(), customer = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO"
                      + " employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)"
                      + " SELECT :id,:code,'公开业务员','其他',id,current_date,'active','regular' FROM"
                      + " departments WHERE code='DEPT_FIN' LIMIT 1")
              .setParameter("id", employee)
              .setParameter("code", "E-" + employee)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO clients(id,code,name,code_sequence,owner_employee_id)"
                      + " VALUES(:id,:code,'owned customer',(SELECT"
                      + " COALESCE(max(code_sequence),0)+1 FROM clients),:owner)")
              .setParameter("id", customer)
              .setParameter("code", "K-" + customer)
              .setParameter("owner", employee)
              .executeUpdate();
          return null;
        });
    login(Set.of("client:view"), false);
    var created =
        detail("clients", service.list("clients", customer, null, null).entries().getFirst());
    assertTrue(
        created.changes().stream()
            .anyMatch(
                c ->
                    c.field().equals("owner_employee_id")
                        && c.afterValue().contains("公开业务员")
                        && c.afterValue().contains("E-" + employee)));
    assertTrue(
        created.changes().stream()
            .noneMatch(c -> c.label().contains("_") || c.afterValue().equals(employee.toString())));
  }

  @Test
  void anEmptyExtensionCellDoesNotBecomeAnUnchangedCreationDifference() {
    UUID item = goods("empty extension"), definition = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO"
                      + " platform_column_definitions(id,scope,name,normalized_name,value_type,price_protected,definition_fingerprint,created_by)"
                      + " VALUES(:id,'master_goods','optional note','optional"
                      + " note','TEXT',false,:fingerprint,:actor)")
              .setParameter("id", definition)
              .setParameter("fingerprint", definition.toString())
              .setParameter("actor", actor)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO"
                      + " platform_record_fields(scope,record_id,cells,created_by,updated_by,retain_on_reset)"
                      + " VALUES('master_goods',:id,CAST(:cells AS jsonb),:actor,:actor,true)")
              .setParameter("id", item)
              .setParameter("cells", "[{\"columnId\":\"" + definition + "\",\"value\":null}]")
              .setParameter("actor", actor)
              .executeUpdate();
          return null;
        });
    var selected = detail("goods", service.list("goods", item, null, null).entries().getFirst());
    assertTrue(selected.changes().isEmpty());
    assertFalse(selected.canRestoreBefore());
    assertFalse(selected.canRestoreAfter());
    assertTrue(selected.blockedReason().contains("已经与此版本一致"));
  }

  @Test
  void softDeletionCanBeRecoveredAndEvidenceCannotBeRewrittenOrTruncated() {
    UUID id = color("retained");
    inTx(
        () -> {
          provenance();
          em.createNativeQuery("UPDATE colors SET is_deleted=true,deleted_at=now() WHERE id=:id")
              .setParameter("id", id)
              .executeUpdate();
          return null;
        });
    var deletion = entry(id);
    assertEquals("DELETE", deletion.action());
    inTx(
        () -> {
          service.restore("colors", historyNumber(deletion.id()), deletion.expectedHead(), true);
          return null;
        });
    assertEquals("false", value("SELECT is_deleted::text FROM colors WHERE id=:id", id));
    assertThrows(
        RuntimeException.class,
        () ->
            inTx(
                () -> {
                  em.createNativeQuery(
                          "UPDATE master_record_versions SET actor_name='changed' WHERE"
                              + " record_id=:id")
                      .setParameter("id", id)
                      .executeUpdate();
                  return null;
                }));
    assertThrows(
        RuntimeException.class,
        () ->
            inTx(
                () -> {
                  em.createNativeQuery("TRUNCATE master_record_versions").executeUpdate();
                  return null;
                }));
  }

  @Test
  void aLowerAllocatedFactCommittedLateInvalidatesTheWholeObjectToken() {
    UUID supplier = UUID.randomUUID(), first = UUID.randomUUID(), second = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO suppliers(id,code,name,status,code_sequence)"
                      + " VALUES(:id,:code,'concurrent supplier','使用',(SELECT"
                      + " COALESCE(max(code_sequence),0)+1 FROM suppliers))")
              .setParameter("id", supplier)
              .setParameter("code", "S-" + supplier)
              .executeUpdate();
          for (UUID address : List.of(first, second))
            em.createNativeQuery(
                    "INSERT INTO party_addresses(id,party_type,party_id,address)"
                        + " VALUES(:id,'SUPPLIER',:party,'original address')")
                .setParameter("id", address)
                .setParameter("party", supplier)
                .executeUpdate();
          return null;
        });
    EntityManager writer = factory.createEntityManager();
    writer.getTransaction().begin();
    try {
      writer
          .createNativeQuery(
              "UPDATE party_addresses SET address='late committed address' WHERE id=:id")
          .setParameter("id", first)
          .executeUpdate();
      inTx(
          () -> {
            em.createNativeQuery(
                    "UPDATE party_addresses SET address='newer committed address' WHERE id=:id")
                .setParameter("id", second)
                .executeUpdate();
            return null;
          });
      var selected =
          detail("suppliers", service.list("suppliers", supplier, null, null).entries().getFirst());
      writer.getTransaction().commit();
      var refreshed = service.detail("suppliers", historyNumber(selected.id()));
      assertEquals(selected.expectedHead().split(":")[1], refreshed.expectedHead().split(":")[1]);
      assertNotEquals(
          selected.expectedHead(),
          refreshed.expectedHead(),
          "A late lower sequence must still invalidate CAS");
      assertThrows(
          ApiException.class,
          () ->
              inTx(
                  () -> {
                    service.restore(
                        "suppliers", historyNumber(selected.id()), selected.expectedHead(), true);
                    return null;
                  }));
      assertEquals(
          "late committed address",
          value("SELECT address FROM party_addresses WHERE id=:id", first));
      assertEquals(
          "newer committed address",
          value("SELECT address FROM party_addresses WHERE id=:id", second));
    } finally {
      if (writer.getTransaction().isActive()) writer.getTransaction().rollback();
      writer.close();
    }
  }

  @Test
  @org.junit.jupiter.api.Timeout(10)
  void anInFlightReferenceWriterIsRejectedBeforeAnyRestoreWrites() {
    UUID item = color("before reference lock");
    edit(item, "after reference lock");
    var selected = entry(item);
    EntityManager writer = factory.createEntityManager();
    writer.getTransaction().begin();
    try {
      writer
          .createNativeQuery("SELECT id FROM colors WHERE id=:id FOR KEY SHARE")
          .setParameter("id", item)
          .getResultList();
      long started = System.nanoTime();
      assertThrows(
          ApiException.class,
          () ->
              inTx(
                  () -> {
                    service.restore(
                        "colors", historyNumber(selected.id()), selected.expectedHead(), true);
                    return null;
                  }));
      System.out.println(
          "MASTER_HISTORY_RESTORE_REFERENCE_BUSY elapsedMs="
              + (System.nanoTime() - started) / 1_000_000);
      assertEquals("after reference lock", value("SELECT name FROM colors WHERE id=:id", item));
    } finally {
      writer.getTransaction().rollback();
      writer.close();
    }
  }

  @Test
  void relatedRowsFromOneCommandAreRestoredAtomicallyAndLaterPrimaryChoicesArePreserved() {
    UUID supplier = UUID.randomUUID(), address = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO suppliers(id,code,name,status,code_sequence)"
                      + " VALUES(:id,:code,'supplier','使用',(SELECT COALESCE(max(code_sequence),0)+1"
                      + " FROM suppliers))")
              .setParameter("id", supplier)
              .setParameter("code", "S-" + supplier)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO party_addresses(id,party_type,party_id,address,is_default)"
                      + " VALUES(:id,'SUPPLIER',:party,'retained address',true)")
              .setParameter("id", address)
              .setParameter("party", supplier)
              .executeUpdate();
          return null;
        });
    inTx(
        () -> {
          provenance();
          em.createNativeQuery("DELETE FROM party_addresses WHERE id=:id")
              .setParameter("id", address)
              .executeUpdate();
          return null;
        });
    var deletion =
        detail("suppliers", service.list("suppliers", supplier, null, null).entries().getFirst());
    inTx(
        () -> {
          service.restore("suppliers", historyNumber(deletion.id()), deletion.expectedHead(), true);
          return null;
        });
    assertEquals(
        "retained address", value("SELECT address FROM party_addresses WHERE id=:id", address));
    inTx(
        () -> {
          provenance();
          em.createNativeQuery("DELETE FROM party_addresses WHERE id=:id")
              .setParameter("id", address)
              .executeUpdate();
          return null;
        });
    var secondDeletion =
        detail("suppliers", service.list("suppliers", supplier, null, null).entries().getFirst());
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO party_addresses(party_type,party_id,address,is_default)"
                      + " VALUES('SUPPLIER',:id,'later address',true)")
              .setParameter("id", supplier)
              .executeUpdate();
          return null;
        });
    var fresh =
        detail(
            "suppliers",
            service.list("suppliers", supplier, null, null).entries().stream()
                .filter(e -> e.id().equals(secondDeletion.id()))
                .findFirst()
                .orElseThrow());
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore(
                      "suppliers", historyNumber(fresh.id()), fresh.expectedHead(), true);
                  return null;
                }));
    assertEquals(
        0,
        em.createNativeQuery("SELECT id FROM party_addresses WHERE id=:id")
            .setParameter("id", address)
            .getResultList()
            .size());
  }

  @Test
  void systemChangesWithoutAnHttpRequestAreCapturedAndPageCursorsStayBounded() {
    UUID id = color("system");
    for (int i = 0; i < 54; i++) {
      final int number = i;
      inTx(
          () -> {
            em.createNativeQuery("UPDATE colors SET name=:name WHERE id=:id")
                .setParameter("name", "system " + number)
                .setParameter("id", id)
                .executeUpdate();
            return null;
          });
    }
    var statistics = factory.unwrap(org.hibernate.SessionFactory.class).getStatistics();
    statistics.clear();
    long started = System.nanoTime();
    var first = service.list("colors", id, null, null);
    assertEquals(50, first.entries().size());
    assertNotNull(first.nextCursor());
    assertEquals(
        1,
        statistics.getPrepareStatementCount(),
        "The 50-entry summary must not issue per-entry queries");
    System.out.println(
        "MASTER_HISTORY_SUMMARY_50 elapsedMs="
            + (System.nanoTime() - started) / 1_000_000
            + " statements="
            + statistics.getPrepareStatementCount());
    var second = service.list("colors", id, null, historyNumber(first.nextCursor()));
    assertEquals(5, second.entries().size());
    assertNull(second.nextCursor());
    assertTrue(
        second.entries().stream()
            .noneMatch(e -> first.entries().stream().anyMatch(f -> f.id().equals(e.id()))));
  }

  @Test
  void currentObjectScopeAndWhitelistedDomainAreEnforced() {
    assertThrows(
        ApiException.class, () -> service.list("colors;DROP TABLE colors", null, null, null));
    UUID id = color("visible");
    login(Set.of(), false);
    assertThrows(ApiException.class, () -> service.list("colors", id, null, null));
  }

  @Test
  void unifiedFiltersUseAuthorisedPublicMetadataAndNeverSearchProtectedRawValues() {
    UUID item = color("needle display name");
    edit(item, "needle revised name");
    var filter =
        new MasterRecordHistoryService.Filters(
            "EDIT", null, "operator-", "needle", "2000-01-01", "2100-01-01", 50);
    var page = service.search("colors", item, null, null, filter);
    assertEquals(1, page.entries().size());
    var entry = page.entries().getFirst();
    assertEquals("colors", entry.entityType());
    assertEquals("needle revised name", entry.recordLabel());
    assertFalse(entry.recordCode().isBlank());
    assertEquals(actor, entry.actorId());
    assertTrue(entry.summary().contains("修改"));
    assertEquals(1, service.search("colors", item, null, null,
        new MasterRecordHistoryService.Filters("EDIT", null, null, null, null, null, 50,
            "RECORD", "修改")).entries().size());
    assertTrue(service.search("colors", item, null, null,
        new MasterRecordHistoryService.Filters(null, null, null, null, null, null, 50,
            "CATEGORY", null)).entries().isEmpty());
    assertTrue(
        service
            .search(
                "colors",
                item,
                null,
                null,
                new MasterRecordHistoryService.Filters("DELETE", null, null, null, null, null, 50))
            .entries()
            .isEmpty());
    assertThrows(
        ApiException.class,
        () ->
            service.search(
                "colors",
                item,
                null,
                null,
                new MasterRecordHistoryService.Filters(
                    null, null, null, null, "not-a-date", null, 50)));
    UUID priced = goods("protected amount");
    inTx(
        () -> {
          em.createNativeQuery("UPDATE goods SET price=885521.17 WHERE id=:id")
              .setParameter("id", priced)
              .executeUpdate();
          return null;
        });
    login(Set.of("goods:view"), false);
    assertTrue(service.search("goods", priced, null, null,
        new MasterRecordHistoryService.Filters(null, null, null, null, null, null, 50,
            null, "885521.17")).entries().isEmpty());
    assertTrue(
        service
            .search(
                "goods",
                priced,
                null,
                null,
                new MasterRecordHistoryService.Filters(
                    null, null, null, "885521.17", null, null, 50))
            .entries()
            .isEmpty());
    login(Set.of("color:view"), false);
    assertTrue(
        service
            .search(null, null, null, null, MasterRecordHistoryService.Filters.defaults())
            .entries()
            .stream()
            .allMatch(e -> e.entityType().equals("colors")));
  }

  @Test
  void indexedCategoryCandidatesRetainDescendantsMovedOutFactsAndExactCursorPagesWithoutDuplicates() {
    UUID root = queryCategory(null, "root"), child = queryCategory(root, "child");
    UUID outside = queryCategory(null, "outside");
    UUID inside = goods("category candidate inside"), moved = goods("category candidate moved");
    UUID unrelated = goods("category candidate unrelated");
    inTx(() -> {
      provenance();
      for (UUID id : List.of(inside, moved)) {
        em.createNativeQuery("UPDATE goods SET category_id=:category WHERE id=:id")
            .setParameter("category", child).setParameter("id", id).executeUpdate();
      }
      em.createNativeQuery("UPDATE goods SET category_id=:category WHERE id=:id")
          .setParameter("category", outside).setParameter("id", unrelated).executeUpdate();
      return null;
    });
    inTx(() -> {
      provenance();
      em.createNativeQuery("UPDATE goods SET name='category candidate inside edited' WHERE id=:id")
          .setParameter("id", inside).executeUpdate();
      return null;
    });
    long overlappingVersion = ((Number) em.createNativeQuery(
        "SELECT max(id) FROM master_record_versions WHERE entity_type='goods' AND record_id=:id")
        .setParameter("id", inside).getSingleResult()).longValue();
    inTx(() -> {
      provenance();
      em.createNativeQuery("UPDATE goods SET category_id=:category WHERE id=:id")
          .setParameter("category", outside).setParameter("id", moved).executeUpdate();
      return null;
    });
    long movedVersion = ((Number) em.createNativeQuery("""
        SELECT id FROM master_record_versions WHERE entity_type='goods' AND record_id=:id
          AND before_row->>'category_id'=:before AND after_row->>'category_id'=:after
        ORDER BY id DESC LIMIT 1
        """).setParameter("id", moved).setParameter("before", child.toString())
        .setParameter("after", outside.toString()).getSingleResult()).longValue();

    // Independent reference: the original OR predicate and transaction collapse,
    // with no candidate CTE or new planner strategy copied into the expectation.
    List<?> original = em.createNativeQuery("""
        SELECT h.id FROM master_record_versions h WHERE h.entity_type='goods'
          AND (h.record_id IN(:categories) OR h.category_id IN(:categories)
            OR NULLIF(h.before_row->>'category_id','')::uuid IN(:categories))
          AND NOT EXISTS(SELECT 1 FROM master_record_versions newer
            WHERE newer.transaction_id=h.transaction_id AND newer.record_id=h.record_id
              AND newer.entity_type=h.entity_type AND newer.id>h.id)
        ORDER BY h.id DESC
        """).setParameter("categories", Set.of(root, child)).getResultList();
    List<Long> expected = original.stream().map(value -> ((Number) value).longValue()).toList();
    assertTrue(expected.size() >= 6, "Root/child and both eras of object history must be retained");
    login(Set.of("goods:view", "material_category:view"), false);
    var whole = service.search("goods", null, root, null,
        new MasterRecordHistoryService.Filters(null, null, null, null, null, null, 100));
    assertEquals(expected, whole.entries().stream().map(entry -> historyNumber(entry.id())).toList());
    assertTrue(whole.entries().stream().anyMatch(entry -> entry.recordId().equals(root)));
    assertTrue(whole.entries().stream().anyMatch(entry -> entry.recordId().equals(child)));
    assertFalse(whole.entries().stream().anyMatch(entry -> entry.recordId().equals(unrelated)));
    assertEquals(1, whole.entries().stream().filter(entry -> historyNumber(entry.id()) == overlappingVersion).count(),
        "A fact matching current and previous category branches must occur once");
    assertTrue(whole.entries().stream().anyMatch(entry -> historyNumber(entry.id()) == movedVersion),
        "Moving outside the selected subtree must not hide the before-category history");

    List<Long> visited = new ArrayList<>();
    Long cursor = null;
    boolean terminal = false;
    for (int page = 0; page <= expected.size(); page++) {
      var next = service.search("goods", null, root, cursor,
          new MasterRecordHistoryService.Filters(null, null, null, null, null, null, 2));
      visited.addAll(next.entries().stream().map(entry -> historyNumber(entry.id())).toList());
      if (next.nextCursor() == null) { terminal = true; break; }
      assertFalse(next.entries().isEmpty());
      assertEquals(next.entries().getLast().id(), next.nextCursor());
      cursor = historyNumber(next.nextCursor());
    }
    assertTrue(terminal, "Cursor traversal must finish");
    assertEquals(expected, visited, "Category cursor pages must keep exactly the original identities and order");
    assertEquals(visited.size(), new HashSet<>(visited).size());
    login(Set.of("goods:view"), false);
    var withoutCategoryAuthority = service.search("goods", null, root, null,
        new MasterRecordHistoryService.Filters(null, null, null, null, null, null, 100));
    assertTrue(withoutCategoryAuthority.entries().stream().noneMatch(entry -> entry.sourceType().equals("CATEGORY")));
    assertTrue(withoutCategoryAuthority.entries().stream().anyMatch(entry -> entry.recordId().equals(moved)));
  }

  @Test
  void forwardPreviousCategoryIndexIsReadyAndMatchesTheTypedCandidateExpression() {
    Object[] index = (Object[]) em.createNativeQuery("""
        SELECT i.indisvalid,i.indisready,pg_get_indexdef(i.indexrelid),
          pg_get_expr(i.indexprs,i.indrelid),i.indnkeyatts,(i.indoption[2] & 1)
        FROM pg_index i WHERE i.indexrelid=to_regclass('public.ix_master_versions_before_category')
        """).getSingleResult();
    assertEquals(Boolean.TRUE, index[0]);
    assertEquals(Boolean.TRUE, index[1]);
    String definition = index[2].toString().toLowerCase(Locale.ROOT);
    String expression = index[3].toString().toLowerCase(Locale.ROOT);
    assertTrue(definition.contains("master_record_versions"));
    assertTrue(definition.indexOf("entity_type") < definition.indexOf("before_row"));
    assertTrue(expression.contains("nullif") && expression.contains("before_row")
        && expression.contains("category_id") && expression.contains("::uuid"));
    assertEquals(3, ((Number) index[4]).intValue());
    assertEquals(1, ((Number) index[5]).intValue(), "The final index key must keep descending history identity");
  }

  private UUID queryCategory(UUID parent, String label) {
    UUID id = UUID.randomUUID();
    return inTx(() -> {
      provenance();
      em.createNativeQuery("INSERT INTO material_categories(id,code,name,parent_id) VALUES(:id,:code,:name,:parent)")
          .setParameter("id", id).setParameter("code", "C-" + id)
          .setParameter("name", "history candidate " + label + " " + id)
          .setParameter("parent", parent).executeUpdate();
      return id;
    });
  }

  @Test
  void historyCategoryTreeIncludesDeletedNodesAndRequiresItsOwnViewPermission() {
    UUID root = UUID.randomUUID(), child = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO material_categories(id,code,name) VALUES(:id,:code,'history filter"
                      + " root')")
              .setParameter("id", root)
              .setParameter("code", "R-" + root)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO material_categories(id,code,name,parent_id,is_deleted,deleted_at)"
                      + " VALUES(:id,:code,'deleted filter child',:parent,true,now())")
              .setParameter("id", child)
              .setParameter("code", "C-" + child)
              .setParameter("parent", root)
              .executeUpdate();
          return null;
        });
    login(Set.of("goods:view", "material_category:view"), false);
    var category =
        service.categories("goods").stream()
            .filter(c -> c.id().equals(root))
            .findFirst()
            .orElseThrow();
    assertEquals(child, category.children().getFirst().id());
    assertTrue(category.children().getFirst().isDeleted());
    assertTrue(category.children().getFirst().name().contains("已删除"));
    login(Set.of("goods:view"), false);
    assertThrows(ApiException.class, () -> service.categories("goods"));
  }

  @Test
  void legacyActorIdsResolveToPublicEmployeeAndAccountLabels() {
    UUID item = color("legacy actor");
    UUID employee = UUID.randomUUID(), account = UUID.randomUUID();
    String login = "legacy-" + account;
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO"
                      + " employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)"
                      + " SELECT :id,:code,'历史操作人','其他',id,current_date,'active','regular' FROM"
                      + " departments WHERE code='DEPT_FIN'")
              .setParameter("id", employee)
              .setParameter("code", "EMP-" + employee)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO"
                      + " users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin)"
                      + " VALUES(:id,:employee,:login,'test-only',false,'active',false)")
              .setParameter("id", account)
              .setParameter("employee", employee)
              .setParameter("login", login)
              .executeUpdate();
          return null;
        });
    Object[] identity = {account, "历史操作人", login};
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO"
                      + " master_record_versions(entity_type,source_table,row_id,record_id,before_row,after_row,action,actor_id)"
                      + " SELECT"
                      + " 'colors','colors',id,id,fn_goods_history_snapshot('colors'::regclass,c),fn_goods_history_snapshot('colors'::regclass,c),'EDIT',:actor"
                      + " FROM colors c WHERE id=:id")
              .setParameter("actor", identity[0])
              .setParameter("id", item)
              .executeUpdate();
          return null;
        });
    var result =
        service.search(
            "colors",
            item,
            null,
            null,
            new MasterRecordHistoryService.Filters(
                "EDIT", null, identity[1].toString(), null, null, null, 50));
    assertEquals(1, result.entries().size());
    assertTrue(result.entries().getFirst().actorName().contains(identity[1].toString()));
    assertTrue(result.entries().getFirst().actorName().contains(identity[2].toString()));
  }

  @Test
  void restoringAnOldSchemaSnapshotPreservesFieldsAddedLater() {
    UUID item = color("before schema evolution");
    edit(item, "after schema evolution");
    var revision = entry(item);
    inTx(
        () -> {
          em.createNativeQuery(
                  "ALTER TABLE colors ADD COLUMN IF NOT EXISTS history_future_field text DEFAULT"
                      + " 'new column current value'")
              .executeUpdate();
          return null;
        });
    var current = service.detail("colors", historyNumber(revision.id()));
    inTx(
        () -> {
          service.restore("colors", historyNumber(revision.id()), current.expectedHead(), true);
          return null;
        });
    assertEquals("before schema evolution", value("SELECT name FROM colors WHERE id=:id", item));
    assertEquals(
        "new column current value",
        value("SELECT history_future_field FROM colors WHERE id=:id", item));
  }

  @Test
  void warehouseHistoryUsesNativeNameNormalizationAndLineSideReadOnlyPolicy() {
    String marker = UUID.randomUUID().toString();
    UUID first = UUID.randomUUID(), other = UUID.randomUUID();
    inTx(
        () -> {
          if (em.createNativeQuery(
                  "SELECT id FROM warehouses WHERE parent_id IS NULL AND NOT is_deleted")
              .getResultList()
              .isEmpty())
            em.createNativeQuery(
                    "INSERT INTO warehouses(id,code,name,status,is_accountable)"
                        + " VALUES(:id,'001','主仓','使用',true)")
                .setParameter("id", UUID.randomUUID())
                .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable)"
                      + " VALUES(:id,:code,:name,fn_warehouse_root_id(),'使用',true)")
              .setParameter("id", first)
              .setParameter("code", "W-" + first)
              .setParameter("name", "历史仓库（" + marker + "）")
              .executeUpdate();
          return null;
        });
    inTx(
        () -> {
          em.createNativeQuery("UPDATE warehouses SET name=:name WHERE id=:id")
              .setParameter("id", first)
              .setParameter("name", "当前仓库" + marker)
              .executeUpdate();
          return null;
        });
    var original =
        detail("warehouses", service.list("warehouses", first, null, null).entries().getFirst());
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable)"
                      + " VALUES(:id,:code,:name,fn_warehouse_root_id(),'使用',true)")
              .setParameter("id", other)
              .setParameter("code", "W-" + other)
              .setParameter("name", " 历史 仓库(" + marker + ") ")
              .executeUpdate();
          return null;
        });
    var blocked = service.detail("warehouses", historyNumber(original.id()));
    assertFalse(blocked.canRestoreBefore());
    assertTrue(blocked.blockedReason().contains("同名仓库"));
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore(
                      "warehouses", historyNumber(original.id()), blocked.expectedHead(), true);
                  return null;
                }));
    assertEquals("当前仓库" + marker, value("SELECT name FROM warehouses WHERE id=:id", first));
    var current =
        new ObjectMapper().createObjectNode().put("is_line_side", true).put("name", "内料仓");
    assertTrue(
        history
            .versionRestorePolicyReason(
                new MasterVersionRow(
                    "warehouses", first, current, current.deepCopy().put("name", "被改名")))
            .contains("只读"));
  }

  @Test
  void categoryDeletionRestoresTheOriginalSubtreeAndItsRecordsAtomically() {
    UUID root = UUID.randomUUID(), child = UUID.randomUUID(), item = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO material_categories(id,code,name) VALUES(:id,:code,'history root')")
              .setParameter("id", root)
              .setParameter("code", "R-" + root)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO material_categories(id,code,name,parent_id)"
                      + " VALUES(:id,:code,'history child',:parent)")
              .setParameter("id", child)
              .setParameter("code", "C-" + child)
              .setParameter("parent", root)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO goods(id,code,name,category_id,code_sequence)"
                      + " VALUES(:id,:code,'subtree item',:category,(SELECT"
                      + " COALESCE(max(code_sequence),0)+1 FROM goods))")
              .setParameter("id", item)
              .setParameter("code", "G-" + item)
              .setParameter("category", child)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO goods(id,code,name,category_id,code_sequence) SELECT"
                      + " gen_random_uuid(),:prefix||n,'subtree item '||n,:category,(SELECT"
                      + " COALESCE(max(code_sequence),0) FROM goods)+n FROM generate_series(1,156)"
                      + " generated(n)")
              .setParameter("prefix", "G-" + item + "-")
              .setParameter("category", child)
              .executeUpdate();
          return null;
        });
    inTx(
        () -> {
          provenance();
          em.createNativeQuery(
                  "UPDATE goods SET is_deleted=true,deleted_at=now() WHERE category_id=:category")
              .setParameter("category", child)
              .executeUpdate();
          em.createNativeQuery(
                  "UPDATE material_categories SET is_deleted=true,deleted_at=now() WHERE id IN"
                      + " (:root,:child)")
              .setParameter("root", root)
              .setParameter("child", child)
              .executeUpdate();
          return null;
        });
    var deletion = detail("goods", service.list("goods", root, null, null).entries().getFirst());
    assertEquals(159, deletion.affectedCount());
    long started = System.nanoTime();
    inTx(
        () -> {
          service.restore("goods", historyNumber(deletion.id()), deletion.expectedHead(), true);
          return null;
        });
    System.out.println(
        "MASTER_HISTORY_RESTORE_CATEGORY goods=157 categories=2 elapsedMs="
            + (System.nanoTime() - started) / 1_000_000);
    assertEquals(
        "false", value("SELECT is_deleted::text FROM material_categories WHERE id=:id", root));
    assertEquals(
        "false", value("SELECT is_deleted::text FROM material_categories WHERE id=:id", child));
    assertEquals("false", value("SELECT is_deleted::text FROM goods WHERE id=:id", item));
    assertEquals(
        157,
        ((Number)
                em.createNativeQuery(
                        "SELECT count(*) FROM goods WHERE category_id=:category AND NOT is_deleted")
                    .setParameter("category", child)
                    .getSingleResult())
            .intValue());
  }

  @Test
  void goodsHistoryMasksEveryPriceAndCostFamilyAndDoesNotInventABomViewPermission() {
    UUID item = goods("costed");
    inTx(
        () -> {
          em.createNativeQuery(
                  "UPDATE goods SET"
                      + " price=17,a_price=19,price2=23,manage_e=29,electric_e=31,source_e=37 WHERE"
                      + " id=:id")
              .setParameter("id", item)
              .executeUpdate();
          return null;
        });
    login(Set.of("goods:view"), false);
    var entry = detail("goods", service.list("goods", item, null, null).entries().getFirst());
    assertTrue(entry.changes().isEmpty());
    assertFalse(entry.canRestoreBefore());
    inTx(
        () -> {
          em.createNativeQuery(
                  "UPDATE goods SET"
                      + " ground_graph=decode('01','hex'),product_graph1=decode('02','hex'),budget_graph=decode('03','hex')"
                      + " WHERE id=:id")
              .setParameter("id", item)
              .executeUpdate();
          return null;
        });
    var pictures = detail("goods", service.list("goods", item, null, null).entries().getFirst());
    assertTrue(
        pictures.changes().stream()
            .anyMatch(c -> c.field().equals("ground_graph") && c.label().equals("货品底图")));
    assertTrue(
        pictures.changes().stream()
            .anyMatch(c -> c.field().equals("product_graph1") && c.label().equals("货品图片1")));
    assertTrue(
        pictures.changes().stream()
            .noneMatch(c -> c.field().equals("budget_graph") || c.label().contains("_")));
    UUID component = goods("visible component"), edge = UUID.randomUUID();
    login(Set.of(), true);
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty)"
                      + " VALUES(:id,:parent,:component,1)")
              .setParameter("id", edge)
              .setParameter("parent", item)
              .setParameter("component", component)
              .executeUpdate();
          return null;
        });
    login(Set.of("goods:view"), false);
    assertFalse(service.list("goods", item, null, null).entries().isEmpty());
  }

  @Test
  void salePriceVisibilityNeverGrantsDiscountHistoryOrDiscountRestoration() {
    UUID item = goods("separate discount");
    inTx(
        () -> {
          em.createNativeQuery("UPDATE goods SET price=77,zk=0.9 WHERE id=:id")
              .setParameter("id", item)
              .executeUpdate();
          return null;
        });
    var selected = detail("goods", service.list("goods", item, null, null).entries().getFirst());
    login(Set.of("goods:view", "goods:edit", "goods:price:view", "goods:price:edit"), false);
    var masked = service.detail("goods", historyNumber(selected.id()));
    assertTrue(masked.changes().stream().anyMatch(c -> c.field().equals("price")));
    assertTrue(masked.changes().stream().noneMatch(c -> c.field().equals("zk")));
    assertFalse(masked.canRestoreBefore());
    assertTrue(masked.blockedReason().contains("折扣"));
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore(
                      "goods", historyNumber(selected.id()), selected.expectedHead(), true);
                  return null;
                }));
    assertEquals("0.9000", value("SELECT zk::text FROM goods WHERE id=:id", item));
  }

  @Test
  void salePriceVisibilityNeverRevealsLearnedPurchaseOrSubcontractCosts() {
    UUID item = goods("learned cost gate");
    inTx(
        () -> {
          em.createNativeQuery(
                  "UPDATE goods SET"
                      + " price=77,default_purchase_price=123.45,default_subcontract_price=67.89"
                      + " WHERE id=:id")
              .setParameter("id", item)
              .executeUpdate();
          return null;
        });
    var selected = detail("goods", service.list("goods", item, null, null).entries().getFirst());
    login(Set.of("goods:view", "goods:price:view"), false);
    var sales = service.detail("goods", historyNumber(selected.id()));
    assertTrue(sales.changes().stream().anyMatch(c -> c.field().equals("price")));
    assertTrue(
        sales.changes().stream()
            .noneMatch(
                c ->
                    c.field().startsWith("default_purchase_price")
                        || c.field().startsWith("default_subcontract_price")));
    login(Set.of("goods:view", "goods:cost:view"), false);
    var costs = service.detail("goods", historyNumber(selected.id()));
    assertTrue(costs.changes().stream().anyMatch(c -> c.field().equals("default_purchase_price")));
    assertTrue(
        costs.changes().stream().anyMatch(c -> c.field().equals("default_subcontract_price")));
    assertTrue(costs.changes().stream().noneMatch(c -> c.field().equals("price")));
  }

  @Test
  void subcontractLossPolicyRestorationRequiresItsNativeCostPermission() {
    UUID item = goods("guarded subcontract policy");
    inTx(
        () -> {
          em.createNativeQuery("UPDATE goods SET subcontract_allowed_loss_pct=15 WHERE id=:id")
              .setParameter("id", item)
              .executeUpdate();
          return null;
        });
    login(Set.of("goods:view", "goods:edit", "goods:purchase:edit"), false);
    var selected = detail("goods", service.list("goods", item, null, null).entries().getFirst());
    assertFalse(selected.canRestoreBefore());
    assertTrue(selected.blockedReason().contains("委外损耗"));
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore(
                      "goods", historyNumber(selected.id()), selected.expectedHead(), true);
                  return null;
                }));
    assertEquals(
        0,
        decimal("15")
            .compareTo(
                decimal(
                    value(
                        "SELECT subcontract_allowed_loss_pct::text FROM goods WHERE id=:id",
                        item))));
    login(Set.of("goods:view", "goods:edit", "goods:cost:view"), false);
    var missingPurchase = service.detail("goods", historyNumber(selected.id()));
    assertFalse(missingPurchase.canRestoreBefore());
    assertTrue(missingPurchase.blockedReason().contains("goods:purchase:edit"));
    assertThrows(ApiException.class, () -> inTx(() -> {
      service.restore("goods", historyNumber(missingPurchase.id()), missingPurchase.expectedHead(), true);
      return null;
    }));
    login(Set.of("goods:view", "goods:edit", "goods:purchase:edit", "goods:cost:view"), false);
    var allowed = service.detail("goods", historyNumber(selected.id()));
    assertTrue(allowed.canRestoreBefore(), allowed.blockedReason());
    inTx(
        () -> {
          service.restore("goods", historyNumber(allowed.id()), allowed.expectedHead(), true);
          return null;
        });
    assertEquals(
        "true",
        value("SELECT (subcontract_allowed_loss_pct IS NULL)::text FROM goods WHERE id=:id", item));
  }

  @Test
  void bomVersionRestoreKeepsReadEditAndDeleteAuthoritiesSeparate() {
    UUID parent = goods("permission parent"), component = goods("permission component");
    UUID edge = UUID.randomUUID();
    inTx(
        () -> {
          provenance();
          em.createNativeQuery(
                  "INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty)"
                      + " VALUES(:id,:parent,:component,1)")
              .setParameter("id", edge)
              .setParameter("parent", parent)
              .setParameter("component", component)
              .executeUpdate();
          return null;
        });
    var creation = detail("goods", service.list("goods", parent, null, null).entries().getFirst());
    long creationId = historyNumber(creation.id());

    for (Set<String> permissions :
        List.of(
            Set.of("goods:view"),
            Set.of("goods:view", "goods:edit", "goods:delete"),
            Set.of("goods:view", "goods:edit", "goods:bom:delete"),
            Set.of("goods:view", "goods:edit", "goods:bom:edit"))) {
      login(permissions, false);
      var denied = service.detail("goods", creationId);
      assertFalse(denied.canRestoreBefore(), permissions.toString());
      assertThrows(
          ApiException.class,
          () ->
              inTx(
                  () -> {
                    service.restore("goods", creationId, denied.expectedHead(), true);
                    return null;
                  }));
      assertEquals(
          "false", value("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id", edge));
    }

    login(Set.of("goods:view", "goods:bom:edit", "goods:bom:delete"), false);
    // Restoring a pure recipe change uses its own edit/delete authorities;
    // it does not invent a direct goods edit or a cost write.
    var deletion = service.detail("goods", creationId);
    assertTrue(deletion.canRestoreBefore(), deletion.blockedReason());
    inTx(
        () -> {
          service.restore("goods", creationId, deletion.expectedHead(), true);
          return null;
        });
    assertEquals("true", value("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id", edge));

    login(Set.of(), true);
    var admin = service.detail("goods", creationId);
    assertTrue(admin.canRestoreAfter(), admin.blockedReason());
    inTx(
        () -> {
          service.restore("goods", creationId, admin.expectedHead(), false);
          return null;
        });
    assertEquals("false", value("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id", edge));
    inTx(
        () -> {
          provenance();
          em.createNativeQuery("UPDATE goods_bom_items SET qty=2 WHERE id=:id")
              .setParameter("id", edge)
              .executeUpdate();
          return null;
        });
    var change = detail("goods", service.list("goods", parent, null, null).entries().getFirst());
    long changeId = historyNumber(change.id());
    login(Set.of("goods:view", "goods:edit"), false);
    assertFalse(service.detail("goods", changeId).canRestoreBefore());
    login(Set.of("goods:view", "goods:bom:edit"), false);
    var editable = service.detail("goods", changeId);
    assertTrue(editable.canRestoreBefore(), editable.blockedReason());
    inTx(
        () -> {
          service.restore("goods", changeId, editable.expectedHead(), true);
          return null;
        });
    assertEquals(
        0,
        decimal("1")
            .compareTo(decimal(value("SELECT qty::text FROM goods_bom_items WHERE id=:id", edge))));
  }

  @Test
  void restoringOnlyEnglishProvenanceStillRechecksTheSalesOrDedicatedAuthority() {
    UUID item = goods("version English source");
    inTx(() -> {
      em.createNativeQuery("UPDATE goods SET name_en='Same English',name_en_source='LEARNED' WHERE id=:id").setParameter("id",item).executeUpdate();
      return null;
    });
    inTx(() -> {
      provenance();
      em.createNativeQuery("UPDATE goods SET name_en_source='MANUAL',version=version+1 WHERE id=:id").setParameter("id",item).executeUpdate();
      return null;
    });
    long selected=historyNumber(service.list("goods",item,null,null).entries().getFirst().id());
    login(Set.of("goods:view","goods:edit"),false);
    var denied=service.detail("goods",selected);
    assertFalse(denied.canRestoreBefore());
    assertThrows(ApiException.class,()->inTx(()->{service.restore("goods",selected,denied.expectedHead(),true);return null;}));
    assertEquals("MANUAL",value("SELECT name_en_source FROM goods WHERE id=:id",item));
    login(Set.of("goods:view","goods:edit","goods:name_en:edit"),false);
    var allowed=service.detail("goods",selected);assertTrue(allowed.canRestoreBefore(),allowed.blockedReason());
    inTx(()->{service.restore("goods",selected,allowed.expectedHead(),true);return null;});
    assertEquals("LEARNED",value("SELECT name_en_source FROM goods WHERE id=:id",item));
    login(Set.of("goods:view","goods:edit"),false);
    var redoDenied=service.detail("goods",selected);
    assertThrows(ApiException.class,()->inTx(()->{service.restore("goods",selected,redoDenied.expectedHead(),false);return null;}));
    assertEquals("LEARNED",value("SELECT name_en_source FROM goods WHERE id=:id",item));
    login(Set.of("goods:view","goods:edit","goods:sales:edit"),false);
    var redo=service.detail("goods",selected);assertTrue(redo.canRestoreAfter(),redo.blockedReason());
    inTx(()->{service.restore("goods",selected,redo.expectedHead(),false);return null;});
    assertEquals("MANUAL",value("SELECT name_en_source FROM goods WHERE id=:id",item));
  }

  @Test
  void restoringABomRejectsDisabledComponentsAndAChangedGraphWithoutPartialWrites() {
    UUID parent = goods("parent"), component = goods("component"), edge = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty)"
                      + " VALUES(:id,:parent,:component,1)")
              .setParameter("id", edge)
              .setParameter("parent", parent)
              .setParameter("component", component)
              .executeUpdate();
          return null;
        });
    inTx(
        () -> {
          provenance();
          em.createNativeQuery(
                  "UPDATE goods_bom_items SET is_deleted=true,deleted_at=now() WHERE id=:id")
              .setParameter("id", edge)
              .executeUpdate();
          return null;
        });
    var deletion = detail("goods", service.list("goods", parent, null, null).entries().getFirst());
    inTx(
        () -> {
          em.createNativeQuery("UPDATE goods SET status='禁用' WHERE id=:id")
              .setParameter("id", component)
              .executeUpdate();
          return null;
        });
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore(
                      "goods", historyNumber(deletion.id()), deletion.expectedHead(), true);
                  return null;
                }));
    assertEquals("true", value("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id", edge));
    inTx(
        () -> {
          em.createNativeQuery("UPDATE goods SET status='使用' WHERE id=:id")
              .setParameter("id", component)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO goods_bom_items(goods_id,component_goods_id,qty)"
                      + " VALUES(:component,:parent,1)")
              .setParameter("component", component)
              .setParameter("parent", parent)
              .executeUpdate();
          return null;
        });
    var fresh =
        detail(
            "goods",
            service.list("goods", parent, null, null).entries().stream()
                .filter(e -> e.id().equals(deletion.id()))
                .findFirst()
                .orElseThrow());
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore("goods", historyNumber(fresh.id()), fresh.expectedHead(), true);
                  return null;
                }));
    assertEquals("true", value("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id", edge));
    verifyNoInteractions(events);
  }

  @Test
  void restoringSeveralBomEdgesPublishesOneDurableUpdateForTheParent() {
    UUID parent = goods("restored BOM"),
        first = goods("first component"),
        second = goods("second component");
    inTx(
        () -> {
          em.createNativeQuery("UPDATE goods SET price=3 WHERE id=:first OR id=:second")
              .setParameter("first", first)
              .setParameter("second", second)
              .executeUpdate();
          for (UUID component : List.of(first, second))
            em.createNativeQuery(
                    "INSERT INTO goods_bom_items(goods_id,component_goods_id,qty,price)"
                        + " VALUES(:parent,:component,1,3)")
                .setParameter("parent", parent)
                .setParameter("component", component)
                .executeUpdate();
          em.createNativeQuery(
                  "UPDATE goods SET source_e=fn_goods_bom_material_cost(id) WHERE id=:parent")
              .setParameter("parent", parent)
              .executeUpdate();
          return null;
        });
    inTx(
        () -> {
          provenance();
          em.createNativeQuery("UPDATE goods_bom_items SET qty=2 WHERE goods_id=:parent")
              .setParameter("parent", parent)
              .executeUpdate();
          em.createNativeQuery(
                  "UPDATE goods SET source_e=fn_goods_bom_material_cost(id) WHERE id=:parent")
              .setParameter("parent", parent)
              .executeUpdate();
          return null;
        });
    var selected = detail("goods", service.list("goods", parent, null, null).entries().getFirst());
    assertEquals(3, selected.affectedCount());
    assertTrue(selected.canRestoreBefore(), selected.blockedReason());
    inTx(
        () -> {
          service.restore("goods", historyNumber(selected.id()), selected.expectedHead(), true);
          return null;
        });
    assertEquals(
        2,
        em.createNativeQuery(
                "SELECT id FROM goods_bom_items WHERE goods_id=:parent AND qty=1 AND NOT"
                    + " is_deleted")
            .setParameter("parent", parent)
            .getResultList()
            .size());
    assertEquals(
        0,
        decimal("6")
            .compareTo(decimal(value("SELECT source_e::text FROM goods WHERE id=:id", parent))));
    verify(events)
        .publish(
            eq("GOODS_BOM_UPDATED"),
            eq("GOODS_BOM"),
            eq(parent),
            eq(Map.of("recordHistoryId", selected.id(), "reason", "VERSION_RESTORE")));
    verifyNoMoreInteractions(events);
  }

  @Test
  void aFailedBomEventAppendRollsBackTheRestoredGraphAndItsNewVersion() {
    UUID parent = goods("atomic BOM"),
        component = goods("atomic component"),
        edge = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty)"
                      + " VALUES(:id,:parent,:component,1)")
              .setParameter("id", edge)
              .setParameter("parent", parent)
              .setParameter("component", component)
              .executeUpdate();
          return null;
        });
    inTx(
        () -> {
          provenance();
          em.createNativeQuery("UPDATE goods_bom_items SET qty=2 WHERE id=:id")
              .setParameter("id", edge)
              .executeUpdate();
          return null;
        });
    var selected = detail("goods", service.list("goods", parent, null, null).entries().getFirst());
    doThrow(new IllegalStateException("outbox unavailable"))
        .when(events)
        .publish(eq("GOODS_BOM_UPDATED"), eq("GOODS_BOM"), eq(parent), anyMap());
    assertThrows(
        ApiException.class,
        () ->
            inTx(
                () -> {
                  service.restore(
                      "goods", historyNumber(selected.id()), selected.expectedHead(), true);
                  return null;
                }));
    assertEquals(
        0,
        decimal("2")
            .compareTo(decimal(value("SELECT qty::text FROM goods_bom_items WHERE id=:id", edge))));
    assertEquals(
        selected.expectedHead(),
        service.detail("goods", historyNumber(selected.id())).expectedHead());
  }

  @Test
  void extensionValuesUseTheExistingGuardedWriterAndProtectedValuesNeverCrossTheHistoryApi() {
    UUID item = goods("extended"), definition = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO"
                      + " platform_column_definitions(id,scope,name,normalized_name,value_type,price_protected,definition_fingerprint,created_by)"
                      + " VALUES(:id,'master_goods','private cost note','private cost"
                      + " note','TEXT',true,:fingerprint,:actor)")
              .setParameter("id", definition)
              .setParameter("fingerprint", definition.toString())
              .setParameter("actor", actor)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO"
                      + " platform_record_fields(scope,record_id,cells,created_by,updated_by,retain_on_reset)"
                      + " VALUES('master_goods',:id,CAST(:cells AS jsonb),:actor,:actor,true)")
              .setParameter("id", item)
              .setParameter("cells", cells(definition, "original private value"))
              .setParameter("actor", actor)
              .executeUpdate();
          return null;
        });
    inTx(
        () -> {
          em.createNativeQuery(
                  "UPDATE platform_record_fields SET cells=CAST(:cells AS jsonb),version=version+1"
                      + " WHERE scope='master_goods' AND record_id=:id")
              .setParameter("id", item)
              .setParameter("cells", cells(definition, "changed private value"))
              .executeUpdate();
          return null;
        });
    var selected = detail("goods", service.list("goods", item, null, null).entries().getFirst());
    assertTrue(
        selected.changes().stream()
            .anyMatch(c -> c.beforeValue().equals("original private value")));
    login(Set.of("goods:view", "goods:edit"), false);
    var masked = service.detail("goods", historyNumber(selected.id()));
    assertTrue(masked.changes().isEmpty());
    login(Set.of(), true);
    inTx(
        () -> {
          var connection = em.unwrap(org.hibernate.Session.class).doReturningWork(c -> c);
          var resource =
              new PlatformColumnResourceAdapter() {
                @Override
                public String scope() {
                  return "master_goods";
                }

                @Override
                public String label() {
                  return "货品资料";
                }

                @Override
                public void requireDefinitionAccess(boolean write) {
                  if (write && !canWrite())
                    throw new ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN);
                }

                @Override
                public boolean canWrite() {
                  return current.get().orElseThrow().isSuperAdmin();
                }

                @Override
                public boolean canViewPrice() {
                  return canWrite();
                }

                @Override
                public Map<UUID, RecordAccess> authorize(Set<UUID> ids, boolean write) {
                  requireDefinitionAccess(write);
                  Map<UUID, RecordAccess> result = new HashMap<>();
                  ids.forEach(id -> result.put(id, new RecordAccess(canWrite(), canViewPrice())));
                  return result;
                }
              };
          var fields =
              new PlatformColumnService(
                  List.of(resource),
                  new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true)),
                  new ObjectMapper(),
                  current,
                  tx);
          service =
              new MasterRecordHistoryService(
                  em,
                  new ObjectMapper(),
                  current,
                  tx,
                  clientPolicy,
                  mock(OwnerVisibility.class),
                  history,
                  goodsHistory,
                  Optional.of(fields),
                  Optional.empty(),
                  events,
                  new EmployeeNameResolver(em),
                  new DepartmentNameResolver(em));
          service.restore("goods", historyNumber(selected.id()), selected.expectedHead(), true);
          return null;
        });
    assertEquals(
        "original private value",
        value(
            "SELECT cells->0->>'value' FROM platform_record_fields WHERE record_id=:id AND"
                + " scope='master_goods'",
            item));
    assertEquals("RESTORE", service.list("goods", item, null, null).entries().getFirst().action());
  }

  @Test
  void periodicBomEdgesRemainVisibleAndRespectTheNativeRestoreGuard() {
    UUID parent = goods("periodic recipe"),
        component = UUID.randomUUID(),
        unit = UUID.randomUUID(),
        edge = UUID.randomUUID();
    inTx(
        () -> {
          em.createNativeQuery("INSERT INTO units(id,code,name) VALUES(:id,:code,'历史重量单位')")
              .setParameter("id", unit)
              .setParameter("code", "KG-" + unit)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO"
                      + " unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance)"
                      + " VALUES(:id,'MASS','KG','MANUAL_GOVERNANCE') ON CONFLICT(unit_id) DO"
                      + " UPDATE SET"
                      + " measurement_dimension='MASS',mass_unit_code=EXCLUDED.mass_unit_code")
              .setParameter("id", unit)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO"
                      + " goods(id,code,name,unit_id,issue_method,periodic_cost_basis,code_sequence)"
                      + " VALUES(:id,:code,'期间原材料',:unit,'PERIODIC','OWN',(SELECT"
                      + " COALESCE(max(code_sequence),0)+1 FROM goods))")
              .setParameter("id", component)
              .setParameter("code", "P-" + component)
              .setParameter("unit", unit)
              .executeUpdate();
          em.createNativeQuery(
                  "INSERT INTO"
                      + " goods_bom_items(id,goods_id,component_goods_id,qty,control_stage,consumption_basis,basis_output_qty,hard_gate)"
                      + " VALUES(:id,:parent,:component,1,'START','PER_UNIT',1,false)")
              .setParameter("id", edge)
              .setParameter("parent", parent)
              .setParameter("component", component)
              .executeUpdate();
          return null;
        });
    inTx(
        () -> {
          provenance();
          em.createNativeQuery("UPDATE goods_bom_items SET qty=2 WHERE id=:id")
              .setParameter("id", edge)
              .executeUpdate();
          return null;
        });
    var selected = detail("goods", service.list("goods", parent, null, null).entries().getFirst());
    assertTrue(
        selected.changes().stream()
            .anyMatch(change -> change.rowId().equals(edge) && change.field().equals("qty")));
    var blocked =
        assertThrows(
            ApiException.class,
            () ->
                inTx(
                    () -> {
                      service.restore(
                          "goods", historyNumber(selected.id()), selected.expectedHead(), true);
                      return null;
                    }));
    assertTrue(blocked.getMessage().contains("期间领料"));
    assertEquals(
        0,
        decimal("2")
            .compareTo(decimal(value("SELECT qty::text FROM goods_bom_items WHERE id=:id", edge))));
    assertEquals("PERIODIC", value("SELECT issue_method FROM goods WHERE id=:id", component));
    assertEquals(
        selected.expectedHead(),
        service.detail("goods", historyNumber(selected.id())).expectedHead());
    verifyNoInteractions(events);
  }

  private String cells(UUID definition, String value) {
    return "[{\"columnId\":\"" + definition + "\",\"value\":\"" + value + "\"}]";
  }

  private UUID goods(String name) {
    UUID id = UUID.randomUUID();
    return inTx(
        () -> {
          em.createNativeQuery(
                  "INSERT INTO goods(id,code,name,code_sequence) VALUES(:id,:code,:name,(SELECT"
                      + " COALESCE(max(code_sequence),0)+1 FROM goods))")
              .setParameter("id", id)
              .setParameter("code", "G-" + id)
              .setParameter("name", name)
              .executeUpdate();
          return id;
        });
  }

  private MasterRecordHistoryService.Entry detail(
      String entity, MasterRecordHistoryService.Entry summary) {
    return service.detail(entity, historyNumber(summary.id()));
  }

  private MasterRecordHistoryService.Entry entry(UUID id) {
    return detail("colors", service.list("colors", id, null, null).entries().getFirst());
  }

  private UUID color(String name) {
    UUID id = UUID.randomUUID();
    return inTx(
        () -> {
          provenance();
          em.createNativeQuery("INSERT INTO colors(id,code,name) VALUES(:id,:code,:name)")
              .setParameter("id", id)
              .setParameter("code", "V-" + id)
              .setParameter("name", name)
              .executeUpdate();
          return id;
        });
  }

  private void edit(UUID id, String name) {
    inTx(
        () -> {
          provenance();
          em.createNativeQuery(
                  "UPDATE colors SET name=:name,updated_at=clock_timestamp() WHERE id=:id")
              .setParameter("name", name)
              .setParameter("id", id)
              .executeUpdate();
          return null;
        });
  }

  private void login(Set<String> permissions, boolean admin) {
    when(current.get())
        .thenReturn(
            Optional.of(
                new AuthUser(
                    actor,
                    UUID.randomUUID(),
                    "operator-" + actor,
                    permissions,
                    false,
                    true,
                    admin)));
  }

  private void provenance() {
    set("app.actor_id", actor.toString());
    set("app.actor_account", "operator-" + actor);
    set("app.audit_request_id", UUID.randomUUID().toString());
    set("app.audit_request_path", "/api/master/record-history");
    set("app.audit_request_method", "POST");
  }

  private void set(String key, String value) {
    em.createNativeQuery("SELECT set_config(:key,:value,true)")
        .setParameter("key", key)
        .setParameter("value", value)
        .getSingleResult();
  }

  private String value(String sql, UUID id) {
    return Objects.toString(
        em.createNativeQuery(sql).setParameter("id", id).getSingleResult(), null);
  }

  private <T> T inTx(Supplier<T> work) {
    em.getTransaction().begin();
    try {
      T result = work.get();
      em.getTransaction().commit();
      return result;
    } catch (RuntimeException | Error error) {
      if (em.getTransaction().isActive()) em.getTransaction().rollback();
      throw error;
    }
  }

  private static long historyNumber(String value) {
    try {
      return Long.parseLong(value);
    } catch (NumberFormatException failure) {
      throw new AssertionError("History API id/cursor must be a 64-bit integer: " + value, failure);
    }
  }

  private static java.math.BigDecimal decimal(String value) {
    try {
      return new java.math.BigDecimal(value);
    } catch (NumberFormatException failure) {
      throw new AssertionError("History database value must be decimal: " + value, failure);
    }
  }
}
