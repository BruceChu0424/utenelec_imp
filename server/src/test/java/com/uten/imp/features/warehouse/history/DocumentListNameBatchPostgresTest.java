package com.uten.imp.features.warehouse.history;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.hibernate.resource.jdbc.spi.StatementInspector;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import java.sql.Connection;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/** Actual caller SQL and employee lookup work, against rollback-only projections of the migrated schema.
 * Business CHECK/FK/trigger and transaction behavior remains covered by the full-chain suites. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class DocumentListNameBatchPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private JdbcTemplate jdbc;
    private EntityManagerFactory factory;
    private EntityManager em;
    private final List<String> statements = new ArrayList<>();

    @BeforeAll static void baseline() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("b1_list_names");
    }
    @AfterAll static void closeDatabase() throws Exception { if (database != null) database.close(); }
    @BeforeEach void projection() throws Exception {
        connection = database.openConnection();
        connection.setAutoCommit(false);
        try (var statement = connection.createStatement()) {
            statement.execute("CREATE SCHEMA b1_list_name_oracle");
            statement.execute("SET LOCAL search_path=b1_list_name_oracle,public");
        }
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                "employees", "users", "departments", "purchase_receipts", "purchase_receipt_items", "subcontract_receipts",
                "subcontract_receipt_items", "subcontract_material_issues", "subcontract_material_issue_items",
                "subcontract_returns", "subcontract_return_items", "subcontract_material_returns",
                "subcontract_material_return_items", "subcontract_wastes", "subcontract_waste_items",
                "subcontract_short_delivery_cases", "subcontract_order_items", "procurement_inspection_items",
                "suppliers", "warehouses", "goods", "colors", "units");
        var source = new SingleConnectionDataSource(connection, true);
        jdbc = new JdbcTemplate(source);
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.common.util");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none",
                "hibernate.session_factory.statement_inspector", (StatementInspector) sql -> {
                    statements.add(sql); return sql;
                }));
        bean.afterPropertiesSet();
        factory = bean.getObject();
        em = factory.createEntityManager();
        statements.clear();
    }
    @AfterEach void rollback() throws Exception {
        if (em != null) em.close();
        if (factory != null) factory.close();
        if (connection != null) { connection.rollback(); connection.close(); }
    }

    @ParameterizedTest @EnumSource(WarehouseHistoryType.class)
    void hundredPhysicalHistoryRowsHaveOneNameQueryAndKeepEveryRowSnapshot(WarehouseHistoryType type) {
        UUID maker = employee("maker", "当前制单人", true), approver = employee("approver", "当前审核人", false);
        UUID missing = UUID.randomUUID();
        List<UUID> expected = new ArrayList<>();
        for (int i = 0; i < 100; i++) {
            UUID header = UUID.randomUUID(); expected.add(header);
            jdbc.update("INSERT INTO " + type.headerTable()
                    + "(id,bill_no,bill_date,status,is_closed,is_deleted,maker_id,approver_id,source_doc_no)"
                    + " VALUES(?,?,'2026-01-01',1,TRUE,FALSE,?,?,?)", header, String.format("H%03d", i),
                    i < 2 ? missing : maker, approver, "0001. 原始来源");
            if (type != WarehouseHistoryType.SUBCONTRACT_WASTE)
                jdbc.update("UPDATE " + type.headerTable() + " SET maker_name=?,approver_name=? WHERE id=?",
                        "冻结制单人" + i, "冻结审核人", header);
            jdbc.update("INSERT INTO " + type.itemTable() + "(id," + type.itemForeignKey()
                    + ",line_no,qty,goods_code_snapshot,goods_name_snapshot,is_deleted) VALUES(?,?,1,0.0001,'001','实物',FALSE)",
                    UUID.randomUUID(), header);
        }
        var scopes = mock(WarehouseTaskScopePort.class);
        when(scopes.current(null)).thenReturn(WarehouseTaskScope.ALL);
        var service = new WarehouseHistoryQueryService(em, new EmployeeNameResolver(em), scopes);

        var result = service.list(type, "", null, null, null, 1, 100, "billNo", "asc", null, null);

        assertThat(result.getTotal()).isEqualTo(100);
        assertThat(result.getItems()).extracting(WarehouseHistoryListItem::id).containsExactlyElementsOf(expected);
        assertThat(result.getItems()).extracting(WarehouseHistoryListItem::approverName).containsOnly("当前审核人");
        if (type == WarehouseHistoryType.SUBCONTRACT_WASTE) {
            // This real source has no frozen maker/approver columns; its reader explicitly projects NULL.
            assertThat(result.getItems().get(0).makerName()).isNull();
            assertThat(result.getItems().get(1).makerName()).isNull();
        } else {
            assertThat(result.getItems().get(0).makerName()).isEqualTo("冻结制单人0");
            assertThat(result.getItems().get(1).makerName()).isEqualTo("冻结制单人1");
        }
        assertThat(result.getItems().subList(2, 100)).extracting(WarehouseHistoryListItem::makerName).containsOnly("当前制单人");
        assertThat(result.getItems()).allSatisfy(row -> {
            assertThat(row.sourceDocumentNo()).isEqualTo("0001. 原始来源");
            assertThat(row.line().quantity()).isEqualByComparingTo("0.0001");
        });
        assertThat(nameStatements()).hasSize(1);
        assertThat(statements).hasSize(3); // count + physical rows + one bounded name read

        jdbc.update("UPDATE employees SET full_name='改名后的当前事实' WHERE id=?", maker);
        statements.clear();
        assertThat(service.list(type, "", null, null, null, 1, 100).getItems())
                .filteredOn(item -> maker.equals(item.makerId()))
                .extracting(WarehouseHistoryListItem::makerName).containsOnly("改名后的当前事实");
        assertThat(nameStatements()).hasSize(1);
    }

    @Test void twoHundredShortDeliveryRowsAndFourHundredNamesUseTwoBoundedNameQueries() {
        UUID goods = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name) VALUES(?,'001','原始物料')", goods);
        for (int i = 0; i < 200; i++) {
            UUID item = UUID.randomUUID(), order = UUID.randomUUID();
            UUID owner = employee("owner" + i, "负责人" + i, i % 2 == 0);
            UUID decider = employee("decider" + i, "判定人" + i, false);
            jdbc.update("INSERT INTO subcontract_order_items(id,line_no) VALUES(?,1)", item);
            jdbc.update("INSERT INTO subcontract_short_delivery_cases(id,order_id,order_item_id,goods_id,order_bill_no_snapshot,"
                    + "status,severity,owner_employee_id,decided_by_employee_id,ordered_qty,shortfall_qty,version)"
                    + " VALUES(?,?,?,?,?,'PENDING_OWNER','SEVERE',?,?,19.0001,0.0001,7)",
                    UUID.randomUUID(), order, item, goods, String.format("SC%03d", i), owner, decider);
        }
        var access = mock(SubcontractDocumentAccessPolicy.class);
        when(access.nativeReadScope("c.owner_employee_id", "owners", "subcontract_order:view"))
                .thenReturn(new NativeReadScope("TRUE", null, Set.of()));
        var service = new SubcontractShortDeliveryService(jdbc, em, null, null, null, access,
                null, null, null, new EmployeeNameResolver(em), null);

        var result = service.list("PENDING", "", null, null, null, null, 1, 200, "orderBillNo", "asc", null);

        assertThat(result.getTotal()).isEqualTo(200);
        assertThat(result.getItems()).hasSize(200).allSatisfy(row -> {
            assertThat(row.ownerName()).startsWith("负责人");
            assertThat(row.decidedByName()).startsWith("判定人");
            assertThat(row.orderedQty()).isEqualByComparingTo("19.0001");
            assertThat(row.shortfallQty()).isEqualByComparingTo("0.0001");
            assertThat(row.version()).isEqualTo(7);
            assertThat(row.canDecide()).isFalse();
        });
        assertThat(nameStatements()).hasSize(2);
        assertThat(statements).hasSize(4); // rows + two batches of <=256 ids + count
    }

    private List<String> nameStatements() {
        return statements.stream().filter(sql -> sql.contains("WITH requested_ids")).toList();
    }

    @Test void departmentBatchesUseActualMigratedTypesAndPreserveDeletedAndUnknownBehavior() {
        List<UUID> ids = new ArrayList<>(); UUID deleted = UUID.randomUUID();
        for (int i = 0; i < 300; i++) {
            UUID id = UUID.randomUUID(); ids.add(id);
            jdbc.update("INSERT INTO departments(id,code,name,is_deleted) VALUES(?,?,?,false)", id, "D" + i, "部门" + i);
        }
        jdbc.update("INSERT INTO departments(id,code,name,is_deleted) VALUES(?,'OLD','历史部门',true)", deleted);
        ids.add(deleted); ids.add(UUID.randomUUID()); ids.add(null); ids.add(ids.getFirst());
        var resolver = new com.uten.imp.common.util.DepartmentNameResolver(em);
        var names = resolver.namesOf(ids);
        assertThat(names).hasSize(300).doesNotContainKey(deleted);
        assertThat(statements).hasSize(2).allSatisfy(sql -> assertThat(sql).contains("FROM departments"));
    }
    private UUID employee(String code, String name, boolean deleted) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,is_deleted) VALUES(?,?,?,?)", id, code, name, deleted);
        return id;
    }
}
