package com.uten.imp.features.master;

import com.uten.imp.common.readsnapshot.*;
import com.uten.imp.common.web.*;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import com.uten.imp.features.master.client.*;
import com.uten.imp.features.master.supplier.*;
import com.uten.imp.features.master.mould.*;
import org.junit.jupiter.api.*;
import org.springframework.http.MediaType;
import org.springframework.http.converter.json.MappingJackson2HttpMessageConverter;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import java.util.*;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

@SuppressWarnings("removal") // The owning application pins this Jackson 2 compatibility converter.
class MasterSummaryControllersTest {
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    @Test void allThreeExactBodiesRetainTypedFiltersAndTheirOriginalOwners() throws Exception {
        var mapper=Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
        var pages=mock(VersionedSummaryPages.class);var proofs=new ArrayList<VersionedSummaryPages.Request>();
        when(pages.read(any(),any(Runnable.class),any())).thenAnswer(call->{proofs.add(call.getArgument(0));call.getArgument(1,Runnable.class).run();return new VersionedSummaryPages.Snapshot<>(call.getArgument(2,Supplier.class).get(),"a".repeat(64),"b".repeat(64),"c".repeat(64));});
        var support=new MasterSummaryReadSupport(pages,mapper);
        var clients=mock(ClientService.class);var suppliers=mock(SupplierService.class);var moulds=mock(MouldService.class);
        when(clients.list(any(),eq(1),eq(100),eq("credit"),eq("desc"))).thenReturn(new PageResponse<>(List.of(),1,100,0,0));
        when(suppliers.list(any(),eq(1),eq(100),eq("lossRate"),eq("desc"))).thenReturn(new PageResponse<>(List.of(),1,100,0,0));
        when(moulds.list(any(),eq(1),eq(100),eq("tqty"),eq("desc"))).thenReturn(new PageResponse<>(List.of(),1,100,0,0));
        var mvc=MockMvcBuilders.standaloneSetup(new ClientSummaryController(clients,support),new SupplierSummaryController(suppliers,support),new MouldSummaryController(moulds,support)).setMessageConverters(new MappingJackson2HttpMessageConverter(mapper)).build();
        for(String[] example:List.of(new String[]{"clients","client:view","credit"},new String[]{"suppliers","supplier:view","lossRate"},new String[]{"moulds","mould:view","tqty"})) {
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader","unused",List.of(new SimpleGrantedAuthority(example[1]))));
            var filter=new LinkedHashMap<String,Object>();filter.put("keyword","中文%_");filter.put("nullFields",List.of("name"));
            if(!example[0].equals("moulds"))filter.put("selectableOnly",true);
            if(example[0].equals("clients")){filter.put("excludeLegacyFinanceStub",true);filter.put("mobile","private-body-only");}
            String path="/api/master/"+example[0]+"/summaries";
            var response=mvc.perform(post(path).param("readSnapshotRevision","b".repeat(64)).contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsBytes(Map.of("filter",filter,"page",1,"size",100,"sort",example[2],"order","desc")))).andReturn().getResponse();
            assertThat(response.getStatus()).isEqualTo(200);
            assertThat(response.getHeader("X-Uten-Read-Scope-Version")).isEqualTo("a".repeat(64));
            var body=mapper.readTree(response.getContentAsByteArray());assertThat(body.path("size").asInt()).isEqualTo(100);assertThat(body.path("readDataVersion").asText()).isEqualTo("c".repeat(64));assertThat(body.has("value")).isFalse();
            assertThat(ExactBodyReadRoutes.matches("POST",path)).isTrue();
            for(String suffix:List.of("/save","/","-all"))assertThat(ExactBodyReadRoutes.matches("POST",path+suffix)).isFalse();
            assertThat(ExactBodyReadRoutes.matches("POST","/api/business-references/"+example[0]+"/summaries")).isEqualTo(!example[0].equals("moulds"));
        }
        verify(clients).list(argThat(f->f.selectableOnly()&&f.excludeLegacyFinanceStub()&&"private-body-only".equals(f.mobile())),eq(1),eq(100),eq("credit"),eq("desc"));
        verify(suppliers).list(argThat(f->f.selectableOnly()&&"中文%_".equals(f.keyword())),eq(1),eq(100),eq("lossRate"),eq("desc"));
        verify(moulds).list(argThat(f->"中文%_".equals(f.keyword())&&f.nullFields().contains("name")),eq(1),eq(100),eq("tqty"),eq("desc"));
        assertThat(proofs).extracting(VersionedSummaryPages.Request::authorizationDomain).containsExactly("client","supplier","master_mould");
    }
}
