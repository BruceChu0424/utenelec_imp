package com.uten.imp.config;

import com.uten.imp.config.props.DeploymentProperties;
import org.apache.catalina.connector.Connector;
import org.apache.coyote.http11.Http11NioProtocol;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.tomcat.servlet.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * The remote identity is a real connector, never a caller-supplied HTTP header.
 * Only the same-host, mTLS-protected reverse proxy can reach this loopback listener.
 */
@Configuration(proxyBeanMethods = false)
public class RemoteIngressConnectorConfiguration {

    @Bean
    WebServerFactoryCustomizer<TomcatServletWebServerFactory> remoteIngressConnector(
            DeploymentProperties properties, @Value("${server.port:8080}") int primaryPort,
            @Value("${spring.datasource.hikari.maximum-pool-size:20}") int databasePoolSize) {
        return factory -> {
            if (!properties.isRemoteIngressEnabled()) return;
            // Forwarded scheme/host may be restored, but the security boundary
            // must retain the real listener port even if a proxy sends port=443.
            for (var valve : factory.getEngineValves()) {
                if (valve instanceof org.apache.catalina.valves.RemoteIpValve remoteIp) {
                    remoteIp.setChangeLocalPort(false);
                }
            }
            if (primaryPort == properties.getRemoteIngressPort()) {
                throw new IllegalStateException("Remote and office connectors must use different ports");
            }
            if (!"local".equalsIgnoreCase(properties.getSite())) {
                throw new IllegalStateException("The remote ingress connector belongs to the local business server");
            }
            if (properties.getRemoteMaxConcurrentRequests() + 2 > databasePoolSize - 4) {
                throw new IllegalStateException("Remote requests plus two health probes must leave at least four database connections for local work");
            }
            Connector remote = new Connector(TomcatServletWebServerFactory.DEFAULT_PROTOCOL);
            remote.setPort(properties.getRemoteIngressPort());
            remote.setScheme("https");
            remote.setSecure(true);
            remote.setProperty("address", "127.0.0.1");
            remote.setMaxPostSize(2 * 1024 * 1024);
            remote.setProperty("maxHttpRequestHeaderSize", "16384");
            remote.setProperty("connectionTimeout", "10000");
            remote.setProperty("keepAliveTimeout", "15000");
            if (remote.getProtocolHandler() instanceof Http11NioProtocol protocol) {
                protocol.setMaxConnections(64);
                protocol.setMaxThreads(24);
                protocol.setAcceptCount(16);
                // Additional connectors do not inherit the primary connector's
                // compression customization. JSON lists must not cross the WAN raw.
                protocol.setCompression("on");
                protocol.setCompressibleMimeType("application/json");
                protocol.setCompressionMinSize(4096);
            }
            factory.addAdditionalConnectors(remote);
        };
    }
}
