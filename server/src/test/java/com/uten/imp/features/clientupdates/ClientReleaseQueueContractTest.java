package com.uten.imp.features.clientupdates;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ClientReleaseQueueContractTest {
    @TempDir Path directory;
    final ObjectMapper mapper=new ObjectMapper().findAndRegisterModules();
    final ClientUpdateProperties properties=new ClientUpdateProperties();
    final SecurityContextCurrentUser users=mock();
    final AuthUser publisher=mock();
    ClientReleaseCatalog catalog;ClientReleaseService service;
    @BeforeEach void setup(){properties.setDirectory(directory.toString());when(publisher.getId()).thenReturn(UUID.randomUUID());when(publisher.getLoginAccount()).thenReturn("fixture");
        when(publisher.getPermissions()).thenReturn(Set.of(ClientReleaseService.PUBLISH_PERMISSION));when(publisher.getEmployeeId()).thenReturn(UUID.randomUUID());when(users.get()).thenReturn(java.util.Optional.of(publisher));
        catalog=new ClientReleaseCatalog(properties,new StorageProperties(),mapper);service=new ClientReleaseService(catalog,new ClientPackageInspector(mapper),properties,users,mock(AuditService.class));}
    @Test void pairedGenerationsHideHalfGroupsAndKeepThePriorCompleteGroup() throws Exception {
        var first=pair(10,"x64");var update=upload(20,"x64","update");service.publish(update.id());
        assertThat(service.check("windows","x64",1).release().id()).isEqualTo(first.get(1).id());
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(first.getFirst().id());
        assertCode(()->service.download(update.id()),ErrorCode.NOT_FOUND);
        var setup=upload(20,"x64","installer");service.publish(setup.id());
        assertThat(service.check("windows","x64",1).release().id()).isEqualTo(update.id());
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(setup.id());
        assertThat(service.get(update.id()).deliveryContract()).isEqualTo("paired_v1");
        var same=service.publish(update.id());assertThat(same.publishedAt()).isEqualTo(service.get(update.id()).publishedAt());
    }
    @Test void wrongVersionArchOrMissingPairNeverBecomesDownloadable() throws Exception {
        var old=pair(10,"x64");var setup=upload(20,"x64","installer");service.publish(setup.id());
        var differentArch=upload(20,"arm64","update");service.publish(differentArch.id());
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(old.getFirst().id());
        assertThat(service.check("windows","x64",1).release().id()).isEqualTo(old.get(1).id());
        var bytes=ClientReleaseFixtures.windows(mapper,21,"arm64","2.5.21");var wrong=service.create(request(UUID.randomUUID(),21,"x64","update",bytes));
        assertCode(()->service.upload(wrong.id(),new ByteArrayInputStream(bytes),bytes.length),ErrorCode.VALIDATION_FAILED);
        assertThat(service.get(wrong.id()).sha256()).isNull();
    }
    @Test void withdrawingAHalfNewGroupHidesOnlyThatContractAndKeepsOtherArchitecture() throws Exception {
        var x64=pair(10,"x64");var arm=pair(10,"arm64");
        service.withdraw(x64.getFirst().id());
        assertThat(service.check("windows","x64",1).updateAvailable()).isFalse();
        assertThat(service.check("windows","arm64",1).release().id()).isEqualTo(arm.get(1).id());
        assertCode(()->service.download(x64.get(1).id()),ErrorCode.NOT_FOUND);
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(arm.getFirst().id());
    }
    @Test void originalRequestIdRecoversEachStageAndRejectsDifferentBytesWithoutDuplicatingSuccess() throws Exception {
        byte[] bytes=ClientReleaseFixtures.windows(mapper,30,"x64","2.5.30");var request=request(UUID.randomUUID(),30,"x64","update",bytes);
        var first=service.create(request);assertThat(service.create(request)).isEqualTo(first);
        service.upload(first.id(),new ByteArrayInputStream(bytes),bytes.length);var uploaded=service.get(first.id());
        assertThat(uploaded.state()).isEqualTo("DRAFT");assertThat(uploaded.sha256()).isEqualTo(ClientReleaseFixtures.sha(bytes));assertThat(uploaded.sizeBytes()).isEqualTo(bytes.length);
        service.publish(first.id());var acknowledged=service.get(first.id());
        assertThat(service.create(request)).isEqualTo(acknowledged);assertThat(service.publish(first.id()).publishedAt()).isEqualTo(acknowledged.publishedAt());
        assertCode(()->service.upload(first.id(),new ByteArrayInputStream(bytes),bytes.length),ErrorCode.CONFLICT);
        var changed=new ClientReleaseDto.Create(first.id(),"windows","x64","2.5.30",30,"different",false,"update.zip",ClientReleaseFixtures.sha(bytes),null);
        assertCode(()->service.create(changed),ErrorCode.CONFLICT);
    }
    @Test void legacyMissingExpectedShaKeepsPriorReaderBehaviorAndReadDoesNotRewriteMetadata() throws Exception {
        byte[] bytes="legacy binary".getBytes(java.nio.charset.StandardCharsets.UTF_8);UUID id=UUID.randomUUID();
        var legacy=new ClientReleaseDto.Release(id,"windows","x64","2.5.1",1,"",false,"old.exe",null,"legacy-hash",bytes.length,"windows_setup",null,
                "/api/client-updates/"+id+"/download","PUBLISHED",Instant.now(),Instant.now(),"installer");
        catalog.locked(root->{catalog.write(root,legacy);Files.write(root.resolve(id.toString()).resolve("package.bin"),bytes);return null;});
        Path file=directory.resolve(id.toString()).resolve("release.json");byte[] before=Files.readAllBytes(file);
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(id);
        assertThat(service.get(id).deliveryContract()).isNull();assertThat(before).isEqualTo(Files.readAllBytes(file));assertThat(mapper.readTree(before).has("deliveryContract")).isFalse();
    }
    @Test void newInstallerZipIsRejectedWhileSameLegacyIdStillRecovers() throws Exception {
        byte[] bytes={1};var request=new ClientReleaseDto.Create(UUID.randomUUID(),"windows","x64","2.5.1",1,"",false,"legacy.zip",ClientReleaseFixtures.sha(bytes),null,"installer");
        assertCode(()->service.create(request),ErrorCode.VALIDATION_FAILED);
        var legacy=ClientReleaseFixtures.legacyDraft(properties,mapper,request,"windows_bundle");
        assertThat(service.create(request)).isEqualTo(legacy);assertThat(service.get(request.requestId()).deliveryContract()).isNull();
    }
    @Test void androidAuditedPayloadVersionAndRealAbiAreAuthoritativeAndOldContractIsUnchanged() throws Exception {
        for(String architecture:List.of("arm64","armeabi-v7a","x64","universal")) {
            byte[] bytes=AndroidPackageFixture.apk(40,"2.5.40",architecture,null);var release=service.create(apkRequest(40,architecture,bytes));
            assertThat(release.deliveryContract()).isEqualTo("audited_v1");service.upload(release.id(),new ByteArrayInputStream(bytes),bytes.length);
        }
        byte[] legacy=ClientReleaseFixtures.zip(java.util.Map.of("AndroidManifest.xml",new byte[]{1},"classes.dex",new byte[]{2}));
        var old=ClientReleaseFixtures.legacyDraft(properties,mapper,apkRequest(41,"arm64",legacy),"android_package");
        assertThat(service.upload(old.id(),new ByteArrayInputStream(legacy),legacy.length).deliveryContract()).isNull();
        byte[] bad=AndroidPackageFixture.apk(42,"2.5.42","arm64",null);var wrong=service.create(apkRequest(43,"x64",bad));
        assertCode(()->service.upload(wrong.id(),new ByteArrayInputStream(bad),bad.length),ErrorCode.VALIDATION_FAILED);
    }
    @Test void androidMalformedDebugReferencedOrIncompletePackagesCannotPassAuditedUpload() throws Exception {
        for(String fault:List.of("debug","resource-version","wrong-resource-map","major-version","duplicate-version","truncated","missing-aot","wrong-elf","wrong-package")) {
            byte[] bytes=AndroidPackageFixture.apk(50,"2.5.50","arm64",fault);var release=service.create(apkRequest(50,"arm64",bytes));
            assertCode(()->service.upload(release.id(),new ByteArrayInputStream(bytes),bytes.length),ErrorCode.VALIDATION_FAILED);
            assertThat(service.get(release.id()).sha256()).isNull();
        }
        byte[] utf16=AndroidPackageFixture.apk(51,"2.5.51","arm64","utf16");var release=service.create(apkRequest(51,"arm64",utf16));
        assertThat(service.upload(release.id(),new ByteArrayInputStream(utf16),utf16.length).sha256()).isNotNull();
    }
    @Test void optInDownloadsIncludesAuditedApkAndOnlyTrustedStoreLinks() throws Exception {
        var windows=pair(60,"x64");byte[] apk=AndroidPackageFixture.apk(60,"2.5.60","arm64",null);
        var mobile=service.create(apkRequest(60,"arm64",apk));service.upload(mobile.id(),new ByteArrayInputStream(apk),apk.length);service.publish(mobile.id());
        var apple=service.create(new ClientReleaseDto.Create(UUID.randomUUID(),"ios","universal","2.5.60",60,"",false,null,null,"https://apps.apple.com/app/id123456"));service.publish(apple.id());
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(windows.getFirst().id());
        assertThat(service.downloads("flutter",true,true)).extracting(ClientReleaseDto.Release::id).containsExactlyInAnyOrder(windows.getFirst().id(),mobile.id(),apple.id());
    }
    @Test void newPairedSetupCannotBorrowALegacyUpdateToRetireThePriorGeneration() throws Exception {
        var old=pair(10,"x64");
        byte[] bytes=ClientReleaseFixtures.windows(mapper,20,"x64","2.5.20");
        var legacy=ClientReleaseFixtures.legacyDraft(properties,mapper,request(UUID.randomUUID(),20,"x64","update",bytes),"windows_archive");
        service.upload(legacy.id(),new ByteArrayInputStream(bytes),bytes.length);service.publish(legacy.id());
        var setup=upload(20,"x64","installer");service.publish(setup.id());
        for(var release:old) assertThat(directory.resolve(release.id().toString()).resolve("package.bin")).isRegularFile();
        assertCode(()->service.download(setup.id()),ErrorCode.NOT_FOUND);
        assertThat(service.downloads()).extracting(ClientReleaseDto.Release::id).containsExactly(old.getFirst().id());
    }
    @Test void actualProgramVersionAndCounterpartVersionCannotBeOverriddenByManifestOrQueueLabels() throws Exception {
        byte[] bytes=ClientReleaseFixtures.windows(mapper,21,"x64","2.5.21");
        var original=new java.util.LinkedHashMap<String,byte[]>();
        try(var zip=new java.util.zip.ZipInputStream(new ByteArrayInputStream(bytes))){for(java.util.zip.ZipEntry entry;(entry=zip.getNextEntry())!=null;) original.put(entry.getName(),zip.readAllBytes());}
        var manifest=(com.fasterxml.jackson.databind.node.ObjectNode)mapper.readTree(original.get("uten-client-manifest.json"));manifest.put("version","2.5.22");
        original.put("uten-client-manifest.json",mapper.writeValueAsBytes(manifest));byte[] forged=ClientReleaseFixtures.zip(original);
        var wrong=service.create(new ClientReleaseDto.Create(UUID.randomUUID(),"windows","x64","2.5.22",21,"",false,"update.zip",ClientReleaseFixtures.sha(forged),null));
        assertCode(()->service.upload(wrong.id(),new ByteArrayInputStream(forged),forged.length),ErrorCode.VALIDATION_FAILED);
        var setup=upload(30,"x64","installer");service.publish(setup.id());
        byte[] mismatched=ClientReleaseFixtures.windows(mapper,30,"x64","2.5.31");
        var different=service.create(new ClientReleaseDto.Create(UUID.randomUUID(),"windows","x64","2.5.31",30,"",false,"update.zip",ClientReleaseFixtures.sha(mismatched),null));
        service.upload(different.id(),new ByteArrayInputStream(mismatched),mismatched.length);
        assertCode(()->service.publish(different.id()),ErrorCode.CONFLICT);assertThat(service.get(different.id()).state()).isEqualTo("DRAFT");
    }
    @Test void auditedAndroidWithMissingBoundFileIsNotRecommendedAndMalformedContractsPreserveBytes() throws Exception {
        byte[] bytes=AndroidPackageFixture.apk(70,"2.5.70","arm64",null);var release=service.create(apkRequest(70,"arm64",bytes));
        service.upload(release.id(),new ByteArrayInputStream(bytes),bytes.length);service.publish(release.id());
        assertThat(service.check("android","arm64",1).release().id()).isEqualTo(release.id());
        Files.delete(directory.resolve(release.id().toString()).resolve("package.bin"));
        assertThat(service.check("android","arm64",1).updateAvailable()).isFalse();
        Path file=directory.resolve(release.id().toString()).resolve("release.json");
        var malformed=(com.fasterxml.jackson.databind.node.ObjectNode)mapper.readTree(file.toFile());malformed.put("deliveryContract","paired_v1");
        byte[] bad=mapper.writeValueAsBytes(malformed);Files.write(file,bad);
        assertCode(()->service.get(release.id()),ErrorCode.PRIMARY_UNAVAILABLE);assertThat(Files.readAllBytes(file)).isEqualTo(bad);
    }
    List<ClientReleaseDto.Release> pair(int build,String arch)throws Exception{var setup=upload(build,arch,"installer");service.publish(setup.id());var zip=upload(build,arch,"update");service.publish(zip.id());return List.of(service.get(setup.id()),service.get(zip.id()));}
    ClientReleaseDto.Release upload(int build,String arch,String kind)throws Exception{byte[]bytes="installer".equals(kind)?WindowsSetupFixture.bytes(build,arch,"2.5."+build):ClientReleaseFixtures.windows(mapper,build,arch,"2.5."+build);var draft=service.create(request(UUID.randomUUID(),build,arch,kind,bytes));return service.upload(draft.id(),new ByteArrayInputStream(bytes),bytes.length);}
    ClientReleaseDto.Create request(UUID id,int build,String arch,String kind,byte[]bytes){return new ClientReleaseDto.Create(id,"windows",arch,"2.5."+build,build,"",false,"installer".equals(kind)?"Setup.exe":"update.zip",ClientReleaseFixtures.sha(bytes),null,kind);}
    ClientReleaseDto.Create apkRequest(int build,String arch,byte[]bytes){return new ClientReleaseDto.Create(UUID.randomUUID(),"android",arch,"2.5."+build,build,"",false,"mobile.apk",ClientReleaseFixtures.sha(bytes),null);}
    static void assertCode(Runnable call,ErrorCode expected){assertThatThrownBy(call::run).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(expected));}
}
