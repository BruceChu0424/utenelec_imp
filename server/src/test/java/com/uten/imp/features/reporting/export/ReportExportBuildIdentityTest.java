package com.uten.imp.features.reporting.export;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
class ReportExportBuildIdentityTest {
    @org.junit.jupiter.api.io.TempDir java.nio.file.Path directory;
    @Test void theActualRuntimeResourceSetHasOneStableCredentialFreeFingerprint() {
        var identity=new ReportExportBuildIdentity();
        String first=identity.revision();
        assertTrue(first.matches("[0-9a-f]{64}"));
        assertEquals(first,identity.revision());
        assertEquals(first,new ReportExportBuildIdentity().revision());
    }
    @Test void sqlResourcesAloneCannotMasqueradeAsAnApplicationBuild() throws Exception {
        var rules=java.nio.file.Files.createDirectories(directory.resolve("sql-only/db/migration"));
        java.nio.file.Files.writeString(rules.resolve("V1__fixture.sql"),"SELECT 1;");
        try(var loader=new java.net.URLClassLoader(new java.net.URL[]{directory.resolve("sql-only").toUri().toURL()},null)) {
            assertThrows(IllegalStateException.class,() -> new ReportExportBuildIdentity(loader).revision());
        }
    }
    @Test void duplicateResourcesFollowTheActualLoaderSelectionAndAChangedSelectionChangesTheStamp() throws Exception {
        var first=java.nio.file.Files.createDirectories(directory.resolve("first/com/uten/imp"));
        var second=java.nio.file.Files.createDirectories(directory.resolve("second/com/uten/imp"));
        java.nio.file.Files.write(first.resolve("Version.class"),new byte[]{1,2,3});
        java.nio.file.Files.write(second.resolve("Version.class"),new byte[]{4,5,6});
        var a=directory.resolve("first").toUri().toURL();var b=directory.resolve("second").toUri().toURL();
        try(var loaderA=new java.net.URLClassLoader(new java.net.URL[]{a,b},null);
            var loaderB=new java.net.URLClassLoader(new java.net.URL[]{b,a},null)) {
            String expected=new ReportExportBuildIdentity(loaderA).revision();
            assertEquals(expected,new ReportExportBuildIdentity(loaderA).revision());
            assertNotEquals(expected,new ReportExportBuildIdentity(loaderB).revision());
        }
    }
}
