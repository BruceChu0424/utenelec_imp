package com.uten.imp.features.clientupdates;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Bounded AXML/DEX/ELF metadata fixtures, not runnable or signed mobile applications. */
final class AndroidPackageFixture {
    private AndroidPackageFixture() { }
    static byte[] apk(long build,String version,String architecture,String fault) throws Exception {
        var files=new LinkedHashMap<String,byte[]>();files.put("AndroidManifest.xml",manifest(build,version,fault));
        byte[] dex=new byte[112];var out=ByteBuffer.wrap(dex).order(ByteOrder.LITTLE_ENDIAN);
        System.arraycopy("dex\n039\0".getBytes(StandardCharsets.US_ASCII),0,dex,0,8);out.putInt(32,112).putInt(36,112).putInt(40,0x12345678);files.put("classes.dex",dex);
        var abis="universal".equals(architecture)?Set.of("armeabi-v7a","arm64-v8a","x86_64"):Set.of(switch(architecture){case "arm64"->"arm64-v8a";case "x64"->"x86_64";default->"armeabi-v7a";});
        for(String abi:abis){String target=abi.equals("arm64-v8a")?"arm64":abi.equals("x86_64")?"x64":"armeabi-v7a";
            byte[] elf=WindowsFlutterFixture.elf("wrong-elf".equals(fault)?"x64":target);
            files.put("lib/"+abi+"/libflutter.so",elf);if(!"missing-aot".equals(fault))files.put("lib/"+abi+"/libapp.so",elf);}
        return ClientReleaseFixtures.zip(files);
    }
    static byte[] manifest(long build,String version,String fault) {
        List<String> strings=List.of("versionCode","versionName","versionCodeMajor","debuggable","testOnly","package",
                "http://schemas.android.com/apk/res/android","manifest","application","wrong-package".equals(fault)?"other.application":"com.uten.uten_imp",version);
        var chunks=new ArrayList<byte[]>();chunks.add(pool(strings,"utf16".equals(fault)));
        var map=ByteBuffer.allocate(28).order(ByteOrder.LITTLE_ENDIAN);map.putShort((short)0x180).putShort((short)8).putInt(28)
            .putInt("wrong-resource-map".equals(fault)?0:0x0101021b).putInt(0x0101021c).putInt(0x01010576).putInt(0x0101000f).putInt(0x01010272);chunks.add(map.array());
        var attributes=new ArrayList<byte[]>();attributes.add(attribute(-1,5,9,3,9));attributes.add(attribute(6,0,-1,0x10,(int)build));
        attributes.add(attribute(6,1,"resource-version".equals(fault)?-1:10,"resource-version".equals(fault)?1:3,"resource-version".equals(fault)?0x7f010001:10));
        if("duplicate-version".equals(fault))attributes.add(attribute(6,0,-1,0x10,(int)build));
        if("major-version".equals(fault))attributes.add(attribute(6,2,-1,0x10,1));
        chunks.add(start(7,attributes));chunks.add(start(8,List.of(attribute(6,3,-1,0x12,"debug".equals(fault)?1:0))));chunks.add(end(8));chunks.add(end(7));
        int size=8+chunks.stream().mapToInt(value->value.length).sum();var result=ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        result.putShort((short)3).putShort((short)8).putInt(size);chunks.forEach(result::put);byte[] bytes=result.array();
        if("truncated".equals(fault))return java.util.Arrays.copyOf(bytes,bytes.length-1);return bytes;
    }
    private static byte[] pool(List<String> strings,boolean utf16) {
        var data=new ByteArrayOutputStream();var offsets=new ArrayList<Integer>();
        for(String value:strings){offsets.add(data.size());byte[] bytes=value.getBytes(utf16?StandardCharsets.UTF_16LE:StandardCharsets.UTF_8);
            if(utf16){data.write(value.length()&255);data.write(value.length()>>>8);}else{length(data,value.length());length(data,bytes.length);}data.writeBytes(bytes);data.write(0);if(utf16)data.write(0);}
        while((data.size()&3)!=0)data.write(0);int start=28+strings.size()*4;var result=ByteBuffer.allocate(start+data.size()).order(ByteOrder.LITTLE_ENDIAN);
        result.putShort((short)1).putShort((short)28).putInt(result.capacity()).putInt(strings.size()).putInt(0).putInt(utf16?0:256).putInt(start).putInt(0);
        offsets.forEach(result::putInt);result.put(data.toByteArray());return result.array();
    }
    private static void length(ByteArrayOutputStream out,int value){if(value>127)out.write(0x80|(value>>>8));out.write(value&255);}
    private static byte[] attribute(int ns,int name,int raw,int type,int value){return ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN).putInt(ns).putInt(name).putInt(raw).putShort((short)8).put((byte)0).put((byte)type).putInt(value).array();}
    private static byte[] start(int name,List<byte[]> attributes){var out=ByteBuffer.allocate(36+attributes.size()*20).order(ByteOrder.LITTLE_ENDIAN);out.putShort((short)0x102).putShort((short)16).putInt(out.capacity()).putInt(1).putInt(-1)
            .putInt(-1).putInt(name).putShort((short)20).putShort((short)20).putShort((short)attributes.size()).putShort((short)0).putShort((short)0).putShort((short)0);attributes.forEach(out::put);return out.array();}
    private static byte[] end(int name){return ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN).putShort((short)0x103).putShort((short)16).putInt(24).putInt(1).putInt(-1).putInt(-1).putInt(name).array();}
}
