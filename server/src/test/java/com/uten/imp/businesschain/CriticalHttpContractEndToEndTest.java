package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.ByteArrayInputStream;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.time.Duration;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Black-box HTTP proof for the release-critical account and workbook-download contracts.
 * Starts real Tomcat and PostgreSQL; requests cross the complete security filter/controller stack.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.jwt.secret=http-contract-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=http-contract-pgp-key-0123456789-test-only",
                "uten.crypto.hmac-key=http-contract-hmac-key-0123456789-test-only",
                "uten.bootstrap.admin-password=HttpBootstrapPass-1!"
        })
class CriticalHttpContractEndToEndTest {

    private static final Set<String> HTTP_METHODS = Set.of(
            "get", "post", "put", "patch", "delete", "head", "options");
    private static final String PROBE_UUID = "00000000-0000-0000-0000-000000000001";

    private static final String ADMIN_LOGIN = "17665410007";
    private static final String ADMIN_INITIAL_PASSWORD = "HttpBootstrapPass-1!";
    private static final String ADMIN_NEW_PASSWORD = "HttpAdminPass-2!";
    private static final String EMPLOYEE_LOGIN = "13800138017";
    private static final String EMPLOYEE_INITIAL_PASSWORD = "31002X";
    private static final String EMPLOYEE_NEW_PASSWORD = "EmployeePass-3!";

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static java.nio.file.Path attachmentDir;

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        try {
            attachmentDir = Files.createTempDirectory("uten-http-contract-");
        } catch (java.io.IOException exception) {
            throw new IllegalStateException("Cannot create HTTP contract test directory", exception);
        }
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        registry.add("uten.storage.local-dir", () -> attachmentDir.toString());
    }

    @LocalServerPort
    private int port;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private JdbcTemplate jdbc;

    private final HttpClient http = HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();

    @Test
    void accountProvisioningPasswordGateAndOptionalWorkbookPasswordWorkOverRealHttp() throws Exception {
        HttpResponse<byte[]> health = request("GET", "/actuator/health", null, null);
        assertStatus(health, 200);
        assertEquals("UP", json(health).path("status").asText());

        JsonNode initialAdmin = login(ADMIN_LOGIN, ADMIN_INITIAL_PASSWORD);
        assertTrue(initialAdmin.path("mustChangePassword").asBoolean());
        assertTrue(initialAdmin.path("user").path("mustChangePassword").asBoolean());
        String initialAdminToken = initialAdmin.path("accessToken").asText();

        HttpResponse<byte[]> blocked = request(
                "GET", "/api/org/employees?page=1&size=1", null, initialAdminToken);
        assertStatus(blocked, 403);
        assertEquals("PASSWORD_CHANGE_REQUIRED", json(blocked).path("code").asText());

        HttpResponse<byte[]> allowedMe = request("GET", "/api/auth/me", null, initialAdminToken);
        assertStatus(allowedMe, 200);
        assertTrue(json(allowedMe).path("mustChangePassword").asBoolean());

        JsonNode changedAdmin = changePassword(
                initialAdminToken, ADMIN_INITIAL_PASSWORD, ADMIN_NEW_PASSWORD);
        assertFalse(changedAdmin.path("mustChangePassword").asBoolean());
        assertFalse(changedAdmin.path("user").path("mustChangePassword").asBoolean());
        String adminToken = changedAdmin.path("accessToken").asText();

        HttpResponse<byte[]> staleAdminToken = request("GET", "/api/auth/me", null, initialAdminToken);
        assertStatus(staleAdminToken, 401);
        assertEquals("UNAUTHORIZED", json(staleAdminToken).path("code").asText());

        String departmentId = jdbc.queryForObject(
                "select id::text from departments where code='DEPT_HR' and is_deleted=false",
                String.class);
        ObjectNode onboarding = onboardingRequest(departmentId);
        HttpResponse<byte[]> created = request(
                "POST", "/api/org/employees", objectMapper.writeValueAsBytes(onboarding), adminToken);
        assertStatus(created, 200);
        JsonNode credential = json(created);
        assertEquals(EMPLOYEE_LOGIN, credential.path("loginAccount").asText());
        assertEquals(EMPLOYEE_INITIAL_PASSWORD, credential.path("temporaryPassword").asText());

        JsonNode initialEmployee = login(EMPLOYEE_LOGIN, EMPLOYEE_INITIAL_PASSWORD);
        assertTrue(initialEmployee.path("mustChangePassword").asBoolean());
        String initialEmployeeToken = initialEmployee.path("accessToken").asText();

        HttpResponse<byte[]> blockedVerification = request(
                "POST",
                "/api/auth/verify-password",
                objectMapper.writeValueAsBytes(java.util.Map.of("password", EMPLOYEE_INITIAL_PASSWORD)),
                initialEmployeeToken);
        assertStatus(blockedVerification, 403);
        assertEquals("PASSWORD_CHANGE_REQUIRED", json(blockedVerification).path("code").asText());

        JsonNode changedEmployee = changePassword(
                initialEmployeeToken, EMPLOYEE_INITIAL_PASSWORD, EMPLOYEE_NEW_PASSWORD);
        assertFalse(changedEmployee.path("mustChangePassword").asBoolean());
        String employeeToken = changedEmployee.path("accessToken").asText();
        HttpResponse<byte[]> employeeMe = request("GET", "/api/auth/me", null, employeeToken);
        assertStatus(employeeMe, 200);
        assertFalse(json(employeeMe).path("mustChangePassword").asBoolean());

        HttpResponse<byte[]> plainWorkbook = request(
                "POST",
                "/api/master/currencies/export",
                objectMapper.writeValueAsBytes(java.util.Map.of()),
                adminToken);
        assertWorkbookResponse(plainWorkbook);
        try (Workbook opened = WorkbookFactory.create(new ByteArrayInputStream(plainWorkbook.body()))) {
            assertTrue(opened.getNumberOfSheets() > 0);
        }

        HttpResponse<byte[]> weakPasswordWorkbook = request(
                "POST",
                "/api/master/currencies/export",
                objectMapper.writeValueAsBytes(java.util.Map.of("password", "1")),
                adminToken);
        assertWorkbookResponse(weakPasswordWorkbook);
        try (Workbook opened = WorkbookFactory.create(
                new ByteArrayInputStream(weakPasswordWorkbook.body()), "1")) {
            assertTrue(opened.getNumberOfSheets() > 0);
        }

        smokeEveryDocumentedHttpOperation(adminToken);
    }

    private JsonNode login(String loginAccount, String password) throws Exception {
        byte[] body = objectMapper.writeValueAsBytes(java.util.Map.of(
                "loginAccount", loginAccount,
                "password", password));
        HttpResponse<byte[]> response = request("POST", "/api/auth/login", body, null);
        assertStatus(response, 200);
        return json(response);
    }

    private JsonNode changePassword(String token, String oldPassword, String newPassword) throws Exception {
        byte[] body = objectMapper.writeValueAsBytes(java.util.Map.of(
                "oldPassword", oldPassword,
                "newPassword", newPassword));
        HttpResponse<byte[]> response = request("POST", "/api/auth/change-password", body, token);
        assertStatus(response, 200);
        return json(response);
    }

    private ObjectNode onboardingRequest(String departmentId) {
        LocalDate employmentDate = LocalDate.now().minusDays(1);
        ObjectNode root = objectMapper.createObjectNode();
        ObjectNode profile = root.putObject("profile");
        profile.put("fullName", "HTTP 新员工");
        profile.put("idType", "身份证");
        profile.put("idNumber", "11010519491231002X");
        profile.put("phone", EMPLOYEE_LOGIN);
        ObjectNode employment = root.putObject("employment");
        employment.put("departmentId", departmentId);
        employment.put("hireDate", employmentDate.toString());
        employment.put("employmentType", "regular");
        employment.put("status", "active");
        employment.put("confirmedAt", employmentDate.toString());
        root.putArray("emergencyContacts");
        root.putArray("certificates");
        root.putArray("educations");
        root.putObject("account").putArray("roles").add("employee");
        return root;
    }

    private HttpResponse<byte[]> request(
            String method,
            String path,
            byte[] body,
            String accessToken) throws Exception {
        HttpRequest.Builder builder = HttpRequest.newBuilder()
                .uri(URI.create("http://127.0.0.1:" + port + path))
                .timeout(Duration.ofSeconds(15))
                .header("Accept", "application/json")
                .method(method, body == null
                        ? HttpRequest.BodyPublishers.noBody()
                        : HttpRequest.BodyPublishers.ofByteArray(body));
        if (body != null) {
            builder.header("Content-Type", "application/json");
        }
        if (accessToken != null) {
            builder.header("Authorization", "Bearer " + accessToken);
        }
        return http.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray());
    }

    private JsonNode json(HttpResponse<byte[]> response) throws Exception {
        return objectMapper.readTree(response.body());
    }

    private static void assertStatus(HttpResponse<byte[]> response, int expected) {
        assertEquals(
                expected,
                response.statusCode(),
                () -> new String(response.body(), StandardCharsets.UTF_8));
    }

    private static void assertWorkbookResponse(HttpResponse<byte[]> response) {
        assertStatus(response, 200);
        assertTrue(response.headers().firstValue("Content-Type").orElse("")
                .startsWith("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"));
        assertTrue(response.body().length > 100);
    }

    /**
     * Sends one method-correct request through every OpenAPI operation. Required parameters receive
     * type-correct probe values and JSON bodies receive an empty object. This is a boundary smoke,
     * not a positive business assertion: deep successful chains are covered separately.
     */
    private void smokeEveryDocumentedHttpOperation(String accessToken) throws Exception {
        HttpResponse<byte[]> docs = request("GET", "/v3/api-docs", null, accessToken);
        assertStatus(docs, 200);
        JsonNode paths = json(docs).path("paths");
        assertTrue(paths.isObject(), "OpenAPI paths missing");

        int operations = 0;
        Map<Integer, Integer> statuses = new TreeMap<>();
        List<String> failures = new ArrayList<>();
        Iterator<Map.Entry<String, JsonNode>> pathIterator = paths.properties().iterator();
        while (pathIterator.hasNext()) {
            Map.Entry<String, JsonNode> pathEntry = pathIterator.next();
            Iterator<Map.Entry<String, JsonNode>> operationIterator =
                    pathEntry.getValue().properties().iterator();
            while (operationIterator.hasNext()) {
                Map.Entry<String, JsonNode> operationEntry = operationIterator.next();
                String method = operationEntry.getKey().toLowerCase(java.util.Locale.ROOT);
                if (!HTTP_METHODS.contains(method)) {
                    continue;
                }
                operations++;
                JsonNode operation = operationEntry.getValue();
                List<JsonNode> parameters = new ArrayList<>();
                pathEntry.getValue().path("parameters").forEach(parameters::add);
                operation.path("parameters").forEach(parameters::add);
                String resolvedPath = resolvePath(pathEntry.getKey(), parameters);
                String query = requiredQuery(parameters);
                String requestPath = query.isEmpty() ? resolvedPath : resolvedPath + "?" + query;

                try {
                    HttpRequest.Builder builder = HttpRequest.newBuilder()
                            .uri(URI.create("http://127.0.0.1:" + port + requestPath))
                            .timeout(Duration.ofSeconds(15))
                            .header("Accept", "application/json")
                            .header("Authorization", "Bearer " + accessToken);
                    for (JsonNode parameter : parameters) {
                        if (parameter.path("required").asBoolean()
                                && "header".equals(parameter.path("in").asText())) {
                            builder.header(parameter.path("name").asText(), probeValue(parameter));
                        }
                    }
                    boolean hasRequestBody = operation.has("requestBody");
                    builder.method(
                            method.toUpperCase(java.util.Locale.ROOT),
                            hasRequestBody
                                    ? HttpRequest.BodyPublishers.ofString("{}", StandardCharsets.UTF_8)
                                    : HttpRequest.BodyPublishers.noBody());
                    if (hasRequestBody) {
                        builder.header("Content-Type", "application/json");
                    }
                    HttpResponse<byte[]> response = http.send(
                            builder.build(), HttpResponse.BodyHandlers.ofByteArray());
                    statuses.merge(response.statusCode(), 1, Integer::sum);
                    if (response.statusCode() >= 500) {
                        failures.add(method.toUpperCase(java.util.Locale.ROOT) + " " + requestPath
                                + " -> " + response.statusCode() + " "
                                + boundedBody(response.body()));
                    }
                } catch (Exception exception) {
                    failures.add(method.toUpperCase(java.util.Locale.ROOT) + " " + requestPath
                            + " -> " + exception.getClass().getSimpleName()
                            + ": " + exception.getMessage());
                }
            }
        }

        System.out.println("HTTP OpenAPI smoke operations=" + operations + ", statuses=" + statuses);
        assertTrue(operations >= 400, "Unexpectedly small OpenAPI surface: " + operations);
        assertTrue(failures.isEmpty(), () -> "HTTP operation smoke failures:\n" + String.join("\n", failures));
    }

    private static String resolvePath(String pathTemplate, List<JsonNode> parameters) {
        String resolved = pathTemplate;
        for (JsonNode parameter : parameters) {
            if ("path".equals(parameter.path("in").asText())) {
                String name = parameter.path("name").asText();
                resolved = resolved.replace("{" + name + "}", encode(probeValue(parameter)));
            }
        }
        while (resolved.contains("{")) {
            int start = resolved.indexOf('{');
            int end = resolved.indexOf('}', start);
            if (end < 0) {
                break;
            }
            String name = resolved.substring(start + 1, end);
            resolved = resolved.substring(0, start)
                    + encode(heuristicProbe(name))
                    + resolved.substring(end + 1);
        }
        return resolved;
    }

    private static String requiredQuery(List<JsonNode> parameters) {
        List<String> pairs = new ArrayList<>();
        for (JsonNode parameter : parameters) {
            if (parameter.path("required").asBoolean()
                    && "query".equals(parameter.path("in").asText())) {
                pairs.add(encode(parameter.path("name").asText())
                        + "=" + encode(probeValue(parameter)));
            }
        }
        return String.join("&", pairs);
    }

    private static String probeValue(JsonNode parameter) {
        JsonNode schema = parameter.path("schema");
        JsonNode enumValues = schema.path("enum");
        if (enumValues.isArray() && !enumValues.isEmpty()) {
            return enumValues.get(0).asText();
        }
        String format = schema.path("format").asText();
        String type = schema.path("type").asText();
        if ("uuid".equals(format)) {
            return PROBE_UUID;
        }
        if ("date".equals(format)) {
            return "2026-01-01";
        }
        if ("date-time".equals(format)) {
            return "2026-01-01T00:00:00Z";
        }
        if ("integer".equals(type) || "number".equals(type)) {
            return "1";
        }
        if ("boolean".equals(type)) {
            return "false";
        }
        return heuristicProbe(parameter.path("name").asText());
    }

    private static String heuristicProbe(String name) {
        String normalized = name.toLowerCase(java.util.Locale.ROOT);
        if (normalized.endsWith("id") || normalized.contains("uuid")) {
            return PROBE_UUID;
        }
        if (normalized.contains("date")) {
            return "2026-01-01";
        }
        if (normalized.equals("year") || normalized.equals("page")
                || normalized.equals("size") || normalized.endsWith("no")) {
            return "1";
        }
        return "probe";
    }

    private static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    private static String boundedBody(byte[] body) {
        String text = new String(body, StandardCharsets.UTF_8).replaceAll("\\s+", " ");
        return text.length() <= 300 ? text : text.substring(0, 300);
    }
}
