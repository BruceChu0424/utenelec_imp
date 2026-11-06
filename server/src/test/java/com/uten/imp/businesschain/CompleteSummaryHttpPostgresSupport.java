package com.uten.imp.businesschain;
import com.fasterxml.jackson.databind.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.core.context.SecurityContextHolder;
import org.junit.jupiter.api.AfterEach;
import java.net.*;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import static org.assertj.core.api.Assertions.*;
/** Transport/auth fixture only: all production controller/service/SQL and original budgets stay real. */
abstract class CompleteSummaryHttpPostgresSupport {
    @LocalServerPort protected int port;
    @Autowired protected ObjectMapper json;
    @Autowired protected JdbcTemplate db;
    @Autowired protected PasswordEncoder passwords;
    @Autowired protected AutowireCapableBeanFactory beans;
    protected final HttpClient http=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(15)).build();
    @AfterEach protected void clear(){SecurityContextHolder.clearContext();}


    protected static String encode(String text){return URLEncoder.encode(text,StandardCharsets.UTF_8);}
    protected JsonNode body(HttpResponse<byte[]> response) throws Exception {return json.readTree(response.body());}
    protected HttpResponse<byte[]> request(String method,String path,byte[] body,String token,int status) throws Exception {
        var request=HttpRequest.newBuilder(URI.create("http://127.0.0.1:"+port+path)).timeout(Duration.ofSeconds(15));
        if(token!=null)request.header("Authorization","Bearer "+token);
        if(body!=null)request.header("Content-Type","application/json");
        request.method(method,body==null?HttpRequest.BodyPublishers.noBody():HttpRequest.BodyPublishers.ofByteArray(body));
        HttpResponse<byte[]> response=http.send(request.build(),HttpResponse.BodyHandlers.ofByteArray());
        assertThat(response.statusCode()).as("%s %s",method,path.replaceAll("readSnapshotRevision=[^&]+","readSnapshotRevision=<opaque>")) .isEqualTo(status);
        return response;
    }
}
