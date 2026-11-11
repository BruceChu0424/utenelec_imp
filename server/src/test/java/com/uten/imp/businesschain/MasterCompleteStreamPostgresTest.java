package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.master.goods.GoodsRepository;
import org.junit.jupiter.api.*;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Full migrations, actual PostgreSQL cursor, original DTOs and complete JWT/security chain. */
class MasterCompleteStreamPostgresTest extends AuthSessionPostgresTestSupport {
    @MockitoSpyBean GoodsRepository goodsRepository;

    private List<JsonNode> read(String path,Map<String,Object> filter,String token)throws Exception {
        var result=mvc.perform(json(post(path).param("complete","true").accept("application/x-ndjson"),
                Map.of("filter",filter,"page",1,"size",100),token)).andReturn();
        assertThat(result.getResponse().getStatus()).as(path).isEqualTo(200);
        assertThat(result.getResponse().getContentType()).startsWith("application/x-ndjson");
        var frames=new ArrayList<JsonNode>();
        for(String line:result.getResponse().getContentAsString().lines().toList()) frames.add(objectMapper.readTree(line));
        assertThat(frames).isNotEmpty();
        assertThat(frames.getLast().path("type").asText()).as(result.getResponse().getContentAsString()).isEqualTo("complete");
        long seen=0;
        for(var frame:frames.subList(0,frames.size()-1)) {
            assertThat(frame.path("type").asText()).isEqualTo("page");
            assertThat(frame.path("value").path("size").asInt()).isEqualTo(100);
            assertThat(frame.path("value").path("items").size()).isLessThanOrEqualTo(100);
            assertThat(frame.path("value").path("readSnapshotRevision").asText())
                    .isEqualTo(frames.getLast().path("readSnapshotRevision").asText());
            seen+=frame.path("value").path("items").size();
        }
        assertThat(seen).isEqualTo(frames.getLast().path("total").asLong());
        return frames;
    }

    @Test void tenThousandGoodsReachTheLiteralTailUsingOneCountAndOneCursorWhileOrdinaryPageCapStaysBounded()throws Exception {
        String token=adminToken(),tag="STREAM"+UUID.randomUUID().toString().replace("-","").substring(0,10);
        UUID category=UUID.randomUUID();
        jdbc.update("INSERT INTO material_categories(id,code,name) VALUES(?,?,?)",category,"CAT-"+tag,tag);
        long base=jdbc.queryForObject("SELECT COALESCE(MAX(code_sequence),0) FROM goods",Long.class);
        List<UUID> ids=new ArrayList<>();for(int n=0;n<10001;n++)ids.add(UUID.randomUUID());
        for(int start=0;start<ids.size();start+=1000) {
            int end=Math.min(start+1000,ids.size());
            jdbc.batchUpdate("INSERT INTO goods(id,code,name,status,category_id,code_sequence,auto_created,price,zk) VALUES(?,?,?,'使用',?,?,false,?,?)",
                    java.util.stream.IntStream.range(start,end).boxed().toList(),100,(statement,index)->{
                        statement.setObject(1,ids.get(index));statement.setString(2,tag+String.format("%06d",index));
                        statement.setString(3,tag+"-"+index);statement.setObject(4,category);statement.setLong(5,base+index+1);
                        statement.setBigDecimal(6,new BigDecimal("1.234567"));statement.setBigDecimal(7,new BigDecimal("0.9500"));
                    });
        }
        clearInvocations(goodsRepository);
        long started=System.nanoTime();
        var frames=read("/api/master/goods/summaries",Map.of("categoryId",category.toString()),token);
        long elapsed=(System.nanoTime()-started)/1_000_000;
        var values=frames.subList(0,frames.size()-1).stream().flatMap(frame->{
            var rows=new ArrayList<JsonNode>();frame.path("value").path("items").forEach(rows::add);return rows.stream();
        }).toList();
        assertThat(frames).hasSize(102);assertThat(values).hasSize(10001);
        assertThat(values.stream().map(row->UUID.fromString(row.path("id").asText())).toList()).containsExactlyElementsOf(ids);
        verify(goodsRepository,times(1)).count(org.mockito.ArgumentMatchers.<Specification<Goods>>notNull());
        verify(goodsRepository,never()).findAll(org.mockito.ArgumentMatchers.<Specification<Goods>>notNull(),any(Pageable.class));
        var bounded=mvc.perform(get("/api/master/goods").param("categoryId",category.toString()).param("size","1000")
                .header("Authorization","Bearer "+token)).andReturn();
        assertThat(bounded.getResponse().getStatus()).isEqualTo(200);
        // 2026-11-08 合同：普通页仍夹在 Pageables.MAX_PAGE_SIZE（1000 → 200），完整读取只走流式端点。
        assertThat(json(bounded).path("items").size()).isEqualTo(Pageables.MAX_PAGE_SIZE);
        System.out.println("MASTER-COMPLETE-STREAM rows=10001 batches=101 countQueries=1 ordinaryPageCap="+Pageables.MAX_PAGE_SIZE+" elapsedMillis="+elapsed);
    }

