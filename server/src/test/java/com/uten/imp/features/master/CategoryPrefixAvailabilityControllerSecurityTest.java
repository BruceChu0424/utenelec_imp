package com.uten.imp.features.master;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.mastercode.CategoryPrefixAvailability;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.master.clientcategory.ClientCategoryController;
import com.uten.imp.features.master.clientcategory.ClientCategoryService;
import com.uten.imp.features.master.materialcategory.MaterialCategoryController;
import com.uten.imp.features.master.materialcategory.MaterialCategoryService;
import com.uten.imp.features.master.mouldcategory.MouldCategoryController;
import com.uten.imp.features.master.mouldcategory.MouldCategoryService;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryController;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.test.util.AopTestUtils;

import java.util.List;
import java.util.UUID;

import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class CategoryPrefixAvailabilityControllerSecurityTest {
    @Configuration
    @EnableMethodSecurity
    static class Config {
        @Bean AuditDetailViewRecorder audit() { return mock(AuditDetailViewRecorder.class); }
        @Bean MaterialCategoryService materials() { return mock(MaterialCategoryService.class); }
        @Bean MouldCategoryService moulds() { return mock(MouldCategoryService.class); }
        @Bean ClientCategoryService clients() { return mock(ClientCategoryService.class); }
        @Bean SupplierCategoryService suppliers() { return mock(SupplierCategoryService.class); }
        @Bean MaterialCategoryController materialController(MaterialCategoryService service, AuditDetailViewRecorder audit) {
            return new MaterialCategoryController(service, audit);
        }
        @Bean MouldCategoryController mouldController(MouldCategoryService service, AuditDetailViewRecorder audit) {
            return new MouldCategoryController(service, audit);
        }
        @Bean ClientCategoryController clientController(ClientCategoryService service, AuditDetailViewRecorder audit) {
            return new ClientCategoryController(service, audit);
        }
        @Bean SupplierCategoryController supplierController(SupplierCategoryService service, AuditDetailViewRecorder audit) {
            return new SupplierCategoryController(service, audit);
        }
    }

    private AnnotationConfigApplicationContext context;
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        context = new AnnotationConfigApplicationContext(Config.class);
        mvc = MockMvcBuilders.standaloneSetup(
                        context.getBean(MaterialCategoryController.class),
                        context.getBean(MouldCategoryController.class),
                        context.getBean(ClientCategoryController.class),
                        context.getBean(SupplierCategoryController.class))
                .setControllerAdvice(new GlobalExceptionHandler()).build();
    }

    @AfterEach
    void cleanUp() {
        SecurityContextHolder.clearContext();
        context.close();
    }

    @ParameterizedTest
    @CsvSource({
            "material,material_category", "mould,mould_category",
            "client,client_category", "supplier,supplier_category"
    })
    void createAndEditAuthoritiesCanCheckTheirOwnDomain(String path, String authority) throws Exception {
        UUID id = UUID.randomUUID();
        var occupied = new CategoryPrefixAvailability("UG", false, CategoryPrefixAvailability.OCCUPIED_MESSAGE);
        when(business(MaterialCategoryService.class).prefixAvailability("ug", id)).thenReturn(occupied);
        when(business(MouldCategoryService.class).prefixAvailability("ug", id)).thenReturn(occupied);
        when(business(ClientCategoryService.class).prefixAvailability("ug", id)).thenReturn(occupied);
        when(business(SupplierCategoryService.class).prefixAvailability("ug", id)).thenReturn(occupied);

        for (String action : List.of("create", "edit")) {
            login(authority + ":" + action);
            mvc.perform(get("/api/master/" + path + "-categories/prefix-availability")
                            .param("prefix", "ug").param("categoryId", id.toString()))
                    .andExpect(status().isOk())
                    .andExpect(jsonPath("$.normalizedPrefix").value("UG"))
                    .andExpect(jsonPath("$.available").value(false))
                    .andExpect(jsonPath("$.message").value(CategoryPrefixAvailability.OCCUPIED_MESSAGE));
        }
        verify(context.getBean(AuditDetailViewRecorder.class), never())
                .record(any(), any(), any(), any(), any(), any());
    }

    @ParameterizedTest
    @CsvSource({
            "material,material_category", "mould,mould_category",
            "client,client_category", "supplier,supplier_category"
    })
    void viewingOrEditingAnotherDomainCannotProbePrefixes(String path, String authority) throws Exception {
        for (String granted : List.of(authority + ":view", "unrelated_category:edit")) {
            login(granted);
            mvc.perform(get("/api/master/" + path + "-categories/prefix-availability")
                            .param("prefix", "UG"))
                    .andExpect(status().isForbidden());
        }
        verifyNoInteractions(business(MaterialCategoryService.class),
                business(MouldCategoryService.class), business(ClientCategoryService.class),
                business(SupplierCategoryService.class));
    }

    private <T> T business(Class<T> type) {
        return AopTestUtils.getUltimateTargetObject(context.getBean(type));
    }

    private void login(String authority) {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("staff", "unused",
                        List.of(new SimpleGrantedAuthority(authority))));
    }
}
