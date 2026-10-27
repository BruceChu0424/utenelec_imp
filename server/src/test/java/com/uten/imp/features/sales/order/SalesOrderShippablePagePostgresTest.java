package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.dto.ShippableLineFilter;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.sql.Connection;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real scoped paging/selection and physical reservation arithmetic; all facts are rollback-only projections. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SalesOrderShippablePagePostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private EntityManagerFactory factory;
    private EntityManager em;
    private JdbcTemplate jdbc;
    private SalesOrderService service;
    private final UUID owner = UUID.randomUUID(), readOnly = UUID.randomUUID();
    private final UUID client = UUID.randomUUID(), otherClient = UUID.randomUUID(), goods = UUID.randomUUID();

    @BeforeAll static void baseline() throws Exception { database = MigratedSchemaBaseline.openDatabase("b1_shippable_pages"); }
    @AfterAll static void close() throws Exception { if (database != null) database.close(); }
    @BeforeEach void fixture() throws Exception {
        connection = database.openConnection(); connection.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);
        connection.setAutoCommit(false);
        try (var statement = connection.createStatement()) {
            statement.execute("CREATE SCHEMA shippable_page_oracle");
            statement.execute("SET LOCAL search_path=shippable_page_oracle,public");
        }
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                "sales_orders", "sales_order_items", "sales_shipments", "sales_shipment_items", "stock_reservations", "clients", "goods");
        var source = new SingleConnectionDataSource(connection, true); jdbc = new JdbcTemplate(source);
        var bean = new LocalContainerEntityManagerFactoryBean(); bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter()); bean.setPackagesToScan("com.uten.imp.common.util");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none")); bean.afterPropertiesSet();
        factory = bean.getObject(); em = factory.createEntityManager();
        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), owner, "reader",
                Set.of("sales_order:view", "sales_shipment:create"), false, true, false)));
        var owners = mock(OwnerVisibility.class);
        when(owners.evaluate("sales", "sales:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(owner, readOnly), Set.of(owner)));
        service = mock(SalesOrderService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "em", em);
        ReflectionTestUtils.setField(service, "accessPolicy", new SalesDocumentAccessPolicy(owners, current));
        ReflectionTestUtils.setField(service, "priceMasker", new SalesPriceMasker(current));
        jdbc.update("INSERT INTO clients(id,code,name) VALUES(?,'C','客户甲'),(?,'D','客户乙')", client, otherClient);
        jdbc.update("INSERT INTO goods(id,code,name) VALUES(?,'A%_B','螺丝 A%_B')", goods);
    }
    @AfterEach void rollback() throws Exception {
        if (em != null) {
            em.close();
        }
        if (factory != null) {
            factory.close();
        }
        if (connection != null) { connection.rollback(); connection.close(); }
    }

    @Test void tiedRowsStaySeparateAcrossPagesAndSelectAllIncludesAllWritableMatches() {
        List<UUID> expected = new ArrayList<>();
        for (int i = 0; i < 205; i++) expected.add(line(i + 1, owner, client));
        for (int i = 205; i < 235; i++) line(i + 1, readOnly, client);
        Set<UUID> seen = new HashSet<>();
        for (int page = 1; page <= 3; page++) {
            var result = service.shippableLinesPage(null, page, 100);
            assertThat(result.getTotal()).isEqualTo(235); assertThat(result.getItems()).hasSize(page < 3 ? 100 : 35);
            result.getItems().forEach(row -> assertThat(seen.add(row.orderItemId())).isTrue());
            assertThat(result.getItems()).allSatisfy(row -> assertThat(row.price()).isNull());
        }
        var selected = service.shippableLinesSelection(null);
        assertThat(selected.getTotal()).isEqualTo(205);
        assertThat(selected.getItems()).extracting(row -> row.orderItemId()).containsExactlyElementsOf(expected);
        assertThat(selected.getItems()).allSatisfy(row -> {
            assertThat(row.writable()).isTrue(); assertThat(row.price()).isNull();
            assertThat(row.qty()).isEqualByComparingTo("5.0001"); assertThat(row.unitRate()).isEqualByComparingTo("1.25");
            assertThat(row.reservedQty()).isEqualByComparingTo("2.0000");
        });
    }

    @Test void keywordAndClientFiltersUseLiteralTermsAndKeepPhysicalDraftAllocation() {
        UUID first = line(1, owner, client), second = line(2, owner, otherClient);
        UUID header = UUID.randomUUID();
        jdbc.update("INSERT INTO sales_shipments(id,status,is_deleted,rejected) VALUES(?,0,false,false)", header);
        jdbc.update("INSERT INTO sales_shipment_items(id,shipment_id,order_item_id,qty,is_deleted) VALUES(?,?,?,?,false)",
                UUID.randomUUID(), header, first, new BigDecimal("0.2500"));
        var filter = new ShippableLineFilter("螺丝 A%_B", client);
        var page = service.shippableLinesPage(filter, 1, 100);
        assertThat(page.getTotal()).isEqualTo(1); assertThat(page.getItems().getFirst().orderItemId()).isEqualTo(first);
        assertThat(page.getItems().getFirst().reservedQty()).isEqualByComparingTo("1.7500");
        assertThat(service.shippableLinesSelection(filter).getItems()).extracting(row -> row.orderItemId()).containsExactly(first);
        assertThat(service.shippableLinesPage(new ShippableLineFilter("螺丝 AXZB", null), 1, 100).getTotal()).isZero();
        assertThat(service.shippableLinesPage(new ShippableLineFilter(null, otherClient), 1, 100).getItems())
                .extracting(row -> row.orderItemId()).containsExactly(second);
        jdbc.update("UPDATE goods SET name='当前显示的新名称' WHERE id=?", goods);
        assertThat(service.shippableLinesPage(new ShippableLineFilter("当前显示的新名称", client), 1, 100).getTotal()).isEqualTo(1);
        assertThat(service.shippableLinesPage(filter, 1, 100).getTotal()).isEqualTo(1); // Original snapshots remain searchable.
        jdbc.update("UPDATE sales_orders SET finance_confirmed=false WHERE id=(SELECT order_id FROM sales_order_items WHERE id=?)", first);
        assertThat(service.shippableLinesPage(filter, 1, 100).getTotal()).isZero();
    }

    @Test void oversizedGlobalSelectionIsRefusedWhilePagedBrowsingRemainsAvailable() {
        for (int i = 0; i < 501; i++) line(i + 1, owner, client);
        assertThatThrownBy(() -> service.shippableLinesSelection(null)).isInstanceOf(ApiException.class).hasMessageContaining("500");
        assertThatThrownBy(service::shippableLines).isInstanceOf(ApiException.class).hasMessageContaining("分页");
        var page = service.shippableLinesPage(null, 6, 100);
        assertThat(page.getItems()).hasSize(1); assertThat(page.getTotal()).isEqualTo(501); assertThat(page.getTotalPages()).isEqualTo(6);
    }

    private UUID line(int sequence, UUID responsible, UUID clientId) {
        UUID order = new UUID(1, sequence), item = new UUID(2, sequence);
        jdbc.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,owner_employee_id,status,is_closed,is_stopped,finance_confirmed,finance_rejected,is_deleted)"
                + " VALUES(?,'SO-TIED','2026-01-01',?,?,1,false,false,true,false,false)", order, clientId, responsible);
        jdbc.update("INSERT INTO sales_order_items(id,order_id,line_no,goods_id,goods_code_snapshot,goods_name_snapshot,qty,unit_rate,reserved_qty,shipped_qty,returned_qty,flag_qty,price,is_deleted)"
                + " VALUES(?,?,1,?,'A%_B','螺丝 A%_B',5.0001,1.25,2,0,0,0,99.9999,false)", item, order, goods);
        jdbc.update("INSERT INTO stock_reservations(id,order_item_id,qty,consumed_qty,released_qty,status,is_deleted)"
                + " VALUES(?,?,2.5,0,0,0,false)", UUID.randomUUID(), item);
        return item;
    }
}
