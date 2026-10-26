package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import org.springframework.stereotype.Component;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;

@Component
public class GoodsCostJson {
    private final ObjectMapper json;
    public GoodsCostJson(ObjectMapper json) { this.json=json.copy().enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS); }
    public String write(Object value) {
        try { return json.writeValueAsString(value); }
        catch(Exception ex) { throw new IllegalStateException("成本数据无法序列化",ex); }
    }
    public <T> T read(String value,Class<T> type) {
        try { return json.readValue(value,type); }
        catch(Exception ex) { throw new IllegalStateException("成本快照无法读取",ex); }
    }
    public String hash(Object value) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(write(value).getBytes(StandardCharsets.UTF_8))); }
        catch(Exception ex) { throw new IllegalStateException("成本摘要无法生成",ex); }
    }
    /** Same Writer-based canonical bytes as write(value).getBytes(UTF_8), without
     * retaining the complete document string. Nested stream arrays stay bounded. */
    public String hashStreaming(Object value) {
        try {
            var digest=MessageDigest.getInstance("SHA-256");
            try(var output=new java.security.DigestOutputStream(java.io.OutputStream.nullOutputStream(),digest);
                var writer=new java.io.OutputStreamWriter(output,StandardCharsets.UTF_8)) {
                json.writeValue(writer,value);
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch(Exception ex) {
            for(Throwable cause=ex;cause!=null;cause=cause.getCause()) {
                if(cause instanceof com.uten.imp.common.web.ApiException api)throw api;
                if(cause instanceof java.util.concurrent.CancellationException cancelled)throw cancelled;
            }
            throw new IllegalStateException("成本摘要无法生成",ex);
        }
    }
}
