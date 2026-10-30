package com.uten.imp.config;

import com.uten.imp.config.props.DeploymentProperties;
import org.apache.coyote.http11.Http11NioProtocol;
import org.junit.jupiter.api.Test;
import org.springframework.boot.tomcat.servlet.TomcatServletWebServerFactory;

import static org.junit.jupiter.api.Assertions.*;

class RemoteIngressConnectorConfigurationTest {
    private final RemoteIngressConnectorConfiguration configuration = new RemoteIngressConnectorConfiguration();

    @Test
    void transportIsOffByDefaultAndCannotBindItsConnectorToTheNetwork() {
        var properties = new DeploymentProperties();
        var factory = new TomcatServletWebServerFactory();
        configuration.remoteIngressConnector(properties,8080,20).customize(factory);
        assertTrue(factory.getAdditionalConnectors().isEmpty());
        properties.setRemoteIngressEnabled(true);
        var forwarded = new org.apache.catalina.valves.RemoteIpValve();
        forwarded.setChangeLocalPort(true);
        factory.addEngineValves(forwarded);
        configuration.remoteIngressConnector(properties,8080,20).customize(factory);
        assertFalse(forwarded.isChangeLocalPort(),"Proxy metadata must never rewrite connector identity");
        assertEquals(1,factory.getAdditionalConnectors().size());
        var connector = factory.getAdditionalConnectors().iterator().next();
        assertEquals(8082,connector.getPort());
        assertEquals("127.0.0.1",((Http11NioProtocol)connector.getProtocolHandler()).getAddress().getHostAddress());
        assertTrue(connector.getSecure());
        assertEquals(64,((Http11NioProtocol)connector.getProtocolHandler()).getMaxConnections());
    }

    @Test
    void invalidCapacityPortOrSiteCannotStart() {
        var properties = new DeploymentProperties();
        properties.setRemoteIngressEnabled(true);
        assertThrows(IllegalStateException.class,() -> configuration.remoteIngressConnector(properties,8082,20)
                .customize(new TomcatServletWebServerFactory()));
        assertThrows(IllegalStateException.class,() -> configuration.remoteIngressConnector(properties,8080,8)
                .customize(new TomcatServletWebServerFactory()));
        properties.setSite("cloud");
        assertThrows(IllegalStateException.class,() -> configuration.remoteIngressConnector(properties,8080,20)
                .customize(new TomcatServletWebServerFactory()));
    }

    @Test
    void realTomcatKeepsListenerIdentityUnderForwardedPortAndCompressesRemoteJson() throws Exception {
        var properties = new DeploymentProperties();
        properties.setRemoteIngressEnabled(true);
        int remotePort;
        try (var reservation = new java.net.ServerSocket(0,1,java.net.InetAddress.getLoopbackAddress())) {
            remotePort = reservation.getLocalPort();
        }
        properties.setRemoteIngressPort(remotePort);
        var factory = new TomcatServletWebServerFactory(0);
        factory.setAddress(java.net.InetAddress.getLoopbackAddress());
        var forwarded = new org.apache.catalina.valves.RemoteIpValve();
        forwarded.setInternalProxies("127\\..*");
        forwarded.setProtocolHeader("X-Forwarded-Proto");
        forwarded.setPortHeader("X-Forwarded-Port");
        forwarded.setChangeLocalPort(true);
        factory.addEngineValves(forwarded);
        configuration.remoteIngressConnector(properties,0,20).customize(factory);
        var server = factory.getWebServer(context -> {
            var servlet = new jakarta.servlet.http.HttpServlet() {
                @Override protected void doGet(jakarta.servlet.http.HttpServletRequest request,
                                               jakarta.servlet.http.HttpServletResponse response) throws java.io.IOException {
                    response.setContentType("application/json");
                    response.getWriter().write("{\"localPort\":"+request.getLocalPort()+",\"data\":\""+"x".repeat(8192)+"\"}");
                }
            };
            context.addServlet("listener-proof",servlet).addMapping("/api/probe");
        });
        try {
            server.start();
            var client = java.net.http.HttpClient.newHttpClient();
            var local = client.send(java.net.http.HttpRequest.newBuilder(
                    java.net.URI.create("http://127.0.0.1:"+server.getPort()+"/api/probe"))
                    .header("X-Forwarded-Proto","https").header("X-Forwarded-Port",Integer.toString(remotePort))
                    .GET().build(),java.net.http.HttpResponse.BodyHandlers.ofString());
            assertEquals(200,local.statusCode());
            assertTrue(local.body().startsWith("{\"localPort\":"+server.getPort()+","));
            var remote = client.send(java.net.http.HttpRequest.newBuilder(
                    java.net.URI.create("http://127.0.0.1:"+remotePort+"/api/probe"))
                    .header("X-Forwarded-Proto","https").header("X-Forwarded-Port","443")
                    .header("Accept-Encoding","gzip").GET().build(),java.net.http.HttpResponse.BodyHandlers.ofByteArray());
            assertEquals(200,remote.statusCode());
            assertEquals("gzip",remote.headers().firstValue("Content-Encoding").orElseThrow());
            assertTrue(remote.body().length<1024,"Large repeated JSON must not use raw WAN bandwidth");
            try (var zipped = new java.util.zip.GZIPInputStream(new java.io.ByteArrayInputStream(remote.body()))) {
                assertTrue(new String(zipped.readAllBytes(),java.nio.charset.StandardCharsets.UTF_8)
                        .startsWith("{\"localPort\":"+remotePort+","));
            }
        } finally {
            server.stop();
        }
    }

