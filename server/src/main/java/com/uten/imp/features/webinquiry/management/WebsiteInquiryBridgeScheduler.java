package com.uten.imp.features.webinquiry.management;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.webinquiry.WebsiteInquiryService;
import com.uten.imp.features.webinquiry.dto.IngestRequest;
import com.uten.imp.common.web.ApiException;
import jakarta.validation.Validator;
import lombok.RequiredArgsConstructor;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.context.annotation.Profile;
import java.util.List;
import java.util.Map;
import java.util.ArrayList;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

/** At-least-once pull. Every receipt names the committed source and ERP identity. */
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class WebsiteInquiryBridgeScheduler {
    private final WebsiteManagementService management;
    private final WebsiteBridgeClient bridge;
    private final WebsiteInquiryService inquiries;
    private final ObjectMapper json;
    private final Validator validator;
    private final WebsitePortalLeaseRenewal leases;
    private final AtomicBoolean running=new AtomicBoolean();

    @Scheduled(fixedDelayString="${uten.website.bridge.poll-delay-ms:30000}",initialDelayString="${uten.website.bridge.initial-delay-ms:30000}")
    public void sync(){
        if(!running.compareAndSet(false,true))return;
        try {
            var config=management.config();
            if(!config.enabled() || !bridge.configured(config.publicOrigin()))return;
            List<String> failures=new ArrayList<>();
            try {
                if(!pull(config))failures.add("部分官网询盘未通过验证或保存失败，未确认记录将自动重试");
            }catch(Exception failure){
                failures.add(failure instanceof ApiException?failure.getMessage():"官网询盘同步失败，未确认记录将在下次连接时重试");
            }
            // Session renewal is independent: a bad inquiry cannot leave revoked accounts renewed,
            // and a renewal outage must not prevent committed inquiries from being acknowledged.
            try {
                if(!leases.renew(config))failures.add("部分官网管理会话续期未确认，未续期会话将在租约到期后停止访问");
            }catch(Exception failure){
                failures.add("官网管理会话续期失败，现有租约到期后会要求重新从 IMP 进入");
            }
            if(!config.equals(management.config()))return;
            if(failures.isEmpty())management.recordSync();
            else management.recordFailure(String.join("；",failures));
        }catch(Exception error){
            management.recordFailure(error instanceof ApiException?error.getMessage():"官网连接状态暂不可用");
        }finally{running.set(false);}
    }

    private boolean pull(WebsiteManagementService.Config config) throws Exception {
            JsonNode batch=bridge.get(config.publicOrigin(),"/api/imp/bridge/inquiries?limit=20");
            if(!batch.path("items").isArray() || batch.path("items").size()>20)
                throw new IllegalStateException("Invalid website inquiry batch");
            List<Map<String,String>> acknowledgments=new ArrayList<>();
            boolean failed=false;
            for(JsonNode delivery:batch.path("items")){
                try {
                    String deliveryId=delivery.path("deliveryId").asText();
                    if(deliveryId.isBlank() || deliveryId.length()>128)throw new IllegalArgumentException();
                    var fields=delivery.deepCopy();
                    ((com.fasterxml.jackson.databind.node.ObjectNode)fields).remove("deliveryId");
                    IngestRequest request=json.treeToValue(fields,IngestRequest.class);
                    if(!validator.validate(request).isEmpty())throw new IllegalArgumentException();
                    // The service proxy commits before returning. Existing sourceId replays keep the original snapshot.
                    inquiries.ingest(request);
                    UUID erpId=inquiries.idBySource(request.sourceId());
                    acknowledgments.add(Map.of("deliveryId",deliveryId,"sourceId",request.sourceId(),"erpInquiryId",erpId.toString()));
                }catch(Exception invalid){failed=true;}
            }
            if(!acknowledgments.isEmpty())
                bridge.post(config.publicOrigin(),"/api/imp/bridge/inquiries/ack",Map.of("items",acknowledgments));
            return !failed;
    }
}
