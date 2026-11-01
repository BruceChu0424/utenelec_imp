package com.uten.imp.features.notice;

import org.junit.jupiter.api.Test;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

class SubcontractOutboundNoticePurposeTest {
    private Notice notice(String route,String type,UUID aggregate) {
        Notice n=new Notice();n.setSourceEvent(SubcontractOutboundNoticePurpose.EVENT);
        n.setType(type);n.setKind("NORMAL");n.setAudienceUserId(UUID.randomUUID());
        n.setAudienceScope("selected");n.setAudienceCount(1);n.setActionRoute(route);
        if(aggregate!=null){n.setAggregateKind("SUBCONTRACT_ORDER");n.setAggregateId(aggregate);}
        return n;
    }

    @Test void threeProducerPurposesUseOnlyTheirOwnActionAndOrdinaryReceiptsKeepTheirSourceIdentity() {
        var order=notice("/subcontract/orders/"+UUID.randomUUID(),"workflow",null);
        var analysis=notice("/production/material-analyses/"+UUID.randomUUID()+"/summary","workflow",null);
        var warehouse=notice(SubcontractOutboundNoticePurpose.WAREHOUSE_ROUTE,"task",UUID.randomUUID());
        var drawer=Set.of("notice:read","subcontract_order:view","subcontract_order:draw");
        var planner=Set.of("notice:read","production_material_analysis:view","production_material_analysis:notify");
        var keeper=Set.of("notice:read","warehouse_inbound:view","warehouse_inbound:stock_in");
        for(var grants:java.util.List.of(drawer,planner,keeper)) {
            assertThat(BusinessNoticeParticipation.allowed(order,grants)).isEqualTo(grants==drawer);
            assertThat(BusinessNoticeParticipation.allowed(analysis,grants)).isEqualTo(grants==planner);
            assertThat(BusinessNoticeParticipation.allowed(warehouse,grants)).isEqualTo(grants==keeper);
        }
        assertThat(order.getSourceEvent()).isEqualTo(SubcontractOutboundNoticePurpose.EVENT);
        assertThat(order.getAggregateId()).isNull();
    }

    @Test void viewOnlyAndCompanyLibraryWritesDoNotQualifyForAnyPurpose() {
        Set<String> viewer=Set.of("notice:read","subcontract_order:view","production_material_analysis:view","warehouse_inbound:view",
                "company_file:view","company_file:create","company_file:edit","company_file:delete","company_file:move",
                "company_file:restore","company_file:upload","company_file:manage_permissions","attachment:upload");
        for(var n:java.util.List.of(notice("/subcontract/orders/"+UUID.randomUUID(),"workflow",null),
                notice("/production/material-analyses/"+UUID.randomUUID()+"/summary","workflow",null),
                notice(SubcontractOutboundNoticePurpose.WAREHOUSE_ROUTE,"task",UUID.randomUUID())))
            assertThat(BusinessNoticeParticipation.allowed(n,viewer)).isFalse();
    }

    @Test void unknownRoutesAndChangedTypeKindAggregateRevisionOrTargetFailClosedEvenForAllActions() {
        Set<String> all=Set.of("notice:read","subcontract_order:view","subcontract_order:draw",
                "production_material_analysis:view","production_material_analysis:notify","warehouse_inbound:view","warehouse_inbound:stock_in");
        String route="/subcontract/orders/"+UUID.randomUUID();
        for(int changed=0;changed<8;changed++) {
            Notice n=notice(route,"workflow",null);
            switch(changed) {
                case 0->n.setActionRoute("/subcontract/orders/not-a-uuid");
                case 1->n.setActionRoute(route+"/extra");
                case 2->n.setType("task");
                case 3->n.setKind("TODO");
                case 4->n.setAggregateId(UUID.randomUUID());
                case 5->n.setAggregateKind("SUBCONTRACT_ORDER");
                case 6->n.setSourceRevision(1L);
                case 7->n.setAudienceScope("all");
            }
            assertThat(BusinessNoticeParticipation.allowed(n,all)).as("changed shape %s",changed).isFalse();
        }
        assertThat(BusinessNoticeParticipation.allowed(notice("/warehouse/inbound/unknown","task",UUID.randomUUID()),all)).isFalse();
        assertThat(BusinessNoticeParticipation.allowed(notice(SubcontractOutboundNoticePurpose.WAREHOUSE_ROUTE,"workflow",null),all)).isFalse();
    }
}
