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
