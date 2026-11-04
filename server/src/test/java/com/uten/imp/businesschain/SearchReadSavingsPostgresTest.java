package com.uten.imp.businesschain;

import com.uten.imp.audit.AuditQueryService;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;
import static org.junit.jupiter.api.Assertions.*;

/** Production read methods + real migrated PostgreSQL, with actual JDBC execution accounting. */
class SearchReadSavingsPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired AuditQueryService actors;
    @Autowired GoodsService goods;

    @Test void actorCountElisionRetainsExactTotalsAcrossEmptyPartialFullAndDeepPages() throws Exception {
        adminToken();
        String prefix="精简审计"+UUID.randomUUID().toString().substring(0,8);
        UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_HR'",UUID.class);
        for(int index=0;index<3;index++) {
            UUID employee=UUID.randomUUID();
            jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)"
                    +" VALUES (?,?,?,'其他',?,DATE '2020-01-01','active','regular')",employee,"SAVE-"+employee,prefix+index,department);
            jdbc.update("INSERT INTO users(employee_id,login_account,password_hash,must_change_password) VALUES (?,?,'test-only',false)",employee,"save-"+employee);
        }
        asAdmin(()->{
            var empty=measure("actor-empty-first",()->actors.actors(prefix+"不存在",1,2));
            assertEquals(0,empty.value().getTotal());assertEquals(1,empty.sql());
            var partial=measure("actor-partial-first",()->actors.actors(prefix,1,10));
            assertEquals(3,partial.value().getTotal());assertEquals(3,partial.value().getItems().size());assertEquals(2,partial.sql());
            var full=measure("actor-full-page",()->actors.actors(prefix,1,2));
            assertEquals(3,full.value().getTotal());assertEquals(2,full.value().getItems().size());assertEquals(3,full.sql());
            var tail=measure("actor-nonempty-tail",()->actors.actors(prefix,2,2));
            assertEquals(3,tail.value().getTotal());assertEquals(1,tail.value().getItems().size());assertEquals(2,tail.sql());
            var deep=measure("actor-empty-deep",()->actors.actors(prefix,3,2));
            assertEquals(3,deep.value().getTotal());assertTrue(deep.value().getItems().isEmpty());assertEquals(2,deep.sql());
            return null;
        });
    }

    @Test void canonicalGoodsSkipThreeRealLegacyLookupsWhileMixedPagesKeepHistoricalNames() throws Exception {
        adminToken();
        String tag=UUID.randomUUID().toString().substring(0,8);
        int legacy=1_800_000_000+(UUID.randomUUID().hashCode() & 0x7fffffff)%1_000_000;
        UUID color=UUID.randomUUID(),unit=UUID.randomUUID(),mould=UUID.randomUUID();
        jdbc.update("INSERT INTO colors(id,legacy_id,code,name,status) VALUES (?,?,?,'精简颜色','使用')",color,legacy,"SC-"+color);
        jdbc.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES (?,?,?,'精简单位','使用')",unit,legacy+1,"SU-"+unit);
        jdbc.update("INSERT INTO moulds(id,legacy_id,code,name,status,code_sequence) VALUES (?,?,?,'精简模具','使用',"
                +"(SELECT COALESCE(MAX(code_sequence),0)+1 FROM moulds))",mould,legacy+2,"SM-"+mould);
        String common="查询精简"+tag,canonicalName=common+"现代",historicalName=common+"历史";
        UUID canonical=good(canonicalName,color,unit,mould,legacy),historical=good(historicalName,null,null,null,legacy);
        asAdmin(()->{
            // Warm both shapes before counting; each invocation still owns a fresh read transaction.
            goods.list(filter(canonicalName,null),1,20,null,null);goods.list(filter(historicalName,null),1,20,null,null);
            var modern=measure("goods-canonical",()->goods.list(filter(canonicalName,null),1,20,null,null));
            var old=measure("goods-legacy-only",()->goods.list(filter(historicalName,null),1,20,null,null));
            assertEquals(3,old.sql()-modern.sql(),"Only the three required legacy fallback reads differ");
            assertNames(modern.value().getItems().getFirst());assertNames(old.value().getItems().getFirst());
            assertEquals(color,modern.value().getItems().getFirst().getColorId());
            assertNull(old.value().getItems().getFirst().getColorId(),"A display fallback must not invent a UUID relation");
            var mixed=goods.list(filter(null,common),1,20,null,null);
            assertEquals(Set.of(canonical,historical),mixed.getItems().stream().map(GoodsListItem::getId).collect(java.util.stream.Collectors.toSet()));
            mixed.getItems().forEach(SearchReadSavingsPostgresTest::assertNames);
            return null;
        });
    }

    private UUID good(String name,UUID color,UUID unit,UUID mould,int legacy) {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,status,auto_created,code_sequence,color_id,unit_id,mould_id,"
                +"color_legacy_id,unit_legacy_id,mould_legacy_id) VALUES (?,?,?,'使用',false,"
                +"(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods),?,?,?,?,?,?)",id,"SG-"+id,name,color,unit,mould,legacy,legacy+1,legacy+2);
        return id;
    }

    private static void assertNames(GoodsListItem row) {
        assertEquals("精简颜色",row.getColorName());assertEquals("精简单位",row.getUnitName());assertEquals("精简模具",row.getMouldName());
    }

    private static GoodsQueryFilter filter(String name,String keyword) {
        return new GoodsQueryFilter(null,null,keyword,Set.of(),null,null,null,null,name,null,null,null,
                null,null,null,null,null,null,null,null,null,null,null,null);
    }

    private <T> T asAdmin(Supplier<T> operation) {
        UUID id=jdbc.queryForObject("SELECT id FROM users WHERE login_account=?",UUID.class,ADMIN_LOGIN);
        UUID employee=jdbc.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,id);
        var actor=new AuthUser(id,employee,ADMIN_LOGIN,Set.of("goods:view","goods:view:all","audit_log:view"),false,true,true);
        var previous=SecurityContextHolder.getContext().getAuthentication();
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
        try{return operation.get();}finally{SecurityContextHolder.getContext().setAuthentication(previous);}
    }

    private record Measurement<T>(T value,long sql) { }
    private <T> Measurement<T> measure(String scenario,Supplier<T> operation) {
        ProductionJdbcMeasurement.Sample sample=ProductionJdbcMeasurement.begin();
        try {
            T value=operation.get();
            System.out.println("SEARCH-READ-SAVINGS scenario="+scenario+" sql="+sample.logicalStatements);
            return new Measurement<>(value,sample.logicalStatements);
        } finally {ProductionJdbcMeasurement.end();}
    }
}
