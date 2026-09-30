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
}
