package com.uten.imp.businesschain;

import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Actual GET mappings, permission checks and PostgreSQL-enforced read-only business queries. */
class ReadOnlyPreviewHttpPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired PlatformTransactionManager transactions;

    @Test
    void previewGetsKeepTheirViewPermissionsAndCannotChangeCategoryOrStockFacts() throws Exception {
        Employee employee = newEmployee(adminToken());
        UUID material = UUID.randomUUID(), materialChild = UUID.randomUUID();
        UUID mould = UUID.randomUUID(), mouldChild = UUID.randomUUID();
        UUID goods = UUID.randomUUID(), tool = UUID.randomUUID();
        jdbc.update("INSERT INTO material_categories(id,code,name,parent_id) VALUES (?,?,?,NULL),(?,?,?,?)",
                material, "RP-" + material, "Read preview root", materialChild, "RP-" + materialChild, "Read preview child", material);
        jdbc.update("INSERT INTO mould_categories(id,code,name,parent_id) VALUES (?,?,?,NULL),(?,?,?,?)",
                mould, "RP-" + mould, "Read preview root", mouldChild, "RP-" + mouldChild, "Read preview child", mould);
        jdbc.update("INSERT INTO goods(id,category_id,code,name,code_sequence) VALUES (?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                goods, materialChild, "RP-" + goods, "Preview goods");
        jdbc.update("INSERT INTO moulds(id,category_id,code,name,code_sequence) VALUES (?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM moulds))",
                tool, mouldChild, "RP-" + tool, "Preview mould");
        List<?> before = facts(material, materialChild, mould, mouldChild, goods, tool);
        var read = new TransactionTemplate(transactions);
        read.setReadOnly(true);
        read.executeWithoutResult(status -> {
            assertEquals("on", jdbc.queryForObject("SHOW transaction_read_only", String.class));
            Authentication viewer = actor(employee, Set.of("material_category:view", "mould_category:view", "stock:view"));
            MvcResult materialPreview = query("/api/master/material-categories/" + material + "/delete-preview", viewer, 200);
            assertEquals(material.toString(), readJson(materialPreview).path("id").asText());
            assertEquals(1, readJson(materialPreview).path("descendantCount").asInt());
            assertEquals(1, readJson(materialPreview).path("goodsCount").asLong());
            MvcResult mouldPreview = query("/api/master/mould-categories/" + mould + "/delete-preview", viewer, 200);
            assertEquals(mould.toString(), readJson(mouldPreview).path("id").asText());
            assertEquals(1, readJson(mouldPreview).path("descendantCount").asInt());
            assertEquals(1, readJson(mouldPreview).path("mouldCount").asLong());
            assertEquals(0, readJson(query("/api/stock/docs/defective-moves/options", viewer, 200)).path("kinds").size());
            for (var channel : List.of(List.of("stock:defective_transfer", "TO_DEFECTIVE"), List.of("stock:defective_release", "DEFECT_RELEASE"))) {
                var options = readJson(query("/api/stock/docs/defective-moves/options", actor(employee, Set.of(channel.getFirst())), 200)).path("kinds");
                assertEquals(1, options.size());
                assertEquals(channel.getLast(), options.get(0).asText());
            }
            Authentication denied = actor(employee, Set.of());
            for (String endpoint : List.of("/api/master/material-categories/" + material + "/delete-preview",
                    "/api/master/mould-categories/" + mould + "/delete-preview", "/api/stock/docs/defective-moves/options")) {
                assertEquals("FORBIDDEN", readJson(query(endpoint, denied, 403)).path("code").asText());
            }
            assertEquals("on", jdbc.queryForObject("SHOW transaction_read_only", String.class));
        });
        assertEquals(before, facts(material, materialChild, mould, mouldChild, goods, tool));
    }

    private MvcResult query(String path, Authentication actor, int expected) {
        MvcResult response = assertDoesNotThrow(() -> mvc.perform(get(path).with(authenticated(actor))).andReturn());
        assertEquals(expected, response.getResponse().getStatus(), body(response));
        return response;
    }

    private com.fasterxml.jackson.databind.JsonNode readJson(MvcResult response) {
        return assertDoesNotThrow(() -> json(response));
    }

    private static Authentication actor(Employee employee, Set<String> permissions) {
        var user = new AuthUser(UUID.fromString(employee.userId()), UUID.fromString(employee.employeeId()),
                employee.loginAccount(), permissions, false, true, false);
        return new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities());
    }

    private List<?> facts(UUID material, UUID materialChild, UUID mould, UUID mouldChild, UUID goods, UUID tool) {
        return jdbc.queryForList("""
                SELECT 'material' AS kind,id::text,xmin::text AS revision,to_jsonb(category)::text AS facts
                FROM material_categories category WHERE id IN (?,?)
                UNION ALL SELECT 'mould_category',id::text,xmin::text,to_jsonb(category)::text
                FROM mould_categories category WHERE id IN (?,?)
                UNION ALL SELECT 'goods',id::text,xmin::text,to_jsonb(goods)::text FROM goods WHERE id=?
                UNION ALL SELECT 'mould',id::text,xmin::text,to_jsonb(mould)::text FROM moulds mould WHERE id=?
                UNION ALL SELECT 'stock_documents','',count(*)::text,'' FROM stock_documents
                UNION ALL SELECT 'stock_movements','',count(*)::text,'' FROM stock_movements
                ORDER BY kind,id
                """, material, materialChild, mould, mouldChild, goods, tool);
    }
}
