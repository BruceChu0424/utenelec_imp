package com.uten.imp.features.clientupdates;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Map;

/** Synthetic bounded PE/ELF metadata only; these bytes cannot execute an ERP client. */
final class WindowsFlutterFixture {
    private WindowsFlutterFixture() { }
    static byte[] main(long build, String architecture, String version) {
        byte[] bytes = WindowsSetupFixture.bytes(build, architecture, version, Map.of(
                "CompanyName", "Uten", "ProductName", "优腾综合管理平台", "OriginalFileName", "uten_imp.exe", "InternalName", "uten_imp", "FileDescription", "UTEN"));
        var buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        int optional = 152, machine = NativeBinaryArchitecture.peMachine(architecture);
        buffer.putShort(132, (short)machine);
        if (machine != 0x14c) {
            buffer.putShort(148,(short)240).putShort(optional,(short)0x20b).putInt(optional+108,16);
            buffer.putInt(optional+128,4096).putInt(optional+132,4096);
            buffer.putInt(400,4096).putInt(404,4096).putInt(408,4096).putInt(412,512);
        }
        return bytes;
    }
    static byte[] engine(long build, String architecture, String version) {
        byte[] bytes=main(build,architecture,version);
        var buffer=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        buffer.putShort(150,(short)(buffer.getShort(150)|0x2000));return bytes;
    }
    static byte[] elf(String architecture) {
        byte[] bytes=new byte[64];var out=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        out.putInt(0,0x464c457f).put(4,(byte)(architecture.equals("x86")||architecture.equals("armeabi-v7a")?1:2)).put(5,(byte)1).put(6,(byte)1);
        int machine=switch(architecture){case "x86"->3;case "armeabi-v7a"->40;case "x64"->62;case "arm64"->183;default->0;};
        out.putShort(16,(short)3).putShort(18,(short)machine).putInt(20,1);
        out.putShort(bytes[4]==1?40:52,(short)(bytes[4]==1?52:64));return bytes;
    }
}
