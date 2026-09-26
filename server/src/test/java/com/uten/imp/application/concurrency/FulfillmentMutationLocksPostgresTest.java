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
    static JpaTransactionManager manager;
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
        // 新建来源登记只凭本事务行版本(xmin)判定, 不依赖审计日志(db-schema-02): 这里刻意没有审计表和触发器。
        jdbc.execute("CREATE TABLE production_material_analyses(id uuid PRIMARY KEY, analysis_no text)");
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(ds); bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setJpaDialect(new com.uten.imp.support.NativeSavepointJpaDialect());
        bean.setPackagesToScan("com.uten.imp.features.sales.order");
        var props = new Properties(); props.setProperty("hibernate.hbm2ddl.auto","none");
        bean.setJpaProperties(props); bean.afterPropertiesSet(); factory = bean.getObject();
        em = SharedEntityManagerCreator.createSharedEntityManager(factory);
        manager = new JpaTransactionManager(factory);
        manager.setNestedTransactionAllowed(true);
        transactions = new TransactionTemplate(manager);
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
                @Override public Guard acquire(FulfillmentMutationLockPlan declared,
                        java.util.function.Supplier<FulfillmentMutationLockPlan> discover) {
                    return super.acquire(declared,() -> {var plan=discover.get(); discovered.countDown();return plan;});
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

    @Test void savepointRetainsTheEarlierPrefixButDropsRolledBackNewSourceExpectations() {
        var original = fixture();
        var newSource = new CommercialSource(CommercialType.SALES_ORDER, UUID.randomUUID());
        transactions.executeWithoutResult(tx -> {
            locks.acquire(() -> plan(original)).verifyUnchanged();
            Object savepoint = tx.createSavepoint();
            locks.expectCreatedSource(newSource);
            em.createNativeQuery("INSERT INTO sales_orders(id) VALUES (:id)").setParameter("id", newSource.id()).executeUpdate();
            assertTrue(FulfillmentLockState.current(false).expectedNewSources.contains(newSource));
            var added = new FulfillmentMutationLockPlan(Set.of(newSource), Set.of(), Set.of(), Set.of(), "added");
            assertThrows(ApiException.class, () -> locks.requireCovered(added), "Expectation alone is never ownership");
            tx.rollbackToSavepoint(savepoint);
            locks.requireCovered(plan(original));
            inventory.requireHeld(new InventoryKey(original.goods, null));
            assertOrderLocked(original.order, true);
            assertThrows(ApiException.class, () -> locks.requireCovered(added));
            assertFalse(FulfillmentLockState.current(false).expectedNewSources.contains(newSource));
            assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM sales_orders WHERE id=?", Integer.class, newSource.id()));
        });
    }

    @Test void prefixCreatedAfterSavepointCannotProveOwnershipUntilTheWholePrefixIsReacquired() {
        var source = fixture();
        transactions.executeWithoutResult(tx -> {
            Object savepoint = tx.createSavepoint();
            var old = locks.acquire(() -> plan(source)); old.verifyUnchanged();
            assertOrderLocked(source.order, true);
            tx.rollbackToSavepoint(savepoint);
            assertOrderLocked(source.order, false);
            assertThrows(ApiException.class, () -> locks.requireCovered(plan(source)));
            assertThrows(ApiException.class, old::verifyUnchanged);
            assertThrows(IllegalStateException.class, () -> inventory.requireHeld(new InventoryKey(source.goods, null)));
            locks.acquire(() -> plan(source)).verifyUnchanged();
            inventory.requireHeld(new InventoryKey(source.goods, null));
            assertOrderLocked(source.order, true);
        });
    }

    private static void assertOrderLocked(UUID id, boolean expected) {
        try (var connection = jdbc.getDataSource().getConnection()) {
            connection.setAutoCommit(false);
            try (var statement = connection.prepareStatement("SELECT id FROM sales_orders WHERE id=? FOR UPDATE NOWAIT")) {
                statement.setObject(1, id);
                try { statement.executeQuery().close(); assertFalse(expected); }
                catch (java.sql.SQLException failure) { assertEquals("55P03", failure.getSQLState()); assertTrue(expected); }
            } finally { connection.rollback(); }
        } catch (java.sql.SQLException failure) { throw new AssertionError(failure); }
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

    @Test void newRowsRequirePriorExpectationAndThisTransactionsRowVersion() {
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

    /**
     * 期望新建之后别的事务抢先提交了同一 UUID: 约定的普通 INSERT 撞主键唯一约束失败, 整笔回滚,
     * 根本走不到登记——不需要审计日志做证据(db-schema-02)。upsert 不是受支持的新建方式。
     */
    @Test void concurrentInsertOfTheExpectedUuidIsRejectedByThePlainInsert() {
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
            assertThrows(jakarta.persistence.PersistenceException.class,()->em.createNativeQuery(
                    "INSERT INTO sales_orders(id) VALUES (:id)").setParameter("id",id).executeUpdate());
            tx.setRollbackOnly();
        });
        assertEquals(0,jdbc.queryForObject("SELECT revision FROM sales_orders WHERE id=?",Integer.class,id));
    }

    /** ADR-107: 嵌套 acquire 不再跑发现, 只按声明的已知 id 在内存里查覆盖; 超出是结构性缺口, 不重跑。 */
    @Test void nestedAcquireChecksDeclaredIdsInMemoryWithoutDiscovery() {
        var f=fixture(); var outside=fixture();
        var discoveries=new java.util.concurrent.atomic.AtomicInteger();
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->{discoveries.incrementAndGet();return plan(f);}).verifyUnchanged();
            assertEquals(2,discoveries.get(),"One discovery plus one post-lock version recheck");
            var nested=locks.acquire(plan(f),()->{throw new AssertionError("nested discovery must not run");});
            nested.verifyUnchanged();
            assertEquals(2,discoveries.get(),"The transaction verifies its prefix exactly once");
            var gap=assertThrows(FulfillmentSourceConflictException.class,
                    ()->locks.acquire(plan(outside),()->{throw new AssertionError("nested discovery must not run");}));
            assertFalse(gap.retryable(),"A declared id outside the prelock is a coding gap, never retried");
            var callback=assertThrows(FulfillmentSourceConflictException.class,()->locks.requireCovered(plan(outside)));
            assertFalse(callback.retryable());
        });
    }

    /** 取锁的守卫复核一次后, 再复核、嵌套 acquire 都不再读库。 */
    @Test void ownerRechecksOnceAndNestedAcquiresNeverRediscover() {
        var f=fixture();
        var discoveries=new java.util.concurrent.atomic.AtomicInteger();
        transactions.executeWithoutResult(tx -> {
            var outer=locks.acquire(()->{discoveries.incrementAndGet();return plan(f);});
            assertEquals(1,discoveries.get(),"The owner may still return an immutable replay before rechecking");
            outer.verifyUnchanged(); outer.verifyUnchanged();
            locks.acquire(plan(f),()->{throw new AssertionError("nested discovery must not run");}).verifyUnchanged();
            assertEquals(2,discoveries.get());
        });
    }

    /**
     * 取锁的命令从没复核就写了、再进入嵌套命令(只为给嵌套出库预锁的入口): 第一个嵌套 acquire 替它做一次
     * 锁后覆盖复核——只要求重读的足迹仍落在已持有集合内, 不把自己的写入误判成来源变化; 之后不再读库。
     */
    @Test void unverifiedOwnerIsCoverageRecheckedByTheFirstNestedAcquireAfterItsOwnWrites() {
        var f=fixture(); var other=fixture();
        var discoveries=new java.util.concurrent.atomic.AtomicInteger();
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->{discoveries.incrementAndGet();return plan(f);});
            em.createNativeQuery("UPDATE sales_orders SET revision=revision+1 WHERE id=:id").setParameter("id",f.order).executeUpdate();
            locks.acquire(()->{throw new AssertionError("nested discovery must not run");}).verifyUnchanged();
            locks.acquire(plan(f),()->{throw new AssertionError("nested discovery must not run");}).verifyUnchanged();
            assertEquals(2,discoveries.get(),"One coverage recheck for the whole transaction");
        });
        var grown=new java.util.concurrent.atomic.AtomicBoolean();
        var drift=assertThrows(FulfillmentSourceConflictException.class,()->transactions.executeWithoutResult(tx -> {
            locks.acquire(()->grown.getAndSet(true)?withOrder(plan(f),other):plan(f));
            locks.acquire(()->{throw new AssertionError("nested discovery must not run");});
        }));
        assertTrue(drift.retryable(),"A footprint that grew after the pre-read is transient drift, re-run from scratch");
    }

    private static FulfillmentMutationLockPlan withOrder(FulfillmentMutationLockPlan plan,Fixture extra) {
        var sources=new java.util.HashSet<>(plan.commercialSources());
        sources.add(new CommercialSource(CommercialType.SALES_ORDER,extra.order));
        return new FulfillmentMutationLockPlan(sources,plan.inventoryDimensions(),plan.mainWarehouseIds(),plan.analysisIds(),"grown");
    }

    /**
     * ADR-107 + 评审: 主仓协调锁仍在数据库锁管理器里排队(不再轮询), 等待上限就是连接上的 lock_timeout;
     * 到点拿不到回可重跑冲突和大白话提示。(ADR-116: 物料分析下达预览改为只读投影后不再取这把锁,
     * 原「预览取共享锁」模式随之删除。)
     */
    @Test void mainWarehouseLockQueuesUpToLockTimeout() throws Exception {
        UUID warehouse=UUID.randomUUID();
        var planned=new FulfillmentMutationLockPlan(Set.of(),Set.of(),Set.of(warehouse),Set.of(),"warehouse-only");
        String key="MATERIAL-ANALYSIS-WAREHOUSE:"+warehouse;
        try (var holder=jdbc.getDataSource().getConnection()) {
            try (var lock=holder.prepareStatement("SELECT pg_advisory_lock_shared(hashtextextended(?,0))")) {
                lock.setString(1,key); lock.executeQuery().close();
            }
            long started=System.nanoTime();
            var busy=assertThrows(FulfillmentSourceConflictException.class,
                    ()->transactions.executeWithoutResult(tx -> { lockTimeout("300ms"); locks.acquire(()->planned); }));
            long waitedMillis=(System.nanoTime()-started)/1_000_000L;
            assertTrue(busy.retryable());
            assertEquals(FulfillmentMutationLocks.WAREHOUSE_BUSY_MESSAGE,busy.getMessage());
            assertTrue(waitedMillis>=250&&waitedMillis<5_000,"Bounded by lock_timeout instead of queueing forever: "+waitedMillis);
            try (var unlock=holder.prepareStatement("SELECT pg_advisory_unlock_shared(hashtextextended(?,0))")) {
                unlock.setString(1,key); unlock.executeQuery().close();
            }
            transactions.executeWithoutResult(tx -> locks.acquire(()->planned).verifyUnchanged());
        }
    }

    /**
     * 预锁阶段排在别人后面超过 lock_timeout(订货单行锁、库存维度锁同理): 本命令还没写任何东西,
     * 回可重跑冲突和大白话提示, 交给最外层事务边界在重跑预算内再排一次队, 而不是裸的锁超时 409。
     */
    @Test void prefixRowLockTimeoutIsARetryableBusyConflict() throws Exception {
        var f=fixture();
        try (var holder=jdbc.getDataSource().getConnection()) {
            holder.setAutoCommit(false);
            try (var lock=holder.prepareStatement("SELECT id FROM sales_orders WHERE id=? FOR UPDATE")) {
                lock.setObject(1,f.order); lock.executeQuery().close();
            }
            var busy=assertThrows(FulfillmentSourceConflictException.class,
                    ()->transactions.executeWithoutResult(tx -> { lockTimeout("300ms"); locks.acquire(()->plan(f)); }));
            assertTrue(busy.retryable());
            assertEquals(FulfillmentMutationLocks.SOURCE_BUSY_MESSAGE,busy.getMessage());
            holder.rollback();
        }
        transactions.executeWithoutResult(tx -> locks.acquire(()->plan(f)).verifyUnchanged());
    }

    /** 评审补充: 前一个写命令持主仓锁约 3 秒, 同仓第二个写命令排队等到它提交后成功, 不回 409。 */
    @Test void secondWarehouseWriterQueuesBehindAThreeSecondHolderAndSucceeds() throws Exception {
        UUID warehouse=UUID.randomUUID();
        var planned=new FulfillmentMutationLockPlan(Set.of(),Set.of(),Set.of(warehouse),Set.of(),"warehouse-queue");
        var held=new CountDownLatch(1);
        try(var workers=Executors.newFixedThreadPool(2)) {
            var holder=workers.submit(() -> transactions.executeWithoutResult(tx -> {
                lockTimeout("10s");
                locks.acquire(()->planned).verifyUnchanged();
                held.countDown();
                sleep(3_000);
            }));
            assertTrue(held.await(5,TimeUnit.SECONDS));
            long started=System.nanoTime();
            var waiter=workers.submit(() -> transactions.executeWithoutResult(tx -> {
                lockTimeout("10s");
                locks.acquire(()->planned).verifyUnchanged();
            }));
            waiter.get(15,TimeUnit.SECONDS);
            long waitedMillis=(System.nanoTime()-started)/1_000_000L;
            holder.get(5,TimeUnit.SECONDS);
            assertTrue(waitedMillis>=2_500,"The second writer queued behind the holder: "+waitedMillis);
        }
    }

    /**
     * 评审补充: 前一个命令持有订货单约 3.5 秒后把发货行改挂到另一张订单并提交; 本命令排队等锁后发现
     * 来源变了——等锁时间不算进重跑预算, 最外层事务边界替它重跑一次, 重新预读新订单后成功。
     */
    @Test void conflictDetectedAfterAThreeSecondQueueIsReRunByTheCommandBoundary() throws Exception {
        var old=fixture(); var replacement=fixture(); UUID shipment=UUID.randomUUID(); UUID line=UUID.randomUUID();
        jdbc.update("INSERT INTO sales_shipments(id) VALUES (?)",shipment);
        jdbc.update("INSERT INTO sales_shipment_items(id,shipment_id,order_item_id,goods_id) VALUES (?,?,?,?)",line,shipment,old.item,old.goods);
        var command=new ShipmentCommand();
        var proxyFactory=new org.springframework.aop.framework.ProxyFactory(command);
        proxyFactory.setProxyTargetClass(true);
        proxyFactory.addAdvice(new FulfillmentSourceConflictRetryInterceptor());
        proxyFactory.addAdvice(new org.springframework.transaction.interceptor.TransactionInterceptor(
                (org.springframework.transaction.TransactionManager) manager,
                new org.springframework.transaction.annotation.AnnotationTransactionAttributeSource()));
        var proxy=(ShipmentCommand) proxyFactory.getProxy();
        var holderReady=new CountDownLatch(1);
        try(var workers=Executors.newFixedThreadPool(2)) {
            var holder=workers.submit(() -> transactions.executeWithoutResult(tx -> {
                em.createNativeQuery("SELECT id FROM sales_orders WHERE id=:id FOR UPDATE").setParameter("id",old.order).getSingleResult();
                holderReady.countDown();
                sleep(3_500);
                em.createNativeQuery("UPDATE sales_shipment_items SET order_item_id=:replacement,goods_id=:goods WHERE id=:id")
                        .setParameter("replacement",replacement.item).setParameter("goods",replacement.goods).setParameter("id",line).executeUpdate();
            }));
            assertTrue(holderReady.await(5,TimeUnit.SECONDS));
            long started=System.nanoTime();
            var waiter=workers.submit(() -> proxy.touch(shipment));
            waiter.get(20,TimeUnit.SECONDS);
            long elapsedMillis=(System.nanoTime()-started)/1_000_000L;
            holder.get(5,TimeUnit.SECONDS);
            assertEquals(2,command.attempts.get(),"The queued attempt conflicted once and the boundary re-ran it");
            assertTrue(elapsedMillis>=3_000,"The first attempt really waited behind the holder: "+elapsedMillis);
            assertEquals(1,jdbc.queryForObject("SELECT revision FROM sales_shipments WHERE id=?",Integer.class,shipment));
        }
    }

    /** A command boundary like a production @Transactional service method (retry advice outside the transaction). */
    static class ShipmentCommand {
        final java.util.concurrent.atomic.AtomicInteger attempts=new java.util.concurrent.atomic.AtomicInteger();
        @org.springframework.transaction.annotation.Transactional
        public void touch(UUID shipment) {
            attempts.incrementAndGet();
            sales.lockShipment(shipment,List.of());
            em.createNativeQuery("UPDATE sales_shipments SET revision=revision+1 WHERE id=:id").setParameter("id",shipment).executeUpdate();
        }
    }

    /**
     * 评审补充: 生产配置下嵌套 acquire 只查声明的 id; 打开诊断开关(测试环境默认打开)后, 嵌套 acquire
     * 还会重跑自己的发现, 没声明却超出预锁的足迹也会被拦下(可重跑, 记 WARN)。
     */
    @Test void verificationSwitchRediscoversUndeclaredNestedFootprints() {
        var f=fixture(); var outside=fixture();
        var verifying=new FulfillmentMutationLocks(em,new FulfillmentInventoryMutationAdapter(inventory),true);
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->plan(f)).verifyUnchanged();
            locks.acquire(()->plan(outside)).verifyUnchanged(); // production: nothing declared, nothing checked
        });
        transactions.executeWithoutResult(tx -> {
            verifying.acquire(()->plan(f)).verifyUnchanged();
            verifying.acquire(()->plan(f)).verifyUnchanged();
            var gap=assertThrows(FulfillmentSourceConflictException.class,()->verifying.acquire(()->plan(outside)));
            assertTrue(gap.retryable(),"A rediscovered footprint may have drifted: re-run, not a coding verdict");
            tx.setRollbackOnly();
        });
        transactions.executeWithoutResult(tx -> {
            locks.acquire(()->plan(f)).verifyUnchanged();
            var drift=assertThrows(FulfillmentSourceConflictException.class,()->locks.requireDiscoveredCovered(()->plan(outside)));
            assertTrue(drift.retryable(),"Rediscovery-based callback checks stay retryable");
            tx.setRollbackOnly();
        });
    }

    private static void lockTimeout(String value) {
        em.createNativeQuery("SELECT set_config('lock_timeout',:value,true)").setParameter("value",value).getSingleResult();
    }
    private static void sleep(long millis) {
        try { Thread.sleep(millis); } catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new AssertionError(e); }
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
