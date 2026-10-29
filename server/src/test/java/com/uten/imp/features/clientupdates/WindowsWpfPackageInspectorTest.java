package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.UnaryOperator;
import java.io.ByteArrayOutputStream;
import java.io.ByteArrayInputStream;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;
import java.util.zip.ZipEntry;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.assertThat;

class WindowsWpfPackageInspectorTest {
    @TempDir Path directory;
    private final ClientPackageInspector inspector = new ClientPackageInspector(new ObjectMapper());
    @Test void acceptsSyntheticX86X64ClrAndWpfSetupIdentityWithoutExecutingBytes() throws Exception {
        for(String arch:List.of("x86","x64")) {
            inspector.inspect(file(WindowsWpfFixture.update(2533, arch, "2.5.33")), release(arch,"wpf_legacy","update"));
            inspector.inspect(file(WindowsWpfFixture.setup(2533,arch,"2.5.33")), release(arch,"wpf_legacy","installer"));
        }
    }
    @Test void missingRuntimeDiscriminatorAndCrossFamilyBytesAreRejected() throws Exception {
        var files = WindowsWpfFixture.files(2533,"x64","2.5.33");
        rejects(WindowsWpfFixture.zip(files,2533,"x64","2.5.33",null), release("x64","wpf_legacy","update"));
        rejects(WindowsWpfFixture.update(2533,"x64","2.5.33"),release("x64","flutter","update"));
        rejects(WindowsWpfFixture.flutterUpdate(2533,"x64"),release("x64","wpf_legacy","update"));
        rejects(WindowsSetupFixture.bytes(2533,"x64","2.5.33"),release("x64","wpf_legacy","installer"));
        rejects(WindowsWpfFixture.setup(2533,"x64","2.5.33"),release("x64","flutter","installer"));
    }
    @Test void filesMustBeCompleteManagedMatchingVersionAndArchitecture() throws Exception {
        for(String missing:WindowsWpfPackageInspector.REQUIRED) {
            var files=WindowsWpfFixture.files(2533,"x64","2.5.33"); files.remove(missing);
            rejects(WindowsWpfFixture.zip(files,2533,"x64","2.5.33","wpf_legacy"),release("x64","wpf_legacy","update"));
        }
        for(String forbidden:List.of("Uten.Legacy.Desktop.pdb","tests/keys.pfx","Web/index.html","client_updater/update.ps1")) {
            var files=WindowsWpfFixture.files(2533,"x64","2.5.33"); files.put(forbidden,new byte[]{1});
            rejects(WindowsWpfFixture.zip(files,2533,"x64","2.5.33","wpf_legacy"),release("x64","wpf_legacy","update"));
        }
        for(String image:List.of("Uten.Legacy.Desktop.exe","Uten.Legacy.Core.dll","BouncyCastle.Cryptography.dll")) {
            var files=WindowsWpfFixture.files(2533,"x64","2.5.33");
            var bytes=files.get(image); ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).putInt(3312+16,0);
            rejects(WindowsWpfFixture.zip(files,2533,"x64","2.5.33","wpf_legacy"),release("x64","wpf_legacy","update"));
        }
        var wrongVersion=WindowsWpfFixture.files(2533,"x64","2.5.33");
        wrongVersion.put("Uten.Legacy.Core.dll",WindowsWpfFixture.image(2532,"x64","2.5.33",true));
        rejects(WindowsWpfFixture.zip(wrongVersion,2533,"x64","2.5.33","wpf_legacy"),release("x64","wpf_legacy","update"));
        var wrongArch=WindowsWpfFixture.files(2533,"x64","2.5.33");
        wrongArch.put("Uten.Legacy.Desktop.exe",WindowsWpfFixture.image(2533,"x86","2.5.33",false));
        rejects(WindowsWpfFixture.zip(wrongArch,2533,"x64","2.5.33","wpf_legacy"),release("x64","wpf_legacy","update"));
    }
    @Test void rejectsUnconfiguredInsecureLoopbackOrDtdEnabledRuntime() throws Exception {
        for(String address:List.of("http://imp.utenelec/api","https://localhost/api","https://localhost./api","https://127.0.0.1/api",
                "https://[::1]/api","https://[::ffff:127.0.0.1]/api","https://0/api","https://2130706433/api",
                "https://0x7f000001/api","https://0x7f.0.0.1/api","https://0177.0.0.1/api","https://imp.utenelec/api?x=1")) {
            var files=WindowsWpfFixture.files(2533,"x64","2.5.33");
            files.put("uten.client.json",("{\"endpoints\":[{\"id\":\"company\",\"name\":\"company\",\"apiBaseUrl\":\""+address+"\"}],\"selectedEndpointId\":\"company\"}").getBytes(StandardCharsets.UTF_8));
            rejects(WindowsWpfFixture.zip(files,2533,"x64","2.5.33","wpf_legacy"),release("x64","wpf_legacy","update"));
        }
        var withSecret=WindowsWpfFixture.files(2533,"x64","2.5.33");
        withSecret.put("uten.client.json",("{\"endpoints\":[{\"id\":\"company\",\"name\":\"company\",\"apiBaseUrl\":\"https://imp.utenelec/api\",\"password\":\"must-not-be-bundled\"}],\"selectedEndpointId\":\"company\"}").getBytes(StandardCharsets.UTF_8));
        rejects(WindowsWpfFixture.zip(withSecret,2533,"x64","2.5.33","wpf_legacy"),release("x64","wpf_legacy","update"));
        for(String runtime:List.of("<configuration><startup><supportedRuntime version=\"v4.0\" sku=\".NETCoreApp,Version=v8.0\"/></startup></configuration>",
                "<!DOCTYPE configuration [<!ENTITY external SYSTEM 'file:///definitely-not-read'>]><configuration>&external;</configuration>")) {
            var files=WindowsWpfFixture.files(2533,"x64","2.5.33"); files.put("Uten.Legacy.Desktop.exe.config",runtime.getBytes(StandardCharsets.UTF_8));
            rejects(WindowsWpfFixture.zip(files,2533,"x64","2.5.33","wpf_legacy"),release("x64","wpf_legacy","update"));
        }
    }
    @Test void rejectsDebugLocalTestUnreviewedAndMissingCompanyReleaseProvenance() throws Exception {
        for (String marker : List.of("", "UTEN WPF candidate; Configuration=Debug; Distribution=Company",
                "UTEN WPF candidate; Configuration=Release; Distribution=LocalTest",
                "UTEN WPF candidate; Configuration=Release; Distribution=Unreviewed",
                WindowsWpfFixture.COMPANY_RELEASE_PROVENANCE + " ")) {
            for (String name : List.of("Uten.Legacy.Desktop.exe", "Uten.Legacy.Core.dll")) {
                var files = WindowsWpfFixture.files(2533,"x64","2.5.33");
                files.put(name,WindowsWpfFixture.image(2533,"x64","2.5.33",name.endsWith(".dll"),marker));
                rejects(WindowsWpfFixture.zip(files,2533,"x64","2.5.33","wpf_legacy"),release("x64","wpf_legacy","update"));
            }
        }
    }
    @Test void exactSharedManifestShapeSizeAndExplicitUpdateKindAreRequired() throws Exception {
        byte[] original = WindowsWpfFixture.update(2533, "x64", "2.5.33");
        for (UnaryOperator<String> mutation : List.<UnaryOperator<String>>of(
                json -> json.replace("\"packageKind\":\"update\",", ""),
                json -> json.replace("\"packageKind\":\"update\"", "\"packageKind\":null"),
                json -> json.replace("\"schemaVersion\":1", "\"schemaVersion\":1,\"schemaVersion\":1"),
                json -> json.replace("\"schemaVersion\":1", "\"schemaVersion\":4294967297"),
                json -> json.replace("\"schemaVersion\":1", "\"schemaVersion\":1,\"unexpected\":true"),
                json -> json.replace("\"files\":[{", "\"files\":[{\"unexpected\":true,"),
                json -> json + "{}",
                json -> json + " ".repeat(WpfPackageContract.MAXIMUM_MANIFEST_BYTES))) {
            rejects(rewriteManifest(original, mutation), release("x64", "wpf_legacy", "update"));
        }
        var ico = WindowsWpfFixture.files(2533, "x64", "2.5.33"); ico.put("uten-wpf.ico", new byte[]{1});
        rejects(WindowsWpfFixture.zip(ico,2533,"x64","2.5.33","wpf_legacy"), release("x64","wpf_legacy","update"));
    }
    @Test void dependencyPinsProductVersionAndDuplicateConfigurationAreEnforced() throws Exception {
        for (String name : List.of("BouncyCastle.Cryptography.dll", "BouncyCastle-LICENSE.md")) {
            var files = WindowsWpfFixture.files(2533,"x64","2.5.33");
            byte[] bytes = files.get(name).clone(); bytes[bytes.length-1] ^= 1; files.put(name, bytes);
            rejects(WindowsWpfFixture.zip(files,2533,"x64","2.5.33","wpf_legacy"), release("x64","wpf_legacy","update"));
        }
        var wrongProduct = WindowsWpfFixture.files(2533,"x64","2.5.33");
        ByteBuffer.wrap(wrongProduct.get("Uten.Legacy.Core.dll")).order(ByteOrder.LITTLE_ENDIAN).putInt(668, 1);
        rejects(WindowsWpfFixture.zip(wrongProduct,2533,"x64","2.5.33","wpf_legacy"), release("x64","wpf_legacy","update"));
        var duplicate = WindowsWpfFixture.files(2533,"x64","2.5.33");
        String config = new String(duplicate.get("uten.client.json"), StandardCharsets.UTF_8);
        duplicate.put("uten.client.json", config.replace("\"selectedEndpointId\":\"company\"",
                "\"selectedEndpointId\":\"company\",\"selectedEndpointId\":\"company\"").getBytes(StandardCharsets.UTF_8));
        rejects(WindowsWpfFixture.zip(duplicate,2533,"x64","2.5.33","wpf_legacy"), release("x64","wpf_legacy","update"));
        byte[] x86Library = WindowsWpfFixture.image(1,"x86","2.7.0",true);
        ByteBuffer.wrap(x86Library).order(ByteOrder.LITTLE_ENDIAN).putInt(3312+16,3);
        assertThatThrownBy(() -> WindowsManagedImageInspector.inspect(x86Library, release("x86","wpf_legacy","update"),true,false,true))
                .isInstanceOf(ApiException.class);
    }
    @Test void centralDirectoryAllocationIsBoundedBeforeCommonsZipFile() throws Exception {
        byte[] original = WindowsWpfFixture.update(2533,"x64","2.5.33");
        for (int field : List.of(4, 8, 10, 12)) {
            byte[] bytes = original.clone(); int end = bytes.length - 22;
            var view = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
            if (field == 12) view.putInt(end + field, WpfPackageContract.MAXIMUM_CENTRAL_DIRECTORY_BYTES + 1);
            else view.putShort(end + field, (short) (field == 4 ? 1 : 65535));
            Path path = file(bytes);
            assertThatThrownBy(() -> WindowsWpfPackageInspector.requireDirectory(path)).isInstanceOf(ApiException.class);
        }
    }
    private static byte[] rewriteManifest(byte[] source, UnaryOperator<String> mutation) throws Exception {
        var result = new ByteArrayOutputStream();
        try (var input = new ZipInputStream(new ByteArrayInputStream(source)); var output = new ZipOutputStream(result)) {
            for (ZipEntry entry; (entry = input.getNextEntry()) != null;) {
                byte[] bytes = input.readAllBytes();
                if ("uten-client-manifest.json".equals(entry.getName()))
                    bytes = mutation.apply(new String(bytes,StandardCharsets.UTF_8)).getBytes(StandardCharsets.UTF_8);
                output.putNextEntry(new ZipEntry(entry.getName())); output.write(bytes); output.closeEntry();
            }
        }
        return result.toByteArray();
    }
    private ClientReleaseDto.Release release(String arch,String family,String kind) {
        return new ClientReleaseDto.Release(UUID.randomUUID(),"windows",arch,"2.5.33",2533,"",false,
                "installer".equals(kind)?"setup.exe":"update.zip",null,null,0,
                "installer".equals(kind)?ClientRuntimeFamily.setupMode(family):ClientRuntimeFamily.archiveMode(family),null,null,"DRAFT",Instant.now(),null,kind,family);
    }
    private Path file(byte[] bytes)throws Exception{return Files.write(directory.resolve(UUID.randomUUID()+".fixture"),bytes);}
    private void rejects(byte[] bytes,ClientReleaseDto.Release release)throws Exception {
        assertThatThrownBy(()->inspector.inspect(file(bytes),release)).isInstanceOfSatisfying(ApiException.class,
                error->assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
    }
}
