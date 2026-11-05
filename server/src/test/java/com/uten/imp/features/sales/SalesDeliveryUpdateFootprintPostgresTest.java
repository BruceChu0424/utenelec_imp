package com.uten.imp.features.sales;

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
import java.util.concurrent.atomic.AtomicBoolean;
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
        db.execute("CREATE TABLE sales_orders(id uuid PRIMARY KEY)");
        db.execute("CREATE TABLE sales_order_items(id uuid PRIMARY KEY,order_id uuid,goods_id uuid,color_id uuid,is_deleted boolean DEFAULT FALSE,delivery_plan jsonb DEFAULT '{\"mode\":\"ASSEMBLED\",\"processes\":[]}',delivery_bom_snapshot jsonb)");
        db.execute("CREATE TABLE goods(id uuid PRIMARY KEY,color_id uuid,unit_id uuid,is_deleted boolean DEFAULT FALSE,auto_created boolean DEFAULT FALSE,status text DEFAULT '使用')");
        db.execute("CREATE TABLE goods_bom_items(id uuid PRIMARY KEY,goods_id uuid,component_goods_id uuid,color_id uuid,qty numeric DEFAULT 1,consumption_basis text DEFAULT 'PER_UNIT',basis_output_qty numeric DEFAULT 1,allow_partial_package boolean DEFAULT TRUE,is_deleted boolean DEFAULT FALSE)");
        db.execute("CREATE TABLE goods_bom_delivery_rules(bom_edge_id uuid PRIMARY KEY,mandatory_assembly boolean DEFAULT FALSE,material_role text DEFAULT 'PART',required_operations jsonb DEFAULT '[]')");
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(dataSource);bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.sales.order");var properties=new Properties();properties.setProperty("hibernate.hbm2ddl.auto","none");
        bean.setJpaProperties(properties);bean.afterPropertiesSet();factory=bean.getObject();em=SharedEntityManagerCreator.createSharedEntityManager(factory);
        transactions=new TransactionTemplate(new JpaTransactionManager(factory));inventory=new FulfillmentInventoryMutationAdapter(new InventoryMutationLock(em));
    }
    @AfterAll static void stop(){if(factory!=null)factory.close();POSTGRES.stop();}
    private record World(UUID order,UUID item,UUID root,UUID child,UUID edge) {}
    private World world() {
        UUID order=UUID.randomUUID(),item=UUID.randomUUID(),root=UUID.randomUUID(),child=UUID.randomUUID(),edge=UUID.randomUUID();
        db.update("INSERT INTO sales_orders(id) VALUES(?)",order);
        db.update("INSERT INTO goods(id) VALUES(?),(?)",root,child);
        db.update("INSERT INTO sales_order_items(id,order_id,goods_id) VALUES(?,?,?)",item,order,root);
        db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id) VALUES(?,?,?)",edge,root,child);
        return new World(order,item,root,child,edge);
    }
    private SalesMutationFootprintService service(AtomicReference<Set<InventoryDimension>> taken,Runnable afterDiscovery) {
        var locks=new FulfillmentMutationLocks(em,dimensions->{taken.set(Set.copyOf(dimensions));inventory.lockDimensions(dimensions);if(afterDiscovery!=null)afterDiscovery.run();},true);
        var sales=new SalesMutationFootprintService(em,locks);ReflectionTestUtils.setField(sales,"masterReferences",mock(MasterReferenceValidationPort.class));return sales;
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
    @Test void changedAuthoritativeEdgeColorFailsTheOriginalPrewriteFingerprintAndCanRetryFresh() {
        var w=world();UUID changedColor=UUID.randomUUID();var taken=new AtomicReference<Set<InventoryDimension>>();var once=new AtomicBoolean();
        var sales=service(taken,()->{if(once.compareAndSet(false,true))try(var connection=dataSource.getConnection();var update=connection.prepareStatement("UPDATE goods_bom_items SET color_id=? WHERE id=?")){
            update.setObject(1,changedColor);update.setObject(2,w.edge());update.executeUpdate();
        }catch(java.sql.SQLException ex){throw new IllegalStateException(ex);}});
        var failure=catchThrowable(()->transactions.executeWithoutResult(tx->sales.lockOrderUpdate(w.order(),List.of(new SalesMutationFootprintService.ProposedOrderLine(w.root(),null,true)))));
        assertThat(failure).isInstanceOfSatisfying(FulfillmentSourceConflictException.class,ex->{
            assertThat(ex.retryable()).isTrue();assertThat(ex.reason()).isEqualTo(FulfillmentSourceConflictException.Reason.PRE_WRITE_SOURCE_CHANGED);
        });
        transactions.executeWithoutResult(tx->service(taken,null).lockOrderUpdate(w.order(),List.of(new SalesMutationFootprintService.ProposedOrderLine(w.root(),null,true))));
        assertThat(taken.get()).contains(new InventoryDimension(w.child(),changedColor)).doesNotContain(new InventoryDimension(w.child(),null));
    }
    private static String snapshot(UUID root,UUID child){return "{\"root\":{\"goodsId\":\""+root+"\",\"children\":[{\"goodsId\":\""+child+"\"}]}}";}
}
