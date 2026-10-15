package com.uten.imp.features.visitor.sms;

import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.stereotype.Component;

/** One Spring gateway, selected per issuance; no startup-time conditional provider beans. */
@Component
public class DynamicSmsGateway implements SmsGateway {
    private final SmsGatewayRuntime runtime;
    private final SmsGatewayFactory factory;
    private final Map<String,Prepared> senders=new LinkedHashMap<>();
    public DynamicSmsGateway(SmsGatewayRuntime runtime,SmsGatewayFactory factory) { this.runtime=runtime;this.factory=factory; }
    @Override public Prepared prepare() {
        var snapshot=runtime.current();
        synchronized(senders) {
            Prepared existing=senders.get(snapshot.revision());
            if(existing!=null)return existing;
            Prepared selected=new Prepared(factory.create(snapshot),snapshot.developmentCodeAllowed());
            senders.put(snapshot.revision(),selected);
            if(senders.size()>8)senders.remove(senders.keySet().iterator().next());
            // Do not close/modify an evicted client: an in-flight issuance still owns it.
            return selected;
        }
    }
    @Override public SmsSendResult sendCode(String phone,String code) { return prepare().sendCode(phone,code); }
}
