package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real pre-exact graph migrated forward; old projected amounts never become exact facts. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryDerivedNodeLegacyPostgresTest {
    @Test void legacyParentKeepsUnknownBoundAcrossNonzeroAndZeroWidthDerivedEdges()throws Exception{
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")){
            pg.start();var ds=new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword());
            var db=new JdbcTemplate(ds);UUID user=UUID.randomUUID(),employee=UUID.randomUUID(),warehouse=UUID.randomUUID(),goods=UUID.randomUUID();
            for(String table:List.of("users","employees","warehouses","goods","colors"))db.execute("CREATE TABLE "+table+"(id uuid PRIMARY KEY)");
            db.update("INSERT INTO users VALUES (?)",user);db.update("INSERT INTO employees VALUES (?)",employee);
            db.update("INSERT INTO warehouses VALUES (?)",warehouse);db.update("INSERT INTO goods VALUES (?)",goods);
            db.execute("""
                    CREATE TABLE stock_balances(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),warehouse_id uuid NOT NULL,
                        goods_id uuid NOT NULL,color_id uuid,qty numeric(18,4) NOT NULL,amount_local numeric(18,4),
                        UNIQUE NULLS NOT DISTINCT(warehouse_id,goods_id,color_id));
                    CREATE TABLE stock_movements(id uuid PRIMARY KEY,transaction_date timestamptz,movement_type smallint,
                        source_doc_type text NOT NULL,source_doc_id uuid,source_item_id uuid,goods_id uuid NOT NULL,
                        color_id uuid,warehouse_id uuid NOT NULL,direction smallint NOT NULL,qty numeric(18,4) NOT NULL,
                        unit_id uuid,unit_rate numeric(18,6),amount_local numeric(18,4));
                    CREATE FUNCTION business_data_reset() RETURNS TABLE(table_name text,policy text) LANGUAGE sql
                        AS $$ VALUES ('stock_value_postings', 'CLEAR') $$;
                    """);
            migration(db,"V500__inventory_value_core.sql");migration(db,"V506__inventory_value_openings_and_legacy_cases.sql");
            var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(ds);factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
            factory.setPackagesToScan("com.uten.imp.features.common.taskclaim");var props=new Properties();props.setProperty("hibernate.hbm2ddl.auto","none");
            factory.setJpaProperties(props);factory.afterPropertiesSet();EntityManagerFactory emf=factory.getObject();
            try{
                var tx=new TransactionTemplate(new JpaTransactionManager(Objects.requireNonNull(emf)));
                var mutex=new InventoryMutationLock(SharedEntityManagerCreator.createSharedEntityManager(emf));
                var named=new NamedParameterJdbcTemplate(ds);var legacy=new InventoryValuationService(named,mutex);
                PoolKey key=new PoolKey(warehouse,goods,null);EventContext acquisition=context(user,employee);
                MovementValue receipt=tx.execute(status->{mutex.lock(new InventoryKey(goods,null));
                    var result=legacy.receive(new Receive(acquisition,UUID.randomUUID(),key,new BigDecimal("3"),BigDecimal.ZERO,BigDecimal.ONE,true));
                    physical(db,result,acquisition,key,new BigDecimal("3"),1);return result;
                });
                assertThat(receipt).isNotNull();
                var original=db.queryForList("SELECT id,to_jsonb(n)::text body FROM stock_value_nodes n ORDER BY id");
                // The old source and pool were committed under the actual V500/V506
                // constraints. Migration supplies NULL bounds, not invented source precision.
                migration(db,"V517__inventory_value_custody_positions.sql");
                assertThat(db.queryForObject("SELECT count(*) FROM stock_value_nodes WHERE value_model='LEGACY_4_PROJECTION' AND bound_lower IS NULL AND source_amount_exact IS NULL",Integer.class)).isEqualTo(2);
                // V517 intentionally removes the four-decimal typmod from the
                // generated owned projection. Compare JSONB numeric values, not
                // textual rendering of equivalent 0.0000 and 0.
                for(var prior:original)assertThat(db.queryForObject("SELECT (to_jsonb(n)-ARRAY['value_model','source_initial_amount_exact','source_amount_exact','initial_bound_lower','initial_bound_upper','bound_lower','bound_upper','initial_bound_scale','bound_scale','bound_revision','distributed_value_local','creation_txid'])=CAST(? AS jsonb) FROM stock_value_nodes n WHERE id=?",Boolean.class,prior.get("body"),prior.get("id"))).isTrue();
                var current=new InventoryValuationService(named,mutex);
                for(String quantity:List.of("1","2")){
                    BigDecimal amount=new BigDecimal(quantity);EventContext issue=context(user,employee);
                    MovementValue moved=tx.execute(status->{mutex.lock(new InventoryKey(goods,null));
                        BigDecimal before=db.queryForObject("SELECT qty FROM stock_balances WHERE goods_id=?",BigDecimal.class,goods);
                        var result=current.issue(new Issue(issue,UUID.randomUUID(),key,amount,before,Destination.COGS,issue.sourceItemId()));
                        physical(db,result,issue,key,amount,-1);return result;
                    });
                    assertThat(moved).isNotNull();assertThat(moved.state()).isEqualTo(State.PENDING);
                    for(UUID id:List.of(moved.valueNodeId(),moved.poolHeadId())){
                        assertThat(db.queryForObject("SELECT bound_lower FROM stock_value_nodes WHERE id=?",BigDecimal.class,id)).isNull();
                        assertThat(db.queryForObject("SELECT bound_upper FROM stock_value_nodes WHERE id=?",BigDecimal.class,id)).isNull();
                        assertThat(db.queryForObject("SELECT count(*) FROM stock_value_edges WHERE child_node_id=? AND allocated_bound_lower IS NULL AND allocated_bound_upper IS NULL",Integer.class,id)).isEqualTo(1);
                    }
                }
                assertThat(db.queryForObject("SELECT qty FROM stock_balances WHERE goods_id=?",BigDecimal.class,goods)).isZero();
                assertThat(db.queryForObject("SELECT count(*) FROM stock_value_edges WHERE interval_from=interval_to AND allocated_bound_lower IS NULL",Integer.class)).isEqualTo(1);
                assertThat(db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid IN ('stock_value_nodes'::regclass,'stock_value_edges'::regclass) AND NOT tgisinternal AND tgenabled<>'A'",Integer.class)).isZero();
            }finally{if(emf!=null)emf.close();}
        }
    }
    private static void migration(JdbcTemplate db,String name)throws Exception{
        try(var stream=InventoryDerivedNodeLegacyPostgresTest.class.getResourceAsStream("/db/migration/"+name)){
            db.execute(new String(Objects.requireNonNull(stream).readAllBytes(),StandardCharsets.UTF_8));
        }
    }
    private static EventContext context(UUID user,UUID employee){UUID id=UUID.randomUUID();
        return new EventContext(id,"TEST_LEGACY_DERIVED",UUID.randomUUID(),UUID.randomUUID(),1,user,employee,id.toString(),OffsetDateTime.parse("2026-09-12T00:00:00Z"));
    }
    private static void physical(JdbcTemplate db,MovementValue result,EventContext event,PoolKey key,BigDecimal qty,int direction){
        db.update("INSERT INTO stock_movements(id,source_doc_type,source_doc_id,source_item_id,goods_id,warehouse_id,direction,qty,amount_local) VALUES (?,?,?,?,?,?,?,?,?)",
                result.movementId(),event.sourceDocType(),event.sourceDocId(),event.sourceItemId(),key.goodsId(),key.warehouseId(),direction,qty,result.knownValueLocal());
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty,amount_local) VALUES (?,?,?,?) ON CONFLICT(warehouse_id,goods_id,color_id) DO UPDATE SET qty=stock_balances.qty+excluded.qty,amount_local=stock_balances.amount_local+excluded.amount_local",
                key.warehouseId(),key.goodsId(),qty.multiply(BigDecimal.valueOf(direction)),result.knownValueLocal().multiply(BigDecimal.valueOf(direction)));
    }
}
