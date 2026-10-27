package com.uten.imp.features.warehouse.history;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.util.EmployeeNameResolver;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DelegatingDataSource;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual name SQL and DTO/fallback behavior; fixed page facts stand in for the authorized history query. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseHistoryOwnerNamesBatchPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine");
    private static final List<String> STATEMENTS = Collections.synchronizedList(new ArrayList<>());
    private static EntityManagerFactory factory;
    private static JdbcTemplate db;
    private EntityManager em;
    private EmployeeNameResolver names;

    @BeforeAll static void database() {
        POSTGRES.start();
        var source = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        db = new JdbcTemplate(source);
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(db, "employees", "users");
        var measured = new DelegatingDataSource(source) {
            @Override public Connection getConnection() throws java.sql.SQLException {
                Connection connection = super.getConnection();
                return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(),
                        new Class<?>[]{Connection.class}, (proxy, method, args) -> {
                            if (method.getName().startsWith("prepare") && args != null && args[0] instanceof String sql) STATEMENTS.add(sql);
                            try { return method.invoke(connection, args); }
                            catch (InvocationTargetException failure) { throw failure.getCause(); }
                        });
            }
        };
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(measured); bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.common.util");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none"));
        bean.afterPropertiesSet(); factory = bean.getObject();
    }

    @AfterAll static void close() {
        if (factory != null) {
            factory.close();
        }
        POSTGRES.stop();
    }
    @BeforeEach void reset() {
        db.execute("TRUNCATE employees, users"); em = factory.createEntityManager(); names = new EmployeeNameResolver(em); STATEMENTS.clear();
    }
    @AfterEach void closeEntityManager() { if (em != null) em.close(); }

    @ParameterizedTest @EnumSource(WarehouseHistoryType.class)
    void aHundredDistinctCurrentAndLegacyActorsUseOneNameSql(WarehouseHistoryType type) {
        List<Object[]> rows = new ArrayList<>();
        List<String> expected = new ArrayList<>();
        for (int index = 0; index < 100; index++) {
            UUID person = employee("W" + index, "责任人" + index, index % 3 == 0);
            UUID actor = index < 50 ? person : user(person);
            rows.add(row(index, actor, null, "旧快照", null)); expected.add("责任人" + index);
        }
        var fixture = fixture(rows);
        STATEMENTS.clear();
        var result = fixture.service().list(type, "", null, null, null, 1, 100);
        assertThat(result.getItems().stream().map(WarehouseHistoryListItem::makerName)).isEqualTo(expected);
        assertThat(result.getItems()).allSatisfy(item -> {
            assertThat(item.lineCount()).isEqualTo(1);
            assertThat(item.billDate()).isEqualTo(LocalDate.of(2026, 10, 20));
            assertThat(item.type()).isEqualTo(type.pathSegment());
        });
        System.out.println("WAREHOUSE-HISTORY-NAMES type=" + type + " rows=100 nameSql=" + STATEMENTS.size());
        assertThat(STATEMENTS).hasSize(1);
    }

    @ParameterizedTest @EnumSource(WarehouseHistoryType.class)
    void preserveUnknownNullBlankDeletedLegacyAndFallbackOrdering(WarehouseHistoryType type) {
        UUID unknown = UUID.randomUUID(), noSnapshot = UUID.randomUUID();
        UUID blank = employee("BLANK", "   ", false);
        UUID deleted = employee("OLD", "  历史员工  ", true);
        UUID legacy = user(deleted);
        List<Object[]> rows = List.of(
                row(1, unknown, unknown, " 首个快照 ", "不同审批快照"),
                row(2, unknown, null, "另一个快照", "每行无UUID审批快照"),
                row(3, noSnapshot, null, null, null),
                row(4, noSnapshot, null, "  ", null),
                row(5, noSnapshot, null, " 后补快照 ", null),
                row(6, noSnapshot, null, "后续不同快照", null),
                row(7, null, null, " 独立无UUID甲 ", " 独立审批 "),
                row(8, null, null, "独立无UUID乙", null),
                row(9, blank, null, " 空白姓名旧值 ", null),
                row(10, blank, null, "后续空白姓名旧值", null),
                row(11, deleted, legacy, "旧制单快照", "旧审核快照"));
        var fixture = fixture(rows);
        STATEMENTS.clear();
        var first = fixture.service().list(type, "", null, null, null, 1, 100).getItems();
        // A missing current identity keeps each document's original snapshot;
        // caching the first fallback by UUID would overwrite later facts.
        assertThat(first.stream().map(WarehouseHistoryListItem::makerName)).containsExactly(
                "首个快照", "另一个快照", null, null, "后补快照", "后续不同快照",
                "独立无UUID甲", "独立无UUID乙", "空白姓名旧值", "后续空白姓名旧值", "历史员工");
        assertThat(first.getFirst().approverName()).isEqualTo("不同审批快照");
        assertThat(first.get(1).approverName()).isEqualTo("每行无UUID审批快照");
        assertThat(first.getLast().approverName()).isEqualTo("历史员工");
        assertThat(STATEMENTS).hasSize(1);
        db.update("UPDATE employees SET full_name='改名后的历史员工' WHERE id=?", deleted);
        STATEMENTS.clear();
        var next = fixture.service().list(type, "", null, null, null, 1, 100).getItems();
        assertThat(next.getLast().makerName()).isEqualTo("改名后的历史员工");
        assertThat(first.getLast().makerName()).isEqualTo("历史员工");
        assertThat(STATEMENTS).hasSize(1);
    }

    @Test void pageMetadataScopeAndColumnFiltersStayBoundToTheSamePageQuery() {
        UUID actor = employee("PAGE", "分页员工", false), requestedWarehouse = UUID.randomUUID();
        List<Object[]> rows = new ArrayList<>();
        for (int index = 0; index < 32; index++) rows.add(row(index, actor, null, null, null));
        var fixture = fixture(rows);
        LocalDate from = LocalDate.of(2026, 10, 1), to = LocalDate.of(2026, 10, 31);
        STATEMENTS.clear();
        var result = fixture.service().list(WarehouseHistoryType.PURCHASE_RECEIPT, "part", (short) 1,
                from, to, 2, 10, "billNo", "asc", "Q123", "S456", requestedWarehouse);
        assertThat(result.getPage()).isEqualTo(2); assertThat(result.getSize()).isEqualTo(10);
        assertThat(result.getTotal()).isEqualTo(32); assertThat(result.getTotalPages()).isEqualTo(4);
        assertThat(result.getItems()).hasSize(10);
        assertThat(result.getItems().getFirst().billNo()).isEqualTo("B10");
        verify(fixture.scopes()).current(requestedWarehouse);
        verify(fixture.rows()).setParameter("offset", 10L);
        verify(fixture.rows()).setParameter("limit", 10);
        for (Query query : List.of(fixture.count(), fixture.rows())) {
            verify(query).setParameter("bill_no", "Q123"); verify(query).setParameter("source_doc_no", "S456");
            verify(query).setParameter("date_from", from); verify(query).setParameter("date_to", to);
            verify(query).setParameter("status", (short) 1);
        }
        assertThat(STATEMENTS).hasSize(1);
    }

    @Test void emptyAndAllNullActorPagesDoNotReadNames() {
        var empty = fixture(List.of());
        STATEMENTS.clear();
        assertThat(empty.service().list(WarehouseHistoryType.PURCHASE_RECEIPT, "", null, null, null, 1, 20).getItems()).isEmpty();
        verify(empty.projection(), times(1)).createNativeQuery(anyString());
        var unassigned = fixture(List.of(row(1, null, null, "旧制单", "旧审核"), row(2, null, null, null, "  ")));
        var result = unassigned.service().list(WarehouseHistoryType.PURCHASE_RECEIPT, "", null, null, null, 1, 20).getItems();
        assertThat(result.getFirst().makerName()).isEqualTo("旧制单");
        assertThat(result.getFirst().approverName()).isEqualTo("旧审核");
        assertThat(result.getLast().makerName()).isNull(); assertThat(result.getLast().approverName()).isNull();
        assertThat(STATEMENTS).isEmpty();
    }

    private record Fixture(WarehouseHistoryQueryService service, EntityManager projection, Query count, Query rows, WarehouseTaskScopePort scopes) { }
    @SuppressWarnings({"rawtypes", "unchecked"})
    private Fixture fixture(List<Object[]> facts) {
        var projection = mock(EntityManager.class); var count = mock(Query.class); var rows = mock(Query.class);
        when(projection.createNativeQuery(anyString())).thenAnswer(call ->
                ((String) call.getArgument(0)).startsWith("SELECT COUNT(*) ") ? count : rows);
        when(count.setParameter(anyString(), any())).thenReturn(count);
        AtomicInteger offset = new AtomicInteger(), limit = new AtomicInteger(100);
        when(rows.setParameter(anyString(), any())).thenAnswer(call -> {
            String key = call.getArgument(0); Object value = call.getArgument(1);
            if (key.equals("offset")) offset.set(((Number) value).intValue());
            if (key.equals("limit")) limit.set(((Number) value).intValue());
            return rows;
        });
        when(count.getSingleResult()).thenReturn((long) facts.size());
        when(rows.getResultList()).thenAnswer(call -> facts.subList(Math.min(offset.get(), facts.size()), Math.min(offset.get() + limit.get(), facts.size())));
        var scopes = mock(WarehouseTaskScopePort.class);
        when(scopes.current(any())).thenReturn(WarehouseTaskScopePort.WarehouseTaskScope.ALL);
        return new Fixture(new WarehouseHistoryQueryService(projection, names, scopes), projection, count, rows, scopes);
    }

    private static Object[] row(int index, UUID maker, UUID approver, String makerLegacy, String approverLegacy) {
        return new Object[]{new UUID(0, index + 1), "B" + index, LocalDate.of(2026, 10, 20), null, null,
                null, "仓库", (short) 0, false, "来源", maker, approver, makerLegacy, approverLegacy, "备注", 1L};
    }
    private UUID employee(String code, String name, boolean deleted) {
        UUID id = UUID.randomUUID(); db.update("INSERT INTO employees(id,code,full_name,is_deleted) VALUES(?,?,?,?)", id, code, name, deleted); return id;
    }
    private UUID user(UUID employee) {
        UUID id = UUID.randomUUID(); db.update("INSERT INTO users(id,employee_id,login_account,is_deleted) VALUES(?,?,?,true)", id, employee, id.toString()); return id;
    }
}
