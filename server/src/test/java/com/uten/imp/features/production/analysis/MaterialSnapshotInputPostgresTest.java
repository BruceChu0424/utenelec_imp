package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import java.util.stream.IntStream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.junit.jupiter.api.Assertions.*;

/** Compares the two production input shapes to independently typed JDBC values,
 * including large decimals, empty versus NULL, dates, UUIDs and quoted Unicode. */
@Testcontainers(disabledWithoutDocker=true)
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MaterialSnapshotInputPostgresTest {
    @Container static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");

    @ParameterizedTest @ValueSource(strings={"NODE_INPUT","NODE_ALLOCATION_INPUT"})
    void typedJsonRetainsTheEntireScalarContractAndArrayOrder(String name)throws Exception {
        MaterialSnapshotInput shape=(MaterialSnapshotInput)ReflectionTestUtils.getField(MaterialAnalysisService.class,name);
        assertNotNull(shape);
        List<String> columns=shape.columns();assertEquals(name.equals("NODE_INPUT")?36:15,columns.size());
        String definitions=(String)ReflectionTestUtils.getField(shape,"definitions");assertNotNull(definitions);
        String[] types=Arrays.stream(definitions.split(", ")).limit(columns.size())
                .map(definition->definition.substring(definition.indexOf(' ')+1)).toArray(String[]::new);
        Object[] first=values(columns,types,false),second=values(columns,types,true);
        List<Object[]> input=Arrays.asList(first,second);
        String encoded=shape.json(input,row->row);
        var tree=new ObjectMapper().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).readTree(encoded);
        for(int row=0;row<input.size();row++) {
            assertEquals(columns.size()+1,tree.get(row).size());assertEquals(row,tree.get(row).path("_position").asInt());
            for(String column:columns)assertTrue(tree.get(row).has(column),"NULL is an explicit input: "+column);
        }
        assertTrue(tree.get(1).path("expected_ready_date").isNull());
        assertEquals(new BigDecimal("12345678901234.1234"),tree.get(0).path("required_qty").decimalValue());
        var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        try(Connection connection=source.getConnection()) {
            String actual="SELECT "+shape.selection("snapshot")+" FROM "+shape.recordset("snapshot")+" ORDER BY snapshot._position";
            actual=actual.replace(":snapshots","?");
            String scalar="SELECT "+IntStream.range(0,columns.size()).mapToObj(index->"CAST(? AS "+types[index]+") AS "+columns.get(index))
                    .collect(java.util.stream.Collectors.joining(","));
            List<List<Object>> expected=new ArrayList<>();
            try(var statement=connection.prepareStatement(scalar)) {
                for(Object[] row:input){for(int index=0;index<row.length;index++)statement.setObject(index+1,row[index]);
                    try(var result=statement.executeQuery()){assertTrue(result.next());expected.add(row(result,columns.size()));}}
            }
            try(var statement=connection.prepareStatement(actual)) {
                statement.setString(1,encoded);assertEquals(1,statement.getParameterMetaData().getParameterCount());
                List<List<Object>> observed=new ArrayList<>();try(var result=statement.executeQuery()){
                    while(result.next())observed.add(row(result,columns.size()));}
                assertEquals(expected,observed,"Every value and SQL numeric scale must match scalar binding");
                statement.setString(1,shape.json(List.<Object[]>of(),row->row));
                try(var result=statement.executeQuery()){assertFalse(result.next());}
            }
        }
    }

    @Test void floatingPointCannotSilentlyReplaceExactSnapshotNumbers() {
        MaterialSnapshotInput input=new MaterialSnapshotInput("quantity numeric");
        assertThrows(IllegalArgumentException.class,()->input.json(List.of(1),ignored->new Object[]{1.1d}));
    }

    private static Object[] values(List<String> columns,String[] types,boolean alternate) {
        Object[] values=new Object[columns.size()];
        for(int index=0;index<columns.size();index++) {
            String column=columns.get(index);
            values[index]=switch(types[index]) {
                case "uuid" -> !alternate&&List.of("color_id","bom_item_id").contains(column)?null:
                        UUID.nameUUIDFromBytes((column+alternate).getBytes(StandardCharsets.UTF_8));
                case "numeric" -> alternate?new BigDecimal("0.0000"):new BigDecimal("12345678901234.1234");
                case "integer" -> alternate?0:2;
                case "boolean" -> alternate;
                case "date" -> alternate?null:LocalDate.of(2026,9,12);
                case "varchar","text" -> column.equals("parent_node_key")?(alternate?"":null):
                        alternate?"":"节点, (部件) \"引号\" '单引号' \\ 斜线\n下一行 🧪";
                default -> throw new IllegalStateException(types[index]);
            };
        }
        return values;
    }

    private static List<Object> row(ResultSet result,int columns)throws Exception {
        List<Object> row=new ArrayList<>();for(int index=1;index<=columns;index++)row.add(result.getObject(index));return row;
    }
}
