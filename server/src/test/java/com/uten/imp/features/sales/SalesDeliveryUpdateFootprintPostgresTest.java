package com.uten.imp.features.sales;

import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.concurrency.FulfillmentSourceConflictException;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.features.stock.FulfillmentInventoryMutationAdapter;
import com.uten.imp.features.stock.InventoryMutationLock;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real SQL discovery and original S/I/fingerprint guards; no migrated business/value-chain claim. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SalesDeliveryUpdateFootprintPostgresTest {
    static final PostgreSQLContainer POSTGRES=new PostgreSQLContainer("postgres:16-alpine");
    static DriverManagerDataSource dataSource;
    static JdbcTemplate db;
    static EntityManagerFactory factory;
    static EntityManager em;
    static TransactionTemplate transactions;
    static FulfillmentInventoryMutationAdapter inventory;
    @BeforeAll static void start() {
        POSTGRES.start();dataSource=new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());db=new JdbcTemplate(dataSource);
        // Complete migrated columns/defaults; retain this oracle's original keys and constraints.
        MigratedProjectionSchema.createCurrentColumns(db,
                "sales_orders", "sales_order_items", "goods", "goods_bom_items", "goods_bom_delivery_rules");
        db.execute("""
                ALTER TABLE sales_orders ADD PRIMARY KEY (id);
                ALTER TABLE sales_order_items ADD PRIMARY KEY (id);
                ALTER TABLE goods ADD PRIMARY KEY (id);
                ALTER TABLE goods_bom_items ADD PRIMARY KEY (id);
                ALTER TABLE goods_bom_delivery_rules ADD PRIMARY KEY (bom_edge_id);
                """);
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(dataSource);bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.sales.order");var properties=new Properties();properties.setProperty("hibernate.hbm2ddl.auto","none");
        bean.setJpaProperties(properties);bean.afterPropertiesSet();factory=bean.getObject();em=SharedEntityManagerCreator.createSharedEntityManager(factory);
        transactions=new TransactionTemplate(new JpaTransactionManager(factory));inventory=new FulfillmentInventoryMutationAdapter(new InventoryMutationLock(em));
    }
    @AfterAll static void stop() {
        if (factory != null) {
            factory.close();
        }
        POSTGRES.stop();
    }
    private record World(UUID order,UUID item,UUID root,UUID child,UUID edge) {}
    private World world() {
        UUID order=UUID.randomUUID(),item=UUID.randomUUID(),root=UUID.randomUUID(),child=UUID.randomUUID(),edge=UUID.randomUUID();
        db.update("INSERT INTO sales_orders(id) VALUES(?)",order);
        db.update("INSERT INTO goods(id) VALUES(?),(?)",root,child);
        db.update("INSERT INTO sales_order_items(id,order_id,goods_id,delivery_plan) VALUES(?,?,?,'{\"mode\":\"ASSEMBLED\",\"processes\":[]}')",item,order,root);
        db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,consumption_basis,basis_output_qty,allow_partial_package) VALUES(?,?,?,1,'PER_UNIT',1,true)",edge,root,child);
        return new World(order,item,root,child,edge);
    }
    private SalesMutationFootprintService service(
            AtomicReference<Set<InventoryDimension>> taken, DiscoveryBarrier afterDiscovery) {
        var locks = new FulfillmentMutationLocks(em, dimensions -> {
            taken.set(Set.copyOf(dimensions));
            inventory.lockDimensions(dimensions);
            if (afterDiscovery != null) {
                afterDiscovery.pause();
            }
        }, true);
        var sales = new SalesMutationFootprintService(em, locks);
        ReflectionTestUtils.setField(sales, "masterReferences", mock(MasterReferenceValidationPort.class));
        return sales;
    }

    private record DiscoveryBarrier(CountDownLatch discovered, CountDownLatch mutationComplete) {
        private void pause() {
            discovered.countDown();
            await(mutationComplete);
        }
    }

    private static void await(CountDownLatch latch) {
        try {
            if (!latch.await(30, TimeUnit.SECONDS)) {
                throw new IllegalStateException("Concurrent fixture mutation did not reach its barrier");
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(interrupted);
        }
    }
    @Test void ordinaryIntentDoesNotAcquireItsUnrelatedBomInventory() {
        var w=world();var taken=new AtomicReference<Set<InventoryDimension>>();
        transactions.executeWithoutResult(tx->service(taken,null).lockOrderUpdate(w.order(),List.of(new SalesMutationFootprintService.ProposedOrderLine(w.root(),null,false))));
        assertThat(taken.get()).containsExactly(new InventoryDimension(w.root(),null));
    }
    @Test void proposedBomAndOldPhysicalSnapshotAreCoveredBeforeNestedApproval() {
        var w=world();UUID oldChild=UUID.randomUUID();db.update("INSERT INTO goods(id) VALUES(?)",oldChild);
        db.update("UPDATE sales_order_items SET delivery_plan='{\"mode\":\"BOM\"}',delivery_bom_snapshot=CAST(? AS jsonb) WHERE id=?",
                snapshot(w.root(),oldChild),w.item());
        var taken=new AtomicReference<Set<InventoryDimension>>();var sales=service(taken,null);
        transactions.executeWithoutResult(tx->{
            sales.lockOrderUpdate(w.order(),List.of(new SalesMutationFootprintService.ProposedOrderLine(w.root(),null,true)));
            em.createNativeQuery("UPDATE sales_order_items SET delivery_bom_snapshot=CAST(:snapshot AS jsonb) WHERE id=:id")
                    .setParameter("snapshot",snapshot(w.root(),w.child())).setParameter("id",w.item()).executeUpdate();
            sales.lockOrder(w.order(),List.of()); // Strict nested discovery sees the newly persisted recipe.
        });
        assertThat(taken.get()).containsExactlyInAnyOrder(new InventoryDimension(w.root(),null),new InventoryDimension(w.child(),null),new InventoryDimension(oldChild,null));
    }
    @Test void newMasterRequiredWorkExpandsDefaultAssembledBeforeItBecomesPhysical() {
        var w=world();db.update("INSERT INTO goods_bom_delivery_rules(bom_edge_id,required_operations) VALUES(?,'[\"LASER\"]')",w.edge());
        var taken=new AtomicReference<Set<InventoryDimension>>();var sales=service(taken,null);
        transactions.executeWithoutResult(tx->{
            sales.lockOrderUpdate(w.order(),List.of(new SalesMutationFootprintService.ProposedOrderLine(w.root(),null,false)));
            em.createNativeQuery("UPDATE sales_order_items SET delivery_plan='{\"mode\":\"ASSEMBLED\",\"processes\":[{\"required\":true}]}'::jsonb,delivery_bom_snapshot=CAST(:snapshot AS jsonb) WHERE id=:id")
                    .setParameter("snapshot",snapshot(w.root(),w.child())).setParameter("id",w.item()).executeUpdate();
            sales.lockOrder(w.order(),List.of());
        });
        assertThat(taken.get()).containsExactlyInAnyOrder(new InventoryDimension(w.root(),null),new InventoryDimension(w.child(),null));
    }
    @Test void periodicCustomerDeliveryCandidatesKeepConfigurationAndHistoricalLocks() {
        var w=world();UUID periodic=UUID.randomUUID(),descendant=UUID.randomUUID(),historical=UUID.randomUUID();
        UUID periodicEdge=UUID.randomUUID(),nestedEdge=UUID.randomUUID();
        db.update("INSERT INTO goods(id,issue_method) VALUES(?,'PERIODIC'),(?,'PER_ORDER'),(?,'PERIODIC')",periodic,descendant,historical);
        db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,consumption_basis,basis_output_qty,allow_partial_package) VALUES(?,?,?,1,'PER_UNIT',1,true),(?,?,?,1,'PER_UNIT',1,true)",
                periodicEdge,w.root(),periodic,nestedEdge,periodic,descendant);
        var taken=new AtomicReference<Set<InventoryDimension>>();var sales=service(taken,null);
        transactions.executeWithoutResult(tx->sales.lockOrderUpdate(w.order(),List.of(new SalesMutationFootprintService.ProposedOrderLine(w.root(),null,false))));
        assertThat(taken.get()).containsExactly(new InventoryDimension(w.root(),null));
        // A not-yet-reviewed BOM choice can select PERIODIC customer goods;
        // discover the complete candidate graph before any source/inventory lock.
        transactions.executeWithoutResult(tx->sales.lockOrderUpdate(w.order(),List.of(new SalesMutationFootprintService.ProposedOrderLine(w.root(),null,true))));
        assertThat(taken.get()).containsExactlyInAnyOrder(new InventoryDimension(w.root(),null),new InventoryDimension(w.child(),null),
                new InventoryDimension(periodic,null),new InventoryDimension(descendant,null));
        db.update("INSERT INTO goods_bom_delivery_rules(bom_edge_id,required_operations) VALUES(?,'[\"LASER\"]')",periodicEdge);
        transactions.executeWithoutResult(tx->sales.lockOrderUpdate(w.order(),List.of(new SalesMutationFootprintService.ProposedOrderLine(w.root(),null,false))));
        assertThat(taken.get()).containsExactlyInAnyOrder(new InventoryDimension(w.root(),null),new InventoryDimension(w.child(),null),
                new InventoryDimension(periodic,null),new InventoryDimension(descendant,null));
        // Prior reviewed physical facts remain protected even when the current
        // recipe no longer contains that old PERIODIC component.
        db.update("UPDATE sales_order_items SET delivery_plan='{\"mode\":\"BOM\"}',delivery_bom_snapshot=CAST(? AS jsonb) WHERE id=?",
                snapshot(w.root(),historical),w.item());
        transactions.executeWithoutResult(tx->sales.lockOrderUpdate(w.order(),List.of(new SalesMutationFootprintService.ProposedOrderLine(w.root(),null,true))));
        assertThat(taken.get()).containsExactlyInAnyOrder(new InventoryDimension(w.root(),null),new InventoryDimension(w.child(),null),
                new InventoryDimension(periodic,null),new InventoryDimension(descendant,null),new InventoryDimension(historical,null));
    }
    @Test void changedAuthoritativeEdgeColorFailsTheOriginalPrewriteFingerprintAndCanRetryFresh() throws Exception {
        var w = world();
        UUID changedColor = UUID.randomUUID();
        var taken = new AtomicReference<Set<InventoryDimension>>();
        var barrier = new DiscoveryBarrier(new CountDownLatch(1), new CountDownLatch(1));
        // The lock port observes/blocks only. The competing transaction belongs
        // to a separate fixture worker, never to the production lock call graph.
        try (var writer = Executors.newSingleThreadExecutor()) {
            var mutation = writer.submit(() -> {
                try {
                    await(barrier.discovered());
                    try (var connection = dataSource.getConnection();
                         var update = connection.prepareStatement("UPDATE goods_bom_items SET color_id=? WHERE id=?")) {
                        update.setObject(1, changedColor);
                        update.setObject(2, w.edge());
                        update.executeUpdate();
                    }
                } catch (java.sql.SQLException failure) {
                    throw new IllegalStateException(failure);
                } finally {
                    barrier.mutationComplete().countDown();
                }
            });
            var sales = service(taken, barrier);
            var failure = catchThrowable(() -> transactions.executeWithoutResult(tx ->
                    sales.lockOrderUpdate(w.order(), List.of(
                            new SalesMutationFootprintService.ProposedOrderLine(w.root(), null, true)))));
            mutation.get(30, TimeUnit.SECONDS);
            assertThat(failure).isInstanceOfSatisfying(FulfillmentSourceConflictException.class, ex -> {
                assertThat(ex.retryable()).isTrue();
                assertThat(ex.reason()).isEqualTo(FulfillmentSourceConflictException.Reason.PRE_WRITE_SOURCE_CHANGED);
            });
        } finally {
            barrier.discovered().countDown();
        }
        transactions.executeWithoutResult(tx -> service(taken, null).lockOrderUpdate(w.order(), List.of(
                new SalesMutationFootprintService.ProposedOrderLine(w.root(), null, true))));
        assertThat(taken.get()).contains(new InventoryDimension(w.child(), changedColor))
                .doesNotContain(new InventoryDimension(w.child(), null));
    }
    private static String snapshot(UUID root,UUID child){return "{\"root\":{\"goodsId\":\""+root+"\",\"children\":[{\"goodsId\":\""+child+"\"}]}}";}
}