    @Test
    void realTomcatDecodedServletAndPathInfoKeepEncodedApiInsideNetworkAndRemoteAccessGuard() throws Exception {
        var properties=new DeploymentProperties();properties.setRemoteIngressEnabled(true);
        properties.setLocalAllowedCidrs("127.0.0.1/32,::1/128");
        int remotePort;
        try(var reservation=new java.net.ServerSocket(0,1,java.net.InetAddress.getLoopbackAddress())) {remotePort=reservation.getLocalPort();}
        properties.setRemoteIngressPort(remotePort);
        var factory=new TomcatServletWebServerFactory(0);factory.setAddress(java.net.InetAddress.getLoopbackAddress());
        var forwarded=new org.apache.catalina.valves.RemoteIpValve();forwarded.setInternalProxies("127\\..*|::1");
        forwarded.setRemoteIpHeader("X-Forwarded-For");factory.addEngineValves(forwarded);
        configuration.remoteIngressConnector(properties,0,20).customize(factory);
        var mapper=new com.fasterxml.jackson.databind.ObjectMapper().findAndRegisterModules();
        var audit=org.mockito.Mockito.mock(com.uten.imp.audit.AuditService.class);
        var network=new com.uten.imp.security.LocalNetworkAccessPolicy(properties);
        var origins=new com.uten.imp.security.TrustedRequestOriginPolicy(properties,network);
        var policy=new com.uten.imp.security.RemoteAccessPolicy(properties,origins);
        var localGuard=new com.uten.imp.security.LocalNetworkGuardFilter(mapper,audit,network,origins);
        var admission=new jakarta.servlet.http.HttpFilter(){
            @Override protected void doFilter(jakarta.servlet.http.HttpServletRequest request,jakarta.servlet.http.HttpServletResponse response,
                                                   jakarta.servlet.FilterChain chain) throws java.io.IOException,jakarta.servlet.ServletException {
                var authentication=org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication();
                if(authentication!=null && authentication.getPrincipal() instanceof com.uten.imp.security.AuthUser principal) {
                    try {policy.requireAuthenticatedAccess(principal);}
                    catch(com.uten.imp.common.web.ApiException denied){
                        response.setStatus(denied.getCode().getHttpStatus());
                        response.setContentType("application/json");
                        response.getWriter().write("{\"code\":\""+denied.getCode().name()+"\"}");
                        return;
                    }
                }
                chain.doFilter(request,response);
            }
        };
        var reached=new java.util.concurrent.atomic.AtomicInteger();
        var server=factory.getWebServer(context->{
            context.addFilter("security-path-proof",new jakarta.servlet.http.HttpFilter(){
                @Override protected void doFilter(jakarta.servlet.http.HttpServletRequest request,jakarta.servlet.http.HttpServletResponse response,
                                                   jakarta.servlet.FilterChain chain) throws java.io.IOException,jakarta.servlet.ServletException {
                    response.setHeader("X-Probe-Raw",request.getRequestURI());
                    response.setHeader("X-Probe-Servlet",request.getServletPath());
                    response.setHeader("X-Probe-Info",request.getPathInfo());
                    var user=new com.uten.imp.security.AuthUser(java.util.UUID.randomUUID(),java.util.UUID.randomUUID(),"office-token",
                            java.util.Set.of(),false,true,false,false,null,java.util.UUID.randomUUID());
                    org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(
                            new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
                    try {localGuard.doFilter(request,response,(req,res)->admission.doFilter(req,res,chain));}
                    finally {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
                }
            }).addMappingForUrlPatterns(java.util.EnumSet.of(jakarta.servlet.DispatcherType.REQUEST),false,"/*");
            context.addServlet("decoded-api",new jakarta.servlet.http.HttpServlet(){
                @Override protected void doGet(jakarta.servlet.http.HttpServletRequest request,jakarta.servlet.http.HttpServletResponse response)
                        throws java.io.IOException {reached.incrementAndGet();response.getWriter().write(com.uten.imp.security.SecurityRequestPath.withinApplication(request));}
            }).addMapping("/api/*");
        });
        try {
            server.start();var client=java.net.http.HttpClient.newHttpClient();
            for(String path:java.util.List.of("/%61pi/auth/me","/api/%61uth/me")) {
                var blocked=client.send(java.net.http.HttpRequest.newBuilder(java.net.URI.create("http://127.0.0.1:"+remotePort+path)).GET().build(),
                        java.net.http.HttpResponse.BodyHandlers.ofString());
                assertEquals(403,blocked.statusCode());assertTrue(blocked.body().contains("REMOTE_ACCESS_DENIED"));
                assertEquals(path,blocked.headers().firstValue("X-Probe-Raw").orElseThrow());
                assertEquals("/api",blocked.headers().firstValue("X-Probe-Servlet").orElseThrow());
                assertEquals("/auth/me",blocked.headers().firstValue("X-Probe-Info").orElseThrow());
                var deniedNetwork=client.send(java.net.http.HttpRequest.newBuilder(java.net.URI.create("http://127.0.0.1:"+server.getPort()+path))
                                .header("X-Forwarded-For","203.0.113.40").GET().build(),java.net.http.HttpResponse.BodyHandlers.ofString());
                assertEquals(403,deniedNetwork.statusCode());assertTrue(deniedNetwork.body().contains("FORBIDDEN"));
            }
            assertEquals(0,reached.get(),"Encoded routing must never reach business code before admission");
            var local=client.send(java.net.http.HttpRequest.newBuilder(java.net.URI.create("http://127.0.0.1:"+server.getPort()+"/%61pi/auth/me")).GET().build(),
                    java.net.http.HttpResponse.BodyHandlers.ofString());
            assertEquals(200,local.statusCode());assertEquals("/api/auth/me",local.body());
        } finally {server.stop();}
    }
}
