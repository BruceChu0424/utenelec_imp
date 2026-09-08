package com.uten.imp.application.concurrency;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.SalesMutationFootprintService;
import com.uten.imp.features.stock.FulfillmentInventoryMutationAdapter;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.Duration;
import java.util.List;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;

/** Real transaction/lock mechanics; business value-chain assertions remain in FullChainEndToEndTest. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FulfillmentMutationLocksPostgresTest {
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    static JdbcTemplate jdbc;
    static EntityManagerFactory factory;
    static EntityManager em;
    static TransactionTemplate transactions;
    static FulfillmentMutationLocks locks;
    static InventoryMutationLock inventory;
    static SalesMutationFootprintService sales;

    @BeforeAll static void start() {
        POSTGRES.start();
        var ds = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(ds);
        // Deliberately small SQL schema for lock mechanics, not a migration or finance fixture.
        jdbc.execute("CREATE TABLE sales_orders(id uuid PRIMARY KEY, revision int NOT NULL DEFAULT 0, is_deleted boolean NOT NULL DEFAULT false)");
        jdbc.execute("CREATE TABLE sales_order_items(id uuid PRIMARY KEY,order_id uuid NOT NULL REFERENCES sales_orders(id),goods_id uuid,color_id uuid,is_deleted boolean NOT NULL DEFAULT false)");
        jdbc.execute("CREATE TABLE sales_shipments(id uuid PRIMARY KEY,revision int NOT NULL DEFAULT 0,is_deleted boolean NOT NULL DEFAULT false)");
        jdbc.execute("CREATE TABLE sales_shipment_items(id uuid PRIMARY KEY,shipment_id uuid NOT NULL REFERENCES sales_shipments(id),order_item_id uuid REFERENCES sales_order_items(id),goods_id uuid,color_id uuid,is_deleted boolean NOT NULL DEFAULT false)");
        jdbc.execute("CREATE TABLE production_material_analyses(id uuid PRIMARY KEY)");
        jdbc.execute("CREATE TABLE audit_log(target_type text,target_id text,action text,event_source text,before jsonb)");
        jdbc.execute("""
                CREATE FUNCTION test_insert_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
                INSERT INTO audit_log(target_type,target_id,action,event_source,before)
                  VALUES (TG_TABLE_NAME,NEW.id::text,'insert','database',NULL); RETURN NEW; END $$
                """);
        jdbc.execute("CREATE TRIGGER test_sales_insert AFTER INSERT ON sales_orders FOR EACH ROW EXECUTE FUNCTION test_insert_audit()");
        jdbc.execute("CREATE TRIGGER test_analysis_insert AFTER INSERT ON production_material_analyses FOR EACH ROW EXECUTE FUNCTION test_insert_audit()");
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(ds); bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.sales.order");
        var props = new Properties(); props.setProperty("hibernate.hbm2ddl.auto","none");
        bean.setJpaProperties(props); bean.afterPropertiesSet(); factory = bean.getObject();
        em = SharedEntityManagerCreator.createSharedEntityManager(factory);
        transactions = new TransactionTemplate(new JpaTransactionManager(factory));
        inventory = new InventoryMutationLock(em);
        locks = new FulfillmentMutationLocks(em,new FulfillmentInventoryMutationAdapter(inventory));
        sales = new SalesMutationFootprintService(em,locks);
    }
    @AfterAll static void stop() { if(factory!=null)factory.close(); POSTGRES.stop(); }

    @Test void salesThenWarehouseAndWarehouseThenSalesBothSerializeWithoutGlobalMutex() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            for(boolean salesFirst: List.of(true,false)) {
                var first = fixture(); var unrelated = fixture();
                var acquired = new CountDownLatch(1); var release = new CountDownLatch(1);
                var attempting = new CountDownLatch(1);
                try(var workers=Executors.newFixedThreadPool(3)) {
                    var holder=workers.submit(() -> transactions.executeWithoutResult(tx -> {
                        take(first,salesFirst); acquired.countDown(); await(release);
                        em.createNativeQuery("UPDATE sales_orders SET revision=revision+1 WHERE id=:id")
                                .setParameter("id",first.order).executeUpdate();
                    }));
                    assertTrue(acquired.await(5,TimeUnit.SECONDS));
                    var waiter=workers.submit(() -> transactions.executeWithoutResult(tx -> {
                        attempting.countDown(); take(first,!salesFirst);
                        em.createNativeQuery("UPDATE sales_orders SET revision=revision+1 WHERE id=:id")
                                .setParameter("id",first.order).executeUpdate();
                    }));
                    assertTrue(attempting.await(5,TimeUnit.SECONDS));
                    var independent=workers.submit(() -> transactions.executeWithoutResult(tx -> take(unrelated,true)));
                    independent.get(5,TimeUnit.SECONDS);
                    assertFalse(waiter.isDone(),"same source must wait while unrelated source completes");
                    release.countDown(); holder.get(5,TimeUnit.SECONDS);
                    if (salesFirst) waiter.get(5,TimeUnit.SECONDS);
                    else {
                        // A sales command whose source changed while waiting must not write
                        // with its old fingerprint. A new request can then use the new fact.
                        var stale=assertThrows(java.util.concurrent.ExecutionException.class,()->waiter.get(5,TimeUnit.SECONDS));
                        assertInstanceOf(ApiException.class,stale.getCause());
                        assertEquals(1,jdbc.queryForObject("SELECT revision FROM sales_orders WHERE id=?",Integer.class,first.order));
                        transactions.executeWithoutResult(tx -> {
                            take(first,true);
                            em.createNativeQuery("UPDATE sales_orders SET revision=revision+1 WHERE id=:id")
                                    .setParameter("id",first.order).executeUpdate();
                        });
                    }
                } finally { release.countDown(); }
                assertEquals(2,jdbc.queryForObject("SELECT revision FROM sales_orders WHERE id=?",Integer.class,first.order));
            }
        });
    }

    @Test void changedSourceWhileWaitingRejectsInsteadOfAcquiringAnUndeclaredOrder() throws Exception {
        var old=fixture(); var replacement=fixture(); UUID shipment=UUID.randomUUID(); UUID line=UUID.randomUUID();
        jdbc.update("INSERT INTO sales_shipments(id) VALUES (?)",shipment);
        jdbc.update("INSERT INTO sales_shipment_items(id,shipment_id,order_item_id,goods_id) VALUES (?,?,?,?)",line,shipment,old.item,old.goods);
        var discovered=new CountDownLatch(1); var release=new CountDownLatch(1); var holderReady=new CountDownLatch(1);
        try(var workers=Executors.newFixedThreadPool(2)) {
            var holder=workers.submit(() -> transactions.executeWithoutResult(tx -> {
                em.createNativeQuery("SELECT id FROM sales_orders WHERE id=:id FOR UPDATE").setParameter("id",old.order).getSingleResult();
                holderReady.countDown(); await(release);
                em.createNativeQuery("UPDATE sales_shipment_items SET order_item_id=:replacement,goods_id=:goods WHERE id=:id")
                        .setParameter("replacement",replacement.item).setParameter("goods",replacement.goods).setParameter("id",line).executeUpdate();
            }));
            assertTrue(holderReady.await(5,TimeUnit.SECONDS));
            var instrumented=new FulfillmentMutationLocks(em,new FulfillmentInventoryMutationAdapter(inventory)) {
                @Override public Guard acquire(java.util.function.Supplier<FulfillmentMutationLockPlan> discover) {
                    return super.acquire(() -> {var plan=discover.get(); discovered.countDown();return plan;});
                }
            };
            var waiter=workers.submit(() -> transactions.executeWithoutResult(tx -> {
                new SalesMutationFootprintService(em,instrumented).lockShipment(shipment,List.of());
                em.createNativeQuery("UPDATE sales_shipments SET revision=99 WHERE id=:id").setParameter("id",shipment).executeUpdate();
            }));
            assertTrue(discovered.await(5,TimeUnit.SECONDS)); release.countDown(); holder.get(5,TimeUnit.SECONDS);
            var error=assertThrows(java.util.concurrent.ExecutionException.class,()->waiter.get(5,TimeUnit.SECONDS));
            assertInstanceOf(ApiException.class,error.getCause());
            assertEquals(0,jdbc.queryForObject("SELECT revision FROM sales_shipments WHERE id=?",Integer.class,shipment));
        } finally {release.countDown();}
    }

    @Test void transactionSuspendResumeAndAfterCommitCannotReuseOwnership() {
        var outer=fixture(); var inner=fixture();
        var requiresNew=new TransactionTemplate(transactions.getTransactionManager());
        requiresNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        var afterCommit=new AtomicReference<Throwable>();
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->plan(outer)).verifyUnchanged();
            requiresNew.executeWithoutResult(next -> locks.acquire(()->plan(inner)).verifyUnchanged());
            locks.requireCovered(plan(outer));
            assertThrows(ApiException.class,()->locks.requireCovered(plan(inner)));
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override public void afterCommit() {
                    afterCommit.set(assertThrows(ApiException.class,()->inventory.lockAll(List.of(new InventoryKey(outer.goods,null)))));
                }
            });
        });
        assertNotNull(afterCommit.get());
        transactions.executeWithoutResult(tx -> locks.acquire(()->plan(inner)).verifyUnchanged());
    }

    @Test void undeclaredDimensionAndInventoryBeforeSourcePrefixAreRejected() {
        var f=fixture();
        transactions.executeWithoutResult(tx -> {
            inventory.lockAll(List.of(new InventoryKey(f.goods,null)));
            assertThrows(ApiException.class,()->locks.acquire(()->plan(f)));
        });
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->plan(f)).verifyUnchanged();
            assertThrows(ApiException.class,()->inventory.lockAll(List.of(new InventoryKey(UUID.randomUUID(),null))));
        });
    }

    @Test void uuidOrderMatchesPostgresAcrossSignedBoundaryAndAllItemsAreLocked() {
        UUID low=UUID.fromString("70000000-0000-0000-0000-000000000001");
        UUID high=UUID.fromString("f0000000-0000-0000-0000-000000000001");
        assertTrue(new CommercialSource(CommercialType.SALES_ORDER,low).compareTo(new CommercialSource(CommercialType.SALES_ORDER,high))<0);
        var f=fixture(); UUID otherItem=UUID.randomUUID();
        jdbc.update("INSERT INTO sales_order_items(id,order_id,goods_id) VALUES (?,?,?)",otherItem,f.order,UUID.randomUUID());
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->plan(f)).verifyUnchanged();
            try(var c=jdbc.getDataSource().getConnection();var statement=c.prepareStatement("SELECT id FROM sales_order_items WHERE id=? FOR UPDATE NOWAIT")) {
                c.setAutoCommit(false); statement.setObject(1,otherItem);
                var error=assertThrows(java.sql.SQLException.class,statement::executeQuery);
                assertEquals("55P03",error.getSQLState()); c.rollback();
            } catch(java.sql.SQLException e) {throw new AssertionError(e);}
        });
    }

    @Test void newRowsRequirePriorExpectationAndSameTransactionInsertAudit() {
        UUID warehouse=UUID.randomUUID(); UUID analysis=UUID.randomUUID(); UUID newOrder=UUID.randomUUID();
        var empty=new FulfillmentMutationLockPlan(Set.of(),Set.of(),Set.of(warehouse),Set.of(),"new-rows");
        var source=new CommercialSource(CommercialType.SALES_ORDER,newOrder);
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->empty).verifyUnchanged();
            locks.expectCreatedAnalysis(analysis); locks.expectCreatedSource(source);
            em.createNativeQuery("INSERT INTO production_material_analyses(id) VALUES (:id)").setParameter("id",analysis).executeUpdate();
            em.createNativeQuery("INSERT INTO sales_orders(id) VALUES (:id)").setParameter("id",newOrder).executeUpdate();
            locks.registerCreatedAnalysis(analysis,warehouse); locks.registerCreatedSource(source);
            locks.requireCovered(new FulfillmentMutationLockPlan(Set.of(source),Set.of(),Set.of(warehouse),Set.of(analysis),"new-callback"));
        });
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->empty).verifyUnchanged();
            assertThrows(ApiException.class,()->locks.expectCreatedSource(source));
            em.createNativeQuery("UPDATE sales_orders SET revision=revision+1 WHERE id=:id").setParameter("id",newOrder).executeUpdate();
            assertThrows(ApiException.class,()->locks.registerCreatedSource(source));
        });
    }

    @Test void concurrentInsertThenUpsertDoesNotMasqueradeAsAnOwnNewSource() {
        UUID id=UUID.randomUUID(); var source=new CommercialSource(CommercialType.SALES_ORDER,id);
        var empty=new FulfillmentMutationLockPlan(Set.of(),Set.of(),Set.of(),Set.of(),"collision");
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->empty).verifyUnchanged(); locks.expectCreatedSource(source);
            // Independent connection commits the genuine insertion, after expectation.
            try (var independent=jdbc.getDataSource().getConnection();
                 var insert=independent.prepareStatement("INSERT INTO sales_orders(id) VALUES (?)")) {
                assertTrue(independent.getAutoCommit());
                insert.setObject(1,id); insert.executeUpdate();
            } catch (java.sql.SQLException error) { throw new AssertionError(error); }
            em.createNativeQuery("INSERT INTO sales_orders(id) VALUES (:id) ON CONFLICT(id) DO UPDATE SET revision=1")
                    .setParameter("id",id).executeUpdate();
            assertThrows(ApiException.class,()->locks.registerCreatedSource(source));
            tx.setRollbackOnly();
        });
        assertEquals(0,jdbc.queryForObject("SELECT revision FROM sales_orders WHERE id=?",Integer.class,id));
    }

    static void take(Fixture f,boolean salesCommand) {
        if(salesCommand)sales.lockOrder(f.order,List.of());
        else locks.acquire(()->plan(f)).verifyUnchanged();
    }
    static FulfillmentMutationLockPlan plan(Fixture f) {
        return new FulfillmentMutationLockPlan(Set.of(new CommercialSource(CommercialType.SALES_ORDER,f.order)),
                Set.of(new InventoryDimension(f.goods,null)),Set.of(),Set.of(),"stable-test-source");
    }
    static Fixture fixture() {
        var f=new Fixture(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID());
        jdbc.update("INSERT INTO sales_orders(id) VALUES (?)",f.order);
        jdbc.update("INSERT INTO sales_order_items(id,order_id,goods_id) VALUES (?,?,?)",f.item,f.order,f.goods);
        return f;
    }
    static void await(CountDownLatch latch) {try {if(!latch.await(8,TimeUnit.SECONDS))throw new AssertionError("latch timed out");}catch(InterruptedException e){Thread.currentThread().interrupt();throw new AssertionError(e);}}
    record Fixture(UUID order,UUID item,UUID goods) {}
}
