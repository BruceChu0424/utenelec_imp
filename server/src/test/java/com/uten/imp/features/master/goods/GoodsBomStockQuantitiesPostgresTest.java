package com.uten.imp.features.master.goods;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Native good-stock projection only; service permissions have separate response/query tests. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsBomStockQuantitiesPostgresTest {
    @Test void sumsAllColorsAndAccountableGoodWarehousesWithoutDefectsOrWorkshopBins() {
        try(var postgres=new PostgreSQLContainer("postgres:16-alpine")) {
            postgres.start();
            var source=new SingleConnectionDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword(),true);
            var sql=new NamedParameterJdbcTemplate(source);var jdbc=sql.getJdbcTemplate();
            // Test-owned temporary projections exercise this read formula only;
            // the service command tests use the full migrated business schema.
            jdbc.execute("CREATE TEMP TABLE warehouses(id uuid PRIMARY KEY,is_accountable boolean,is_defective boolean,is_line_side boolean)");
            jdbc.execute("CREATE TEMP TABLE stock_balances(warehouse_id uuid,goods_id uuid,color_id uuid,qty numeric)");
            UUID first=UUID.randomUUID(),second=UUID.randomUUID();
            for(int index=0;index<5;index++) {
                UUID warehouse=UUID.randomUUID();
                jdbc.update("INSERT INTO warehouses VALUES(?,?,?,?)",warehouse,index!=2,index==3,index==4);
                jdbc.update("INSERT INTO stock_balances VALUES(?,?,?,?)",warehouse,first,UUID.randomUUID(),
                        new BigDecimal(index==0?"10.1111":index==1?"2.2222":"500"));
                if(index==1)jdbc.update("INSERT INTO stock_balances VALUES(?,?,?,?)",warehouse,second,null,new BigDecimal("3"));
            }
            var result=sql.query(GoodsStockQuantities.SQL,Map.of("ids",List.of(first,second)),
                    (row,index)->Map.entry(row.getObject("goods_id",UUID.class),row.getBigDecimal("qty")));
            Map<UUID,BigDecimal> quantities=result.stream().collect(java.util.stream.Collectors.toMap(Map.Entry::getKey,Map.Entry::getValue));
            assertEquals(0,new BigDecimal("12.3333").compareTo(quantities.get(first)));
            assertEquals(0,new BigDecimal("3").compareTo(quantities.get(second)));
            assertEquals(2,quantities.size());
            source.destroy();
        }
    }
}
