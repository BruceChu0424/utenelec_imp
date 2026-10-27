package com.uten.imp.features.reporting.export;

import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.stereotype.Component;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;

/** Fingerprints application bytes, bundled SQL rules and dependency versions without a Git checkout. */
@Component
public class ReportExportBuildIdentity {
    public static final String CONTRACT="report-v1";
    private final ClassLoader loader;
    private volatile String cached;
    public ReportExportBuildIdentity() {this(ReportExportBuildIdentity.class.getClassLoader());}
    ReportExportBuildIdentity(ClassLoader loader) {this.loader=Objects.requireNonNull(loader);}
    public synchronized String revision() {
        if(cached!=null)return cached;
        try {
            var entries=new TreeMap<String,byte[]>();
            boolean applicationClasses=false;
            var resolver=new PathMatchingResourcePatternResolver(loader);
            for(var pattern:List.of("classpath*:com/uten/imp/**/*.class","classpath*:db/migration/*.sql",
                    "classpath*:META-INF/maven/**/pom.properties")) {
              for(var resource:resolver.getResources(pattern)) {
                String marker=pattern.startsWith("classpath*:com/")?"com/uten/imp/"
                        :pattern.startsWith("classpath*:db/")?"db/migration/":"META-INF/maven/";
                String url=resource.getURL().toString();int offset=url.lastIndexOf(marker);
                if(offset<0)throw new IOException("Unknown export build resource path");
                String key=url.substring(offset);
                if(key.startsWith("com/uten/imp/"))applicationClasses=true;
                if(entries.containsKey(key))continue;
                // Match actual ClassLoader precedence, rather than rejecting an unused
                // dependency/test resource which shadows the same classpath name.
                var selected=loader.getResource(key);
                if(selected==null)throw new IOException("Selected export resource is unavailable");
                byte[] hash;
                try(var input=selected.openStream()) {
                    var digest=MessageDigest.getInstance("SHA-256");
                    try(var hashing=new java.security.DigestOutputStream(java.io.OutputStream.nullOutputStream(),digest)) {
                        input.transferTo(hashing);
                    }
                    hash=digest.digest();
                }
                entries.put(key,hash);
              }
            }
            if(entries.isEmpty() || !applicationClasses)throw new IOException("Application class fingerprint is unavailable");
            var digest=MessageDigest.getInstance("SHA-256");
            entries.forEach((path,hash) -> {digest.update(path.getBytes(StandardCharsets.UTF_8));digest.update((byte)0);digest.update(hash);});
            cached=HexFormat.of().formatHex(digest.digest());return cached;
        } catch(IOException|GeneralSecurityException error) {throw new IllegalStateException("Export build identity is unavailable",error);}
    }
}
