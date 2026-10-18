package com.uten.imp.features.webinquiry.management;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.features.webinquiry.WebsiteInquiryService;
import com.uten.imp.features.webinquiry.dto.IngestRequest;
import jakarta.validation.Validation;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class WebsiteInquiryBridgeSchedulerTest {
    private final ObjectMapper json=new ObjectMapper();
    @Test void acknowledgesOnlyCommittedValidatedItemsAndPreservesSourceReceipt() throws Exception {
        var management=mock(WebsiteManagementService.class);var bridge=mock(WebsiteBridgeClient.class);var service=mock(WebsiteInquiryService.class);
        when(management.config()).thenReturn(new WebsiteManagementService.Config(1,"网站","https://site.example",true));
        when(bridge.configured("https://site.example")).thenReturn(true);
        ObjectNode valid=json.createObjectNode().put("deliveryId","delivery-1").put("sourceId","source-1").put("name","演示")
                .put("message","需求").put("source","contact").put("locale","zh");
        ObjectNode invalid=valid.deepCopy().put("deliveryId","delivery-2").put("sourceId","source-2").put("name","");
        when(bridge.get(anyString(),anyString())).thenReturn(json.createObjectNode().set("items",json.createArrayNode().add(valid).add(invalid)));
        UUID id=UUID.randomUUID();when(service.idBySource("source-1")).thenReturn(id);
        try(var factory=Validation.buildDefaultValidatorFactory()){
            var scheduler=new WebsiteInquiryBridgeScheduler(management,bridge,service,json,factory.getValidator(),mock(WebsitePortalLeaseRenewal.class));
            scheduler.sync();
            var order=inOrder(service,bridge);
            order.verify(bridge).get("https://site.example","/api/imp/bridge/inquiries?limit=20");
            order.verify(service).ingest(argThat(r->"source-1".equals(r.sourceId())));
            order.verify(service).idBySource("source-1");
            order.verify(bridge).post("https://site.example","/api/imp/bridge/inquiries/ack",
                    Map.of("items",List.of(Map.of("deliveryId","delivery-1","sourceId","source-1","erpInquiryId",id.toString()))));
            verify(service,never()).ingest(argThat(r->"source-2".equals(r.sourceId())));
            verify(management).recordFailure(anyString());verify(management,never()).recordSync();
        }
    }
    @Test void failedCommitIsNeverAcknowledgedAndDisabledBridgeNeverConnects() throws Exception {
        var management=mock(WebsiteManagementService.class);var bridge=mock(WebsiteBridgeClient.class);var service=mock(WebsiteInquiryService.class);
        when(management.config()).thenReturn(new WebsiteManagementService.Config(0,"网站",null,false));
        try(var factory=Validation.buildDefaultValidatorFactory()){
            var scheduler=new WebsiteInquiryBridgeScheduler(management,bridge,service,json,factory.getValidator(),mock(WebsitePortalLeaseRenewal.class));
            scheduler.sync();verifyNoInteractions(bridge,service);
            when(management.config()).thenReturn(new WebsiteManagementService.Config(1,"网站","https://site.example",true));
            when(bridge.configured(anyString())).thenReturn(true);
            when(bridge.get(anyString(),anyString())).thenReturn(json.readTree("{\"items\":[{\"deliveryId\":\"d\",\"sourceId\":\"s\",\"name\":\"n\",\"message\":\"m\"}]}"));
            doThrow(new IllegalStateException("commit failed")).when(service).ingest(any(IngestRequest.class));
            scheduler.sync();
            verify(bridge,never()).post(anyString(),anyString(),any());verify(service,never()).idBySource(anyString());
        }
    }

    @Test void inquiryTransportFailureStillRechecksPortalAccountLeases(){
        var management=mock(WebsiteManagementService.class);var bridge=mock(WebsiteBridgeClient.class);
        var inquiries=mock(WebsiteInquiryService.class);var leases=mock(WebsitePortalLeaseRenewal.class);
        var config=new WebsiteManagementService.Config(1,"官网","https://site.example",true);
        when(management.config()).thenReturn(config);when(bridge.configured(config.publicOrigin())).thenReturn(true);
        when(bridge.get(anyString(),anyString())).thenThrow(new IllegalStateException("inquiry transport failed"));
        when(leases.renew(config)).thenReturn(true);
        try(var factory=Validation.buildDefaultValidatorFactory()){
            new WebsiteInquiryBridgeScheduler(management,bridge,inquiries,json,factory.getValidator(),leases).sync();
        }
        verify(leases).renew(config);verify(management).recordFailure(anyString());verify(management,never()).recordSync();
        verifyNoInteractions(inquiries);
    }

    @Test void configurationChangedDuringCycleDoesNotOverwriteItsClearedDiagnostics(){
        var management=mock(WebsiteManagementService.class);var bridge=mock(WebsiteBridgeClient.class);
        var inquiries=mock(WebsiteInquiryService.class);var leases=mock(WebsitePortalLeaseRenewal.class);
        var config=new WebsiteManagementService.Config(1,"官网","https://site.example",true);
        when(management.config()).thenReturn(config,new WebsiteManagementService.Config(2,"官网",config.publicOrigin(),false));
        when(bridge.configured(config.publicOrigin())).thenReturn(true);
        when(bridge.get(anyString(),anyString())).thenReturn(json.createObjectNode().set("items",json.createArrayNode()));
        try(var factory=Validation.buildDefaultValidatorFactory()){
            new WebsiteInquiryBridgeScheduler(management,bridge,inquiries,json,factory.getValidator(),leases).sync();
        }
        verify(management,never()).recordFailure(anyString());verify(management,never()).recordSync();
    }
}
