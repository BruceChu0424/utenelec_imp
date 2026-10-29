using System;
using System.IO;

namespace Uten.Legacy.Updater
{
    internal static class ZipDirectory
    {
        // Standard EOCD (22 bytes) + the ZIP format's bounded 16-bit comment.
        // WPF's six small files never need ZIP64. Do not materialize archive
        // entries until count and directory byte allocation are bounded.
        internal static void Require(Stream file)
        {
            int count = (int)Math.Min(file.Length, 22 + UInt16.MaxValue);
            var tail = new byte[count];
            file.Position = file.Length - count;
            int received = 0;
            while (received < count)
            {
                int read = file.Read(tail, received, count - received);
                if (read == 0) throw new InvalidDataException("Truncated ZIP directory.");
                received += read;
            }
            int position = -1;
            for (int index = count - 4; index >= 0; index--)
                if (BitConverter.ToUInt32(tail, index) == 0x06054b50) { position = index; break; }
            if (position < 0 || position > count - 22) throw new InvalidDataException("Missing bounded WPF ZIP directory.");
            int expected = PackageContract.Files.Length + 1;
            uint length = BitConverter.ToUInt32(tail, position + 12), offset = BitConverter.ToUInt32(tail, position + 16);
            long absolute = file.Length - count + position;
            if (BitConverter.ToUInt16(tail, position + 4) != 0 || BitConverter.ToUInt16(tail, position + 6) != 0
                || BitConverter.ToUInt16(tail, position + 8) != expected || BitConverter.ToUInt16(tail, position + 10) != expected
                || length < expected * 46 || length > PackageContract.MaximumCentralDirectoryBytes
                || (long)offset + length != absolute || position + 22 + BitConverter.ToUInt16(tail, position + 20) != count)
                throw new InvalidDataException("WPF ZIP must have one bounded seven-entry non-ZIP64 directory.");
            file.Position = 0;
        }
    }
}
