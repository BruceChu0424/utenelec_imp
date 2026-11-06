package com.uten.imp.migration;

import java.nio.file.Path;
import java.nio.file.Files;
import java.util.Comparator;
import java.util.List;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/** Only invokes the coordinator's filename parser; its bootstrap is never run. */
class LegacyBootstrapFlywayVersionTest {
    private static MigrationVersion version(String filename) throws Exception {
        var method=LegacyBootstrapCoordinatorPostgresTest.class.getDeclaredMethod("version",Path.class);
        method.setAccessible(true);
        return (MigrationVersion)method.invoke(null,Path.of(filename));
    }

    @Test void actualCoordinatorSortKeepsEveryDottedResourceInFlywayOrder() throws Exception {
        var files=List.of("V1000__next.sql","V999_11__eleventh.sql","V999_2__second.sql",
                "V999_1__first.sql","V999__base.sql");
        var actual=files.stream().sorted(Comparator.comparing(filename->{
            try{return version(filename);}catch(Exception error){throw new AssertionError(error);}
        })).toList();
        assertEquals(List.of("V999__base.sql","V999_1__first.sql","V999_2__second.sql",
                "V999_11__eleventh.sql","V1000__next.sql"),actual);
        assertEquals("999.11",version("V999_11__eleventh.sql").getVersion());
    }

    @Test void largeComponentsAndOrdinaryIntegerIdentityRemainCompatible() throws Exception {
        assertTrue(version("V3000000000_1__large.sql").compareTo(version("V3000000000__base.sql"))>0);
        assertEquals("306",version("V306__ordinary.sql").getVersion());
        assertEquals("1",version("V01__enable_pgcrypto.sql").getVersion());
        assertEquals(MigrationVersion.fromVersion("999.1"),version("V999_1__first.sql"));
    }

    @Test void catalogCountsEveryComponentAndKeepsAnActualDottedHead(@TempDir Path directory) throws Exception {
        for (String filename:List.of("V999__base.sql","V999_1__first.sql","V999_2_1__third_part.sql",
                "V999_10__tenth.sql","V999_11__eleventh.sql")) {
            Files.writeString(directory.resolve(filename),"-- synthetic filename metadata only\n");
        }
        var catalog=MigrationRehearsalSupport.readMigrationCatalog(directory);
        assertEquals(5,catalog.versions().size());
        assertEquals("999.11",catalog.headVersion());
        assertEquals(1,catalog.countUpTo(MigrationVersion.fromVersion("999")));
        assertEquals(2,catalog.countUpTo(MigrationVersion.fromVersion("999.2")));
        assertEquals(5,catalog.countUpTo(MigrationVersion.fromVersion("1000")));
    }

    @Test void catalogHeadAndIntegerBoundDoNotTruncateLargeOrThreePartVersions(@TempDir Path directory) throws Exception {
        String major="20261105123456789012345678901234567890";
        Files.writeString(directory.resolve("V"+major+"__major.sql"),"-- metadata\n");
        Files.writeString(directory.resolve("V"+major+"_0_1__third_part.sql"),"-- metadata\n");
        var catalog=MigrationRehearsalSupport.readMigrationCatalog(directory);
        assertEquals(major+".0.1",catalog.headVersion());
        assertEquals(0,catalog.countUpTo(MigrationVersion.fromVersion(Integer.toString(Integer.MAX_VALUE))));
        assertEquals(1,catalog.countUpTo(MigrationVersion.fromVersion(major)));
    }
}
