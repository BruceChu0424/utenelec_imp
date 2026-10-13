package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryPositionPort.Owner;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.assertThat;

/** Read/index contract; the complete immutable value graph is covered by InventoryPositionPostgresTest. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryOwnerPositionsPostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;

    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        db.execute("""
                CREATE TABLE stock_value_nodes(id uuid PRIMARY KEY,root_issue_id uuid NOT NULL,return_head_id uuid,
                    owner_kind text NOT NULL,owner_id uuid NOT NULL,active boolean NOT NULL,
                    range_from numeric NOT NULL,range_to numeric NOT NULL,created_at timestamptz NOT NULL,
                    kind text NOT NULL DEFAULT 'ISSUE_POSITION');
                CREATE INDEX idx_stock_value_nodes_owner ON stock_value_nodes(owner_kind,owner_id,id) WHERE active;
                """);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void clear(){db.execute("TRUNCATE stock_value_nodes");}

    @Test void followsCurrentHeadButReturnsOriginalRootsInTheExistingFifoOrder(){
        UUID owner=UUID.randomUUID(),other=UUID.randomUUID();
        UUID first=position(owner,"2020-01-01", "0.25"),second=position(owner,"2020-01-02","0.50");
        position(owner,"2020-01-03","1"); // Exhausted current head contributes no physical quantity.
        position(other,"2020-01-01","0");
        var actual=InventoryOwnerPositions.remaining(named,Owner.QUALITY_PENDING,List.of(owner));
        assertThat(actual).extracting(InventoryOwnerPositions.Available::rootId).containsExactly(first,second);
        assertThat(actual.get(0).quantity()).isEqualByComparingTo("0.75");
        assertThat(actual.get(1).quantity()).isEqualByComparingTo("0.50");
        var legacy=named.query("""
                SELECT root.id,root.kind,head.owner_id,head.range_to-head.range_from qty FROM stock_value_nodes root
                JOIN stock_value_nodes head ON head.id=root.return_head_id
                WHERE root.root_issue_id=root.id AND head.owner_kind=:owner AND head.owner_id=:id
                  AND head.range_to>head.range_from ORDER BY root.created_at,root.id
                """,Map.of("owner",Owner.QUALITY_PENDING.name(),"id",owner),
                (row,index)->new InventoryOwnerPositions.Available(row.getObject("id",UUID.class),row.getObject("owner_id",UUID.class),row.getBigDecimal("qty"),row.getString("kind")));
        assertThat(actual).isEqualTo(legacy);
        assertThat(InventoryOwnerPositions.remaining(named,Owner.QUALITY_PENDING,List.of())).isEmpty();
    }

    @Test void anOlderUnknownKindIsNotSilentlySkippedInFavorOfANewerCostSource(){
        UUID owner=UUID.randomUUID();
        UUID legacy=position(owner,"2019-01-01","0"),current=position(owner,"2020-01-01","0");
        db.update("UPDATE stock_value_nodes SET kind='ISSUE' WHERE id=?",legacy);
        var available=InventoryOwnerPositions.remaining(named,Owner.QUALITY_PENDING,List.of(owner));
        assertThat(available).extracting(InventoryOwnerPositions.Available::rootId).containsExactly(legacy,current);
        // The consuming value command retains its original requireRoot rejection;
        // excluding this candidate here could silently select different funding.
        assertThat(available.getFirst().kind()).isEqualTo("ISSUE");
    }

    @Test void existingOwnerPartialIndexBoundsWorkIndependentlyOfUnrelatedHistory(){
        db.execute("""
                WITH noise AS MATERIALIZED(SELECT gen_random_uuid() id,gen_random_uuid() owner FROM generate_series(1,12000))
                INSERT INTO stock_value_nodes(id,root_issue_id,return_head_id,owner_kind,owner_id,active,range_from,range_to,created_at)
                SELECT id,id,id,'WIP',owner,true,0,1,'2020-01-01'::timestamptz FROM noise
                """);
        UUID owner=UUID.randomUUID(),root=position(owner,"2020-02-01","0.25");
        db.execute("ANALYZE stock_value_nodes");
        String plan=named.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) "+InventoryOwnerPositions.REMAINING_SQL,
                Map.of("owner",Owner.QUALITY_PENDING.name(),"ids",List.of(owner)),String.class);
        assertThat(plan).contains("idx_stock_value_nodes_owner");
        assertThat(InventoryOwnerPositions.remaining(named,Owner.QUALITY_PENDING,List.of(owner)))
                .extracting(InventoryOwnerPositions.Available::rootId).containsExactly(root);
    }

    private UUID position(UUID owner,String created,String consumed){
        UUID root=UUID.randomUUID(),head=UUID.randomUUID();
        db.update("INSERT INTO stock_value_nodes(id,root_issue_id,return_head_id,owner_kind,owner_id,active,range_from,range_to,created_at) VALUES (?,?,?,'QUALITY_PENDING',?,false,0,1,?::timestamptz)",root,root,head,owner,created);
        db.update("INSERT INTO stock_value_nodes(id,root_issue_id,return_head_id,owner_kind,owner_id,active,range_from,range_to,created_at) VALUES (?,?,NULL,'QUALITY_PENDING',?,true,?,1,?::timestamptz)",
                head,root,owner,new BigDecimal(consumed),created);
        return root;
    }
}
