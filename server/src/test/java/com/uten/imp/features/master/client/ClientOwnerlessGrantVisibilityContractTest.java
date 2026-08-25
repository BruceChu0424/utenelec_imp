package com.uten.imp.features.master.client;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ClientOwnerlessGrantVisibilityContractTest {

    @Test
    void jpaAndNativeViewerPredicatesRequireAnAssignedOwner() throws Exception {
        String policy = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/client/ClientAccessPolicy.java"));

        assertThat(policy)
                .contains("assignedOwnerOnly(root, cb, cb.exists(shared))")
                .contains("owner_employee_id IS NOT NULL AND EXISTS")
                .contains("if (ownerEmployeeId == null) return scope.canAssign();");
    }

    @Test
    void everyCustomerReadSurfaceUsesTheSameObjectPolicy() throws Exception {
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/client/ClientService.java"));

        assertThat(section(service, "public PageResponse<ClientListItem> list(",
                "public List<ClientDictItem> dict()"))
                .contains("clientAccessPolicy.readablePredicate");
        assertThat(section(service, "public List<ClientDictItem> dict(boolean",
                "private static void addEq"))
                .contains("clientAccessPolicy.readablePredicate");
        assertThat(section(service, "public ExportPayload export(",
                "public ClientFacets facets(UUID categoryId)"))
                .contains("PageResponse<ClientListItem> page = list(f");
        assertThat(section(service, "public ClientFacets facets(UUID categoryId,",
                "private void requireReadable"))
                .contains("clientAccessPolicy.nativeReadScope");
        assertThat(section(service, "public ClientDetail detail(",
                "public ClientDetail create("))
                .contains("clientAccessPolicy.requireReadable");
    }

    private static String section(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        assertThat(from).as(start).isGreaterThanOrEqualTo(0);
        assertThat(to).as(end).isGreaterThan(from);
        return source.substring(from, to);
    }
}
