package com.uten.imp.features.master;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.client.*;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.master.supplier.*;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.TypedQuery;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;

import java.sql.Connection;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Actual Criteria/PG reads from migrated column shapes; source FK/trigger workflows use their full-chain tests. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PartyLookupSearchContextPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private EntityManagerFactory factory;
    private EntityManager em;
    private JdbcTemplate jdbc;
    private ClientService clients;
    private SupplierService suppliers;
    private boolean committedFixture;
    private final UUID viewer = UUID.randomUUID(), outside = UUID.randomUUID();

    @BeforeAll static void baseline() throws Exception { database = MigratedSchemaBaseline.openDatabase("b1_party_context"); }
    @AfterAll static void close() throws Exception { if (database != null) database.close(); }
    @BeforeEach void fixture() throws Exception {
        committedFixture = false;
        connection = database.openConnection(); connection.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);
        connection.setAutoCommit(false);
        try (var statement = connection.createStatement()) {
            statement.execute("CREATE SCHEMA party_context_oracle");
            statement.execute("SET LOCAL search_path=party_context_oracle,public");
        }
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection, "clients", "client_categories",
                "suppliers", "supplier_categories", "client_visibility_grants", "employees", "users");
        var source = new SingleConnectionDataSource(connection, true); jdbc = new JdbcTemplate(source);
        var bean = new LocalContainerEntityManagerFactoryBean(); bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter()); bean.setPackagesToScan(
                "com.uten.imp.features.master.client", "com.uten.imp.features.master.clientcategory",
                "com.uten.imp.features.master.supplier", "com.uten.imp.features.master.suppliercategory");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none")); bean.afterPropertiesSet();
        factory = bean.getObject(); em = factory.createEntityManager();
        var repos = new JpaRepositoryFactory(em);
        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), viewer, "reader",
                Set.of("client:view", "supplier:view"), false, true, false)));
        var owners = mock(OwnerVisibility.class);
        when(owners.evaluate("client", "client:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(viewer)));
        clients = new ClientService(repos.getRepository(ClientRepository.class), repos.getRepository(ClientCategoryRepository.class),
                null, em, null, new ClientAccessPolicy(owners, current, em), null, new EmployeeNameResolver(em));
        suppliers = new SupplierService(repos.getRepository(SupplierRepository.class), repos.getRepository(SupplierCategoryRepository.class),
                null, em, null, null, new EmployeeNameResolver(em));
    }
    @AfterEach void rollback() throws Exception {
        if (em != null) em.close(); if (factory != null) factory.close();
        if (connection != null) {
            connection.rollback();
            if (committedFixture) {
                connection.setAutoCommit(true);
                try (var statement = connection.createStatement()) { statement.execute("DROP SCHEMA party_context_oracle CASCADE"); }
            }
            connection.close();
        }
    }

    @Test void clientLookupSharesDictionaryScopeAndNeverExposesPrivateFields() {
        UUID category = category("client", 1, "客户分类");
        UUID active = client(category, viewer, "使用", false, "A", "公开名称");
        UUID disabled = client(category, viewer, "禁用", false, "D", "历史名称");
        UUID hidden = client(category, outside, "使用", false, "H", "隐藏名称");
        UUID shared = client(category, outside, "使用", false, "S", "分享名称");
        UUID deleted = client(category, viewer, "使用", true, "X", "已删名称");
        UUID stub = client(category, viewer, "使用", false, "LEGACY-FIN-CL-1", "财务影子");
        jdbc.update("INSERT INTO client_visibility_grants(client_id,grantee_employee_id,active) VALUES(?,?,true)", shared, viewer);
        Set<UUID> requested = Set.of(active, disabled, hidden, shared, deleted, stub, UUID.randomUUID());
        var result = clients.lookup(requested, true);
        assertThat(result).extracting(row -> row.id()).containsExactlyInAnyOrder(active, disabled, shared);
        assertThat(result).filteredOn(row -> row.id().equals(disabled)).allSatisfy(row -> assertThat(row.selectable()).isFalse());
        var json = new ObjectMapper().valueToTree(result).toString();
        assertThat(json).doesNotContain("mobile", "bankAccount", "税", "PRIVATE", "hidden", "隐藏名称");
        jdbc.update("UPDATE client_visibility_grants SET active=false WHERE client_id=?", shared);
        assertThat(clients.lookup(requested, true)).extracting(row -> row.id()).doesNotContain(shared);
        jdbc.update("UPDATE client_visibility_grants SET active=true WHERE client_id=?", shared);
        assertThat(clients.lookup(requested, false)).extracting(row -> row.id()).contains(shared, stub).doesNotContain(hidden, deleted);
    }

    @Test void contextUsesSameSearchAndSelectabilityAsRowsAndIncludesLateAndNullCategories() {
        UUID first = category("client", 1, "第一类"), last = category("client", 200, "末页分类");
        client(first, viewer, "使用", false, "A", "target A%_B");
        client(last, viewer, "使用", false, "B", "target A%_B");
        client(null, viewer, "使用", false, "C", "target A%_B");
        client(last, viewer, "禁用", false, "D", "target A%_B");
        client(last, outside, "使用", false, "H", "target A%_B");
        client(last, viewer, "使用", false, "N", "target AXZB");
        ClientQueryFilter filter = clientFilter("target A%_B", true);
        var page1 = clients.searchContext(filter, 1, 2);
        var page2 = clients.searchContext(filter, 2, 2);
        assertThat(page1.totalMatches()).isEqualTo(3); assertThat(page1.totalCategories()).isEqualTo(3);
        assertThat(page1.categories()).extracting(row -> row.categoryId()).containsExactly(first, last);
        assertThat(page2.categories()).hasSize(1); assertThat(page2.categories().getFirst().categoryId()).isNull();
        assertThat(page2.categories().getFirst().count()).isEqualTo(1);
        assertThat(clients.list(filter, 1, 100, null, null).getTotal()).isEqualTo(page1.totalMatches());
        assertThat(clients.searchContext(clientFilter("none", true), 1, 100).categories()).isEmpty();
    }

    @Test void supplierContextAndLookupKeepDisabledDisplayAndExcludeInternalWorkshopsOnlyWhereRequired() {
        UUID category = category("supplier", 1, "供应商分类");
        UUID active = supplier(category, "使用", false, false, "A"), disabled = supplier(category, "禁用", false, false, "D");
        UUID workshop = supplier(category, "使用", true, false, "W"), deleted = supplier(category, "使用", false, true, "X");
        var result = suppliers.lookup(Set.of(active, disabled, workshop, deleted));
        assertThat(result).extracting(row -> row.getId()).containsExactlyInAnyOrder(active, disabled);
        assertThat(result).filteredOn(row -> row.getId().equals(disabled)).allSatisfy(row -> assertThat(row.getStatus()).isEqualTo("禁用"));
        var context = suppliers.searchContext(supplierFilter("供应商", true), 1, 100);
        assertThat(context.totalMatches()).isEqualTo(1); assertThat(context.totalCategories()).isEqualTo(1);
        assertThat(suppliers.list(supplierFilter("供应商", true), 1, 100, null, null).getTotal()).isEqualTo(context.totalMatches());
    }

    @Test void twoHundredIdsRemainLegalAndOversizedLookupsAreRejectedBeforeReading() {
        Set<UUID> ids = new HashSet<>(); for (int i = 0; i < 200; i++) ids.add(UUID.randomUUID());
        assertThat(clients.lookup(ids, true)).isEmpty(); assertThat(suppliers.lookup(ids)).isEmpty();
        ids.add(UUID.randomUUID());
        assertThatThrownBy(() -> clients.lookup(ids, true)).isInstanceOf(ApiException.class).hasMessageContaining("200");
        assertThatThrownBy(() -> suppliers.lookup(ids)).isInstanceOf(ApiException.class).hasMessageContaining("200");
    }

    @Test void metadataRowsAndTotalsKeepOneRealPostgresSnapshotWhenAnotherTransactionCommitsBetweenThem() throws Exception {
        UUID first = category("client", 1, "首类"), second = category("client", 2, "次类");
        client(first, viewer, "使用", false, "A", "已有A"); client(second, viewer, "使用", false, "B", "已有B");
        connection.commit(); committedFixture = true;
        try (var statement = connection.createStatement()) { statement.execute("SET LOCAL search_path=party_context_oracle,public"); }
        AtomicBoolean inserted = new AtomicBoolean();
        EntityManager measured = (EntityManager) Proxy.newProxyInstance(EntityManager.class.getClassLoader(),
                new Class<?>[]{EntityManager.class}, (proxy, method, args) -> {
                    try {
                        Object result = method.invoke(em, args);
                        if (!method.getName().equals("createQuery") || !(result instanceof TypedQuery<?> query)) return result;
                        return Proxy.newProxyInstance(TypedQuery.class.getClassLoader(), new Class<?>[]{TypedQuery.class},
                                (queryProxy, queryMethod, queryArgs) -> {
                                    try {
                                        Object value = queryMethod.invoke(query, queryArgs);
                                        if (queryMethod.getName().equals("getSingleResult") && inserted.compareAndSet(false, true)) {
                                            try (Connection writer = database.openConnection()) {
                                                writer.setAutoCommit(false);
                                                try (var statement = writer.createStatement()) { statement.execute("SET LOCAL search_path=party_context_oracle,public"); }
                                                var other = new JdbcTemplate(new SingleConnectionDataSource(writer, true));
                                                UUID category = new UUID(0, 3);
                                                other.update("INSERT INTO client_categories(id,code,name,version,is_deleted,level,path,sort_order) VALUES(?,'CAT3','迟到类',0,false,0,'/',0)", category);
                                                other.update("INSERT INTO clients(id,name,code,category_id,owner_employee_id,status,is_deleted,version,access_version,code_managed,code_sequence)"
                                                        + " VALUES(?,'晚提交','LATE',?,?,'使用',false,0,0,false,1)", UUID.randomUUID(), category, viewer);
                                                writer.commit();
                                            }
                                        }
                                        return value;
                                    } catch (InvocationTargetException failure) { throw failure.getCause(); }
                                });
                    } catch (InvocationTargetException failure) { throw failure.getCause(); }
                });
        ReflectionTestUtils.setField(clients, "em", measured);
        var context = clients.searchContext(clientFilter(null, true), 1, 100);
        assertThat(inserted).isTrue(); assertThat(context.totalMatches()).isEqualTo(2);
        assertThat(context.totalCategories()).isEqualTo(2);
        assertThat(context.categories()).extracting(row -> row.categoryId()).containsExactly(first, second);
        connection.commit();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM party_context_oracle.clients", Long.class)).isEqualTo(3);
    }

    private UUID category(String kind, int sequence, String name) {
        UUID id = new UUID(0, sequence);
        jdbc.update("INSERT INTO " + kind + "_categories(id,code,name,version,is_deleted,level,path,sort_order) VALUES(?,?,?,0,false,0,'/',0)",
                id, "CAT" + sequence, name); return id;
    }
    private UUID client(UUID category, UUID owner, String status, boolean deleted, String code, String name) {
        UUID id = UUID.randomUUID(); jdbc.update("INSERT INTO clients(id,name,code,category_id,owner_employee_id,status,is_deleted,version,access_version,code_managed,code_sequence,mobile,bank_account)"
                + " VALUES(?,?,?,?,?,?,?,0,0,false,1,'PRIVATE-MOBILE','PRIVATE-BANK')", id, name, code, category, owner, status, deleted); return id;
    }
    private UUID supplier(UUID category, String status, boolean workshop, boolean deleted, String code) {
        UUID id = UUID.randomUUID(); jdbc.update("INSERT INTO suppliers(id,name,code,category_id,status,is_internal_workshop,is_deleted,version,code_managed,code_sequence)"
                + " VALUES(?,'供应商',?,?,?,?,?,0,false,1)", id, code, category, status, workshop, deleted); return id;
    }
    private static ClientQueryFilter clientFilter(String keyword, boolean selectable) {
        Map<String, Object> input = new HashMap<>(); input.put("keyword", keyword); input.put("selectableOnly", selectable);
        input.put("excludeLegacyFinanceStub", true);
        return new ObjectMapper().convertValue(input, ClientQueryFilter.class);
    }
    private static SupplierQueryFilter supplierFilter(String keyword, boolean selectable) {
        Map<String, Object> input = new HashMap<>(); input.put("keyword", keyword); input.put("selectableOnly", selectable);
        return new ObjectMapper().convertValue(input, SupplierQueryFilter.class);
    }
}
