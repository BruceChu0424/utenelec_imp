package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

@org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc(print=org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint.NONE)
// JUnit 环境条件不继承：子类必须自带 UTEN_RUN_DB_TESTS 门，否则快速 CI 会误起数据库夹具。
@org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class OrderPreviewRemediationTest extends CompanyMaterialOrderQuantityEndToEndTest {
    @org.springframework.beans.factory.annotation.Autowired org.springframework.test.web.servlet.MockMvc http;
    @org.springframework.beans.factory.annotation.Autowired tools.jackson.databind.ObjectMapper json;
    GroupInput input(String route,List<UUID> ids,Map<UUID,BigDecimal> amounts,String mode,String qty) {
        return new GroupInput("review-"+route,ids,route,new BigDecimal(qty),true,null,null,null,null,null,null,null,
                BigDecimal.ZERO,amounts,false,"COVERAGE_TOTAL",mode);
    }
    @Test void incompletePerSourceMapMustReturnActionableRejection() throws Exception {
        var c=support.createMaterial("25","BUY");
        UUID regular=support.fixture.createUserWithPerms(c.world(),"feedback-invalid-map-"+UUID.randomUUID().toString().substring(0,8),
                "production_material_analysis:view","production_material_analysis:notify");
        db.update("UPDATE production_material_analyses SET maker_id=(SELECT employee_id FROM users WHERE id=?) WHERE id=?",regular,c.analysis());
        support.fixture.loginAs(regular);
        assertFalse(((AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal()).isSuperAdmin());
        var ids=analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.goodsId().equals(c.material())&&row.level()>0)
                .map(row->row.materialLineId()).limit(2).toList();
        assertEquals(2,ids.size());
        var bad=input("BUY",ids,Map.of(ids.getFirst(),BigDecimal.ONE),"AVAILABLE_THEN_ORDER","1");
        var request=support.request(c,List.of(bad));
        Exception rejected=assertThrows(Exception.class,()->preview.preview(c.analysis(),request));
        System.out.println("AUDIT incomplete source array throws "+rejected.getClass().getName()+" message="+rejected.getMessage());
        assertInstanceOf(ApiException.class,rejected,"must reject with a business validation message rather than internal error");
        assertTrue(rejected.getMessage().contains("逐来源下单数量必须完整对应本次原物料行"));
        var actor=SecurityContextHolder.getContext().getAuthentication();
        var before=db.queryForObject("SELECT count(*) FROM preplan_aggregate_batches WHERE analysis_id=?",Long.class,c.analysis());
        try {
            var response=http.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post(
                    "/api/production/material-analyses/"+c.analysis()+"/aggregate-orders/preview")
                    .with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication(actor))
                    .with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf())
                    .contentType("application/json").content(json.writeValueAsString(request))).andReturn().getResponse();
            System.out.println("REMEDIATION incomplete source HTTP="+response.getStatus()+" "+response.getContentAsString(java.nio.charset.StandardCharsets.UTF_8));
            assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED.getHttpStatus(),response.getStatus());
            assertTrue(response.getContentAsString(java.nio.charset.StandardCharsets.UTF_8).contains("逐来源下单数量必须完整对应本次原物料行"));
            assertEquals(before,db.queryForObject("SELECT count(*) FROM preplan_aggregate_batches WHERE analysis_id=?",Long.class,c.analysis()));
        } finally { SecurityContextHolder.getContext().setAuthentication(actor); }

    }
    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void ordinaryPlannerCanUseStockButCannotOverOrderWithoutSeparatePermission(String route) {
        var c=support.createMaterial("25",route);
        support.receive(c,c.material(),"18.1517");
        var rows=analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.goodsId().equals(c.material())&&row.level()>0).toList();
        var row=rows.stream().max(Comparator.comparing(r->r.planningUncoveredQty())).orElseThrow();
        var id=row.materialLineId();
        UUID regular=support.fixture.createUserWithPerms(c.world(),"audit-"+UUID.randomUUID().toString().substring(0,8),
            "production_material_analysis:view","production_material_analysis:notify","production_material_analysis:over_supply");
        // The synthetic analysis now belongs to the synthetic ordinary planner. No immutable ledger is updated.
        db.update("UPDATE production_material_analyses SET maker_id=(SELECT employee_id FROM users WHERE id=?) WHERE id=?",regular,c.analysis());
        var permitted=input(route,List.of(id),Map.of(id,new BigDecimal("500")),"AVAILABLE_THEN_ORDER","500");
        support.fixture.loginAs(regular);
        var principal=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        assertFalse(principal.isSuperAdmin());assertTrue(principal.getPermissions().contains("production_material_analysis:over_supply"));
        var intent=support.request(c,List.of(permitted));var p=preview.preview(c.analysis(),intent);
        var gp=p.groups().getFirst();assertNull(gp.blockedReason());
        assertEquals(0,gp.requestedQty().compareTo(new BigDecimal("481.8483")));
        assertEquals(0,gp.sources().stream().map(SourcePreview::allocatedQty).reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(new BigDecimal("31.8483")));
        assertEquals("18.1517",gp.quantityBreakdown().get("physicalClaimQty"));
        assertEquals(0,new BigDecimal(gp.quantityBreakdown().get("newOrderQty")).compareTo(new BigDecimal("481.8483")));
        assertEquals(0,new BigDecimal(gp.quantityBreakdown().get("publicExtraQty")).compareTo(new BigDecimal("450")));
        var command=support.submit(p,intent);
        var batch=writer.submit(c.analysis(),command).batches().getFirst();
        var replay=writer.submit(c.analysis(),command);
        final BigDecimal privateAmount=batch.sources().stream().map(s->s.allocatedQty()).reduce(BigDecimal.ZERO,BigDecimal::add);
        System.out.println("AUDIT "+route+" not-super permissions="+principal.getPermissions().size()
            +" beforeUncovered="+row.planningUncoveredQty()+" reviewedQty="+gp.requestedQty()
            +" reviewedPrivate="+gp.sources().stream().map(s->s.allocatedQty()).reduce(BigDecimal.ZERO,BigDecimal::add)
            +" written="+batch.qty()+" private="+privateAmount+" public="+batch.publicExtraQty()+" replay="+replay.replayed());
        assertEquals(0,batch.qty().compareTo(new BigDecimal("481.8483")));
        assertEquals(0,privateAmount.compareTo(new BigDecimal("31.8483")));
        assertEquals(0,batch.publicExtraQty().compareTo(new BigDecimal("450")));assertTrue(replay.replayed());
        var changed=input(route,List.of(id),Map.of(id,new BigDecimal("499")),"AVAILABLE_THEN_ORDER","499");
        var wrong=new SubmitRequest(command.version(),command.fingerprint(),command.idempotencyKey(),command.warehouseId(),
                command.billDate(),command.deliveryDate(),command.approveNow(),List.of(changed),command.previewFingerprint());
        assertThrows(ApiException.class,()->writer.submit(c.analysis(),wrong));
        UUID restricted=support.fixture.createUserWithPerms(c.world(),"audit-"+UUID.randomUUID().toString().substring(0,8),
                "production_material_analysis:view","production_material_analysis:notify");
        db.update("UPDATE production_material_analyses SET maker_id=(SELECT employee_id FROM users WHERE id=?) WHERE id=?",restricted,c.analysis());
        support.fixture.loginAs(restricted);
        var alternate=rows.stream().filter(r->!r.materialLineId().equals(id)).findFirst().orElseThrow().materialLineId();
        var denied=input(route,List.of(alternate),Map.of(alternate,new BigDecimal("500")),"ORDER_ALL","500");
        var restrictedIntent=support.request(c,List.of(denied));var blocked=preview.preview(c.analysis(),restrictedIntent);
        System.out.println("AUDIT "+route+" ordinary without over_supply preview="+blocked.groups().getFirst().blockedReason());
        assertNotNull(blocked.groups().getFirst().blockedReason());
        assertThrows(ApiException.class,()->writer.submit(c.analysis(),support.submit(blocked,restrictedIntent)));
    }
}