    @Test void allFiveFlatMastersKeepTheirOriginalFiltersAndSettlementBeyondFiveHundredIsComplete()throws Exception {
        String token=adminToken(),tag="FLAT"+UUID.randomUUID().toString().replace("-","").substring(0,10);
        UUID currency=jdbc.queryForObject("SELECT id FROM currencies WHERE NOT is_deleted ORDER BY code,id LIMIT 1",UUID.class);
        var styles=jdbc.queryForList("SELECT id FROM payment_styles s WHERE category='ACCOUNT' AND NOT is_deleted AND NOT EXISTS(SELECT 1 FROM payment_styles c WHERE c.parent_id=s.id AND NOT c.is_deleted) ORDER BY code,id LIMIT 1",UUID.class);
        UUID style=styles.isEmpty()?UUID.randomUUID():styles.getFirst();
        if(styles.isEmpty())jdbc.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,?,'ACCOUNT','使用')",style,"STYLE-"+tag,tag);
        for(String master:List.of("colors","units","currencies","accounts","settlement_methods")) {
            int count=master.equals("settlement_methods")?501:251;
            List<UUID> ids=new ArrayList<>();for(int n=0;n<count;n++)ids.add(UUID.randomUUID());
            for(int n=0;n<count;n++) {
                String code=tag+"-"+master+"-"+String.format("%04d",n);
                if(master.equals("accounts"))jdbc.update("INSERT INTO accounts(id,code,name,status,style_id,currency_id) VALUES(?,?,?,'使用',?,?)",ids.get(n),code,tag,style,currency);
                else if(master.equals("currencies"))jdbc.update("INSERT INTO currencies(id,code,name,status,exchange_rate) VALUES(?,?,?,'使用',1.234567)",ids.get(n),code,tag);
                else jdbc.update("INSERT INTO "+master+"(id,code,name,status) VALUES(?,?,?,'使用')",ids.get(n),code,tag);
            }
            String path=master.equals("settlement_methods")?"/api/master/reference-methods/settlement-admin/summaries":"/api/master/"+master+"/summaries";
            var frames=read(path,Map.of("keyword",tag+"-"+master),token);
            assertThat(frames.getLast().path("total").asInt()).as(master).isEqualTo(count);
            var all=new ArrayList<UUID>();for(var frame:frames.subList(0,frames.size()-1))for(var row:frame.path("value").path("items"))all.add(UUID.fromString(row.path("id").asText()));
            assertThat(all).as(master).containsExactlyElementsOf(ids);
        }
        assertThat(jdbc.queryForList("SELECT domain FROM summary_read_domains WHERE domain IN ('color-master-list','unit-master-list','currency-master-list','account-master-list','settlement-method-master-list')",String.class)).hasSize(5);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'trg_flat_master_summary_%' AND NOT tgisinternal",Integer.class)).isEqualTo(24);
    }

    @Test void invalidInternalSizeFailsClearlyAndUnauthorizedCompleteReadsStayDenied()throws Exception {
        String token=adminToken();
        // 2026-11-09 合同后 1000 是合法的渐进内部批量（PROGRESSIVE_REQUEST_SIZE）；
        // 内部 size 只接受固定 200 或渐进 1000，其余值（含超上限）必须清晰失败。
        var result=mvc.perform(json(post("/api/master/goods/summaries").param("complete","true").accept("application/x-ndjson"),
                Map.of("filter",Map.of(),"page",1,"size",Pageables.MAX_PAGE_SIZE+1),token)).andReturn();
        assertThat(result.getResponse().getStatus()).isEqualTo(422);
        var denied=mvc.perform(json(post("/api/master/accounts/summaries").param("complete","true").accept("application/x-ndjson"),
                Map.of("filter",Map.of(),"page",1,"size",100),null)).andReturn();
        assertThat(denied.getResponse().getStatus()).isEqualTo(401);
    }
}
