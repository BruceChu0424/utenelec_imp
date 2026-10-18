package com.uten.imp.features.webinquiry.management;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.io.ByteArrayOutputStream;
import java.time.Duration;
import java.util.List;
import java.util.Set;
import java.util.Arrays;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.Flow;
import java.util.stream.Collectors;

/** Fixed-origin, bounded, redirect-free server-to-server transport. Never exposes its token. */
@Component
public class WebsiteBridgeClient {
    static final int MAX_BYTES=2*1024*1024;
    private final ObjectMapper json;
    private final HttpClient http;
    private final Set<String> origins;
    private final String token;
    private final String siteId;
    private final boolean localHttp;

    public WebsiteBridgeClient(ObjectMapper json,
            @Value("${uten.website.bridge.allowed-origins:}") String allowedOrigins,
            @Value("${uten.website.bridge.token:}") String token,
            @Value("${uten.website.bridge.site-id:uten}") String siteId,
            @Value("${uten.website.bridge.allow-loopback-http:false}") boolean localHttp) {
        this.json=json;this.token=token;this.siteId=siteId;this.localHttp=localHttp;
        this.origins=Arrays.stream(allowedOrigins.split(",")).map(String::trim).filter(s->!s.isEmpty())
                .map(this::normalizeOrigin).collect(Collectors.toUnmodifiableSet());
        this.http=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3))
                .version(HttpClient.Version.HTTP_1_1)
                .followRedirects(HttpClient.Redirect.NEVER).build();
    }
    public String siteId(){return siteId;}
    public List<String> allowedOrigins(){return origins.stream().sorted().toList();}
    public boolean tokenConfigured(){return token!=null && token.matches("[A-Za-z0-9+/=_-]{43,512}");}
    public boolean configured(String origin){return origin!=null && origins.contains(origin) && tokenConfigured() && !siteId.isBlank();}
    public String validateOrigin(String value){
        String origin=normalizeOrigin(value);
        if(!origins.contains(origin)) throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择管理员预置的受信官网地址");
        return origin;
    }
    private String normalizeOrigin(String raw){
        try {
            URI uri=URI.create(raw);
            String host=uri.getHost();
            boolean https="https".equals(uri.getScheme());
            boolean local=localHttp && "http".equals(uri.getScheme()) && Set.of("localhost","127.0.0.1","[::1]","::1").contains(host);
            if(host==null || !(https||local) || uri.getRawUserInfo()!=null || uri.getRawQuery()!=null || uri.getRawFragment()!=null
                    || (uri.getRawPath()!=null && !uri.getRawPath().isEmpty() && !"/".equals(uri.getRawPath())))
                throw new IllegalArgumentException();
            return new URI(uri.getScheme(),null,host.toLowerCase(java.util.Locale.ROOT),uri.getPort(),null,null,null).toASCIIString();
        } catch(Exception ignored){throw new ApiException(ErrorCode.VALIDATION_FAILED,"官网地址必须是预置 HTTPS origin，本地测试仅允许明确启用的回环地址");}
    }
    public JsonNode get(String origin,String path){return request(origin,path,null);}
    public JsonNode post(String origin,String path,Object payload){return request(origin,path,payload);}
    private JsonNode request(String origin,String path,Object payload){
        validateOrigin(origin);
        if(!configured(origin)) throw new ApiException(ErrorCode.BUSINESS,"官网服务身份尚未配置");
        if(!allowedPath(path))
            throw new IllegalArgumentException("Unsupported website bridge operation");
        try {
            var builder=HttpRequest.newBuilder(URI.create(origin+path)).timeout(Duration.ofSeconds(8))
                    .header("Authorization","Bearer "+token).header("X-Uten-Site-Id",siteId)
                    .header("Accept","application/json");
            if(payload==null) builder.GET();
            else builder.header("Content-Type","application/json").POST(HttpRequest.BodyPublishers.ofByteArray(json.writeValueAsBytes(payload)));
            var response=http.send(builder.build(),ignored->new BoundedBody(MAX_BYTES));
            if(response.statusCode()<200 || response.statusCode()>=300)
                throw new ApiException(ErrorCode.BUSINESS,"官网管理接口返回 "+response.statusCode()+"，请检查服务身份或服务状态");
            JsonNode result=json.readTree(response.body());
            if(result==null || !result.isObject()) throw new ApiException(ErrorCode.BUSINESS,"官网管理接口响应格式不正确");
            return result;
        } catch(ApiException known){throw known;}
        catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new ApiException(ErrorCode.BUSINESS,"官网连接检查已中断");}
        catch(Exception unavailable){throw new ApiException(ErrorCode.BUSINESS,"官网暂不可达或响应不符合约定，请检查连接后重试");}
    }
    static boolean allowedPath(String path){
        if(Set.of("/api/imp/bridge/status","/api/imp/bridge/inquiries?limit=20",
                "/api/imp/bridge/inquiries/ack","/api/imp/bridge/authorizations",
                "/api/imp/bridge/sessions?limit=100","/api/imp/bridge/sessions/renew").contains(path))return true;
        String prefix="/api/imp/bridge/sessions?after=",suffix="&limit=100";
        return path.startsWith(prefix) && path.endsWith(suffix)
                && path.substring(prefix.length(),path.length()-suffix.length()).matches("[A-Za-z0-9_-]{1,128}");
    }
    static final class BoundedBody implements HttpResponse.BodySubscriber<byte[]> {
        private final int limit; private final ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        private final CompletableFuture<byte[]> result=new CompletableFuture<>(); private Flow.Subscription subscription;
        BoundedBody(int limit){this.limit=limit;}
        @Override public CompletionStage<byte[]> getBody(){return result;}
        @Override public void onSubscribe(Flow.Subscription subscription){this.subscription=subscription;subscription.request(Long.MAX_VALUE);}
        @Override public void onNext(List<ByteBuffer> buffers){
            for(ByteBuffer buffer:buffers){if(buffer.remaining()>limit-bytes.size()){subscription.cancel();result.completeExceptionally(new IllegalStateException("Website response exceeds limit"));return;}
                byte[] chunk=new byte[buffer.remaining()];buffer.get(chunk);bytes.writeBytes(chunk);}
        }
        @Override public void onError(Throwable error){result.completeExceptionally(error);}
        @Override public void onComplete(){result.complete(bytes.toByteArray());}
    }
}
