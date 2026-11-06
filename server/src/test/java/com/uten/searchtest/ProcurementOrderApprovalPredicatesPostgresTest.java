package com.uten.searchtest;

import com.uten.imp.features.finance.procurement.ProcurementOrderApprovalRead;
import com.uten.imp.features.finance.procurement.ProcurementOrderApprovalPredicates;

import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;

/** Actual Criteria/SQL with history growth; no materialized Java candidate-ID directory. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementOrderApprovalPredicatesPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static SessionFactory factory;
    static JdbcTemplate jdbc;
    static final List<String> SQL=new ArrayList<>();
    @BeforeAll static void start() {
        PG.start();var ds=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());jdbc=new JdbcTemplate(ds);
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(jdbc,"procurement_order_approval_cases");
        jdbc.execute("CREATE TABLE approval_predicate_orders(id uuid PRIMARY KEY)");
        jdbc.execute("CREATE INDEX idx_procurement_order_approval_order ON procurement_order_approval_cases(order_type,order_id,attempt DESC)");
        jdbc.execute("CREATE UNIQUE INDEX uk_procurement_order_approval_pending ON procurement_order_approval_cases(order_type,order_id) WHERE status='PENDING'");
        var c=new Configuration().addAnnotatedClass(Order.class).addAnnotatedClass(ProcurementOrderApprovalRead.class)
                .setProperty("hibernate.hbm2ddl.auto","none").setProperty("hibernate.generate_statistics","true");
        c.getProperties().put("hibernate.connection.datasource",ds);
        c.setStatementInspector(sql->{SQL.add(sql);return sql;});factory=c.buildSessionFactory();
    }
    @AfterAll static void stop(){if(factory!=null)factory.close();PG.stop();}
    @BeforeEach void clear(){jdbc.execute("TRUNCATE approval_predicate_orders,procurement_order_approval_cases");SQL.clear();}

    @Test void anyOrderPendingAndLatestOrderRejectionRetainTypeAndRequestBoundaries() {
        UUID pending=order(),rejected=order(),resubmitted=order(),closure=order(),otherType=order();
        approval(pending,"PURCHASE","ORDER","PENDING",1);
        approval(rejected,"PURCHASE","ORDER","REJECTED",1);
        approval(rejected,"PURCHASE","CLOSE","APPROVED",2);
        approval(resubmitted,"PURCHASE","ORDER","REJECTED",1);
        approval(resubmitted,"PURCHASE","ORDER","APPROVED",2);
        approval(closure,"PURCHASE","CLOSE","PENDING",1);
        approval(otherType,"SUBCONTRACT","ORDER","PENDING",1);
        assertThat(find("PURCHASE",false)).containsExactly(pending);
        assertThat(find("PURCHASE",true)).containsExactly(rejected);
        assertThat(find("SUBCONTRACT",false)).containsExactly(otherType);
        assertThat(find("SUBCONTRACT",true)).isEmpty();
    }

    @Test void thousandsOfHistoricalRejectionsDoNotCreateInListsOrAdditionalRoundTrips() {
        UUID target=order();approval(target,"PURCHASE","ORDER","PENDING",1);
        assertThat(find("PURCHASE",false)).containsExactly(target);
        int smallBindings=bindings(SQL.getLast());
        jdbc.execute("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,request_type,status,attempt) SELECT md5('case'||n)::uuid,'PURCHASE',md5('order'||n)::uuid,'ORDER','REJECTED',1 FROM generate_series(1,6000)n");
        jdbc.execute("ANALYZE procurement_order_approval_cases");SQL.clear();factory.getStatistics().clear();
        assertThat(find("PURCHASE",false)).containsExactly(target);
        assertThat(factory.getStatistics().getPrepareStatementCount()).isEqualTo(1);
        assertThat(SQL).hasSize(1);assertThat(bindings(SQL.getFirst())).isEqualTo(smallBindings).isLessThan(10);
        assertThat(SQL.getFirst().toLowerCase(Locale.ROOT)).contains("exists").doesNotContain(" in (");
        String plan=jdbc.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT id FROM approval_predicate_orders o WHERE o.id='"+target+"' AND EXISTS(SELECT 1 FROM procurement_order_approval_cases c WHERE c.order_type='PURCHASE' AND c.order_id=o.id AND c.request_type='ORDER' AND c.status='PENDING')",String.class);
        assertThat(plan).contains("uk_procurement_order_approval_pending");
        System.out.println("APPROVAL-QUALIFIER-GROWTH historicalCases=6000 statements=1 bindings="+smallBindings+" existingPendingIndex=true");
    }

    private static List<UUID> find(String type,boolean rejected) {
        try(var em=factory.createEntityManager()) {
            var cb=em.getCriteriaBuilder();var query=cb.createQuery(UUID.class);var row=query.from(Order.class);
            query.select(row.get("id")).where(rejected
                    ?ProcurementOrderApprovalPredicates.latestRejected(row.get("id"),query,cb,type)
                    :ProcurementOrderApprovalPredicates.pending(row.get("id"),query,cb,type));
            return em.createQuery(query).getResultList();
        }
    }
    private static UUID order(){UUID id=UUID.randomUUID();jdbc.update("INSERT INTO approval_predicate_orders VALUES(?)",id);return id;}
    private static void approval(UUID order,String type,String request,String status,int attempt){jdbc.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,request_type,status,attempt) VALUES(?,?,?,?,?,?)",UUID.randomUUID(),type,order,request,status,attempt);}
    private static int bindings(String sql){return (int)sql.chars().filter(ch->ch=='?').count();}
    @Entity(name="ApprovalPredicateOrderFixture") @Table(name="approval_predicate_orders")
    static class Order {@Id UUID id;protected Order(){}}
}
