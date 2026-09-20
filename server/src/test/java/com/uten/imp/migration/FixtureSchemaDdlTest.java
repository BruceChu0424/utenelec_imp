package com.uten.imp.migration;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class FixtureSchemaDdlTest {
    @TempDir Path sources;

    @Test void publicQualifiedNamesAreStaticCatalogRelations() throws Exception {
        Files.writeString(sources.resolve("Fixture.java"), """
                class Fixture { String sql = "CREATE TABLE public.goods(id uuid, name text)"; }
                """);
        var scan = FixtureSchemaDdl.scan(sources, Set.of());
        assertThat(scan.dynamicDdlFiles()).isEmpty();
        assertThat(scan.parseFailures()).isEmpty();
        assertThat(scan.tables()).hasSize(1);
        assertThat(scan.tables().getFirst().table()).isEqualTo("goods");
        assertThat(scan.tables().getFirst().columns()).containsKeys("id", "name");
    }

    @Test void anotherSchemaIsNotSilentlyMatchedAgainstPublic() throws Exception {
        Files.writeString(sources.resolve("Fixture.java"), """
                class Fixture { String sql = "CREATE TABLE shadow.goods(id uuid)"; }
                """);
        var scan = FixtureSchemaDdl.scan(sources, Set.of());
        assertThat(scan.tables()).isEmpty();
        assertThat(scan.dynamicDdlFiles()).containsExactly("Fixture.java");
    }
}
