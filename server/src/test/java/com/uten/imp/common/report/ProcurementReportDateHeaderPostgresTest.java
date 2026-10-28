package com.uten.imp.common.report;

import com.uten.imp.support.MigratedProjectionSchema;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.assertThat;

/** Boundary-positive dates use the real current head/item DATE columns and effective-date precedence. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementReportDateHeaderPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;private static NamedParameterJdbcTemplate named;
    @BeforeAll static void start() {
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"purchase_requests","purchase_request_items","subcontract_orders","subcontract_order_items");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void clean(){db.execute("TRUNCATE purchase_request_items,purchase_requests,subcontract_order_items,subcontract_orders");}
    @Test void requestDeliveryDateUsesTheActualItemDateAndIncludesTheLastDayButNotTheNextMonth() {
        UUID match=request("2026-10-01","2026-10-31");
        request("2026-10-28","2026-11-01");request("2026-09-30","2026-10-31");request("2026-10-28",null);
        var where=new ReportQueryKit.WhereBuilder("WHERE true");
        ProcurementReportColumnSearch.apply(where,Map.of("search.billDate","2026-10","search.deliverDate","2026-10-01..2026-10-31"),
                Map.of("billDate","date","deliverDate","date"),Map.of("deliverDate","i.deliver_date"));
        var built=where.build(null);
        assertThat(named.queryForList("SELECT i.id FROM purchase_request_items i JOIN purchase_requests o ON o.id=i.request_id "+built.sql(),built.params(),UUID.class)).containsExactly(match);
        assertThat(named.queryForObject("SELECT COUNT(*) FROM purchase_request_items i JOIN purchase_requests o ON o.id=i.request_id "+built.sql(),built.params(),Long.class)).isEqualTo(1);
    }
    @Test void subcontractEffectiveDeliveryDateKeepsItemPrecedenceAndUnknownDateOutsideTheRange() {
        UUID fallback=order("2026-10-01","2026-10-31",null);
        order("2026-10-28","2026-10-31","2026-11-01");
        UUID item=order("2026-10-28","2026-11-01","2026-10-31");
        order("2026-10-28",null,null);
        var where=new ReportQueryKit.WhereBuilder("WHERE true");
        ProcurementReportColumnSearch.apply(where,Map.of("search.billDate","2026","search.deliverDate","2026-10"),
                Map.of("billDate","date","deliverDate","date"),Map.of("deliverDate","COALESCE(i.deliver_date,o.deliver_date)"));
        var built=where.build(null);
        assertThat(named.queryForList("SELECT i.id FROM subcontract_order_items i JOIN subcontract_orders o ON o.id=i.order_id "+built.sql(),built.params(),UUID.class))
                .containsExactlyInAnyOrder(fallback,item);
    }
    private UUID request(String billDate,String delivery) {
        UUID head=UUID.randomUUID(),item=UUID.randomUUID();
        db.update("INSERT INTO purchase_requests(id,bill_no,bill_date) VALUES(?,?,?)",head,"REQ-"+head,LocalDate.parse(billDate));
        db.update("INSERT INTO purchase_request_items(id,request_id,deliver_date) VALUES(?,?,?)",item,head,date(delivery));return item;
    }
    private UUID order(String billDate,String headerDate,String itemDate) {
        UUID head=UUID.randomUUID(),item=UUID.randomUUID();
        db.update("INSERT INTO subcontract_orders(id,bill_no,bill_date,deliver_date) VALUES(?,?,?,?)",head,"ORDER-"+head,LocalDate.parse(billDate),date(headerDate));
        db.update("INSERT INTO subcontract_order_items(id,order_id,deliver_date) VALUES(?,?,?)",item,head,date(itemDate));return item;
    }
    private static LocalDate date(String value){return value==null?null:LocalDate.parse(value);}
}
