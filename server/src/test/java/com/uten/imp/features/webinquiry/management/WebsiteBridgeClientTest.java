package com.uten.imp.features.webinquiry.management;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.Test;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.Flow;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.assertj.core.api.Assertions.*;

class WebsiteBridgeClientTest {
    private static final String TOKEN="test-only-website-bridge-token-0123456789-abcdefgh";

    @Test void rejectsUntrustedOriginsCredentialsPathsAndPlainHttpByDefault(){
        var client=new WebsiteBridgeClient(new ObjectMapper(),"https://www.example.com",TOKEN,"uten",false);
        assertThat(client.validateOrigin("https://www.example.com/")).isEqualTo("https://www.example.com");
        for(String bad:List.of("https://www.example.com.evil.test","https://www.example.com@evil.test",
                "https://www.example.com/admin","https://www.example.com?x=1","https://www.example.com#secret","http://www.example.com"))
            assertThatThrownBy(()->client.validateOrigin(bad)).isInstanceOf(ApiException.class);
        assertThat(new WebsiteBridgeClient(new ObjectMapper(),"https://www.example.com","short","uten",false).tokenConfigured()).isFalse();
        assertThatThrownBy(()->new WebsiteBridgeClient(new ObjectMapper(),"http://10.0.0.1",TOKEN,"uten",true)).isInstanceOf(ApiException.class);
    }

    @Test void usesHttp11ForServersRejectingH2cAndNeverFollowsRedirects() throws Exception {
        var server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        AtomicBoolean validHeaders=new AtomicBoolean(),redirectHit=new AtomicBoolean(),redirect=new AtomicBoolean();
        server.createContext("/api/imp/bridge/status",exchange->{
            // Mirrors the local Next.js interoperability failure: reject plaintext HTTP/2 upgrade.
            if(exchange.getRequestHeaders().getFirst("Upgrade")!=null){exchange.close();return;}
            validHeaders.set(("Bearer "+TOKEN).equals(exchange.getRequestHeaders().getFirst("Authorization"))
                    && "uten".equals(exchange.getRequestHeaders().getFirst("X-Uten-Site-Id")));
            if(redirect.get()){exchange.getResponseHeaders().add("Location","/other");exchange.sendResponseHeaders(302,-1);}
            else{byte[] body="{\"siteId\":\"uten\",\"ready\":true}".getBytes(StandardCharsets.UTF_8);exchange.sendResponseHeaders(200,body.length);exchange.getResponseBody().write(body);}
            exchange.close();
        });
        server.createContext("/other",exchange->{redirectHit.set(true);exchange.sendResponseHeaders(200,-1);exchange.close();});
        server.start();
        try{
            String origin="http://127.0.0.1:"+server.getAddress().getPort();
            var client=new WebsiteBridgeClient(new ObjectMapper(),origin,TOKEN,"uten",true);
            assertThat(client.get(origin,"/api/imp/bridge/status").path("ready").asBoolean()).isTrue();
            assertThat(validHeaders).isTrue();redirect.set(true);
            assertThatThrownBy(()->client.get(origin,"/api/imp/bridge/status")).isInstanceOf(ApiException.class).hasMessageContaining("302");
            assertThat(redirectHit).isFalse();
        }finally{server.stop(0);}
    }

    @Test void cancelsOversizedBodyWithoutRetainingIt(){
        var body=new WebsiteBridgeClient.BoundedBody(8);
        AtomicBoolean canceled=new AtomicBoolean();
        body.onSubscribe(new Flow.Subscription(){@Override public void request(long n){}@Override public void cancel(){canceled.set(true);}});
        body.onNext(List.of(ByteBuffer.wrap(new byte[9])));
        assertThat(canceled).isTrue();
        assertThat(body.getBody().toCompletableFuture()).isCompletedExceptionally();
    }

    @Test void tokenContractMatchesWebsiteLengthAndAlphabetWithoutTrimming(){
        for(String invalid:List.of("","a".repeat(32),"a".repeat(42),"a".repeat(513),
                " "+"a".repeat(43),"a".repeat(43)+" ","a".repeat(43)+"\n","a".repeat(42)+"界")){
            assertThat(new WebsiteBridgeClient(new ObjectMapper(),"https://site.example",invalid,"uten",false).tokenConfigured())
                    .as("invalid length/alphabet boundary").isFalse();
        }
        for(String valid:List.of("a".repeat(43),"a".repeat(512),"a".repeat(38)+"+/=_-")){
            assertThat(new WebsiteBridgeClient(new ObjectMapper(),"https://site.example",valid,"uten",false).tokenConfigured()).isTrue();
        }
    }
}
