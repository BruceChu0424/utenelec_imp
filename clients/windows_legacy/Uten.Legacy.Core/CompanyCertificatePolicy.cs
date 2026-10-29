using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;

namespace Uten.Legacy.Core
{
    /// <summary>Loads the fixed company CA; all connection validation lives in ManagedCertificateValidator.</summary>
    internal sealed class CompanyCertificatePolicy
    {
        internal const string BundledPemSha256 = "e8479fe7113e0efd5d877cb5a35611454d8fd641728fedd8840e1501deb23763";
        private readonly byte[] rootBytes;
        internal byte[] RootDer { get { return (byte[])rootBytes.Clone(); } }

        // Only same-assembly contract tests construct a separate test-owned policy.
        internal CompanyCertificatePolicy(byte[] rootDer)
        {
            using (var root = new X509Certificate2(rootDer))
            {
                var constraints = root.Extensions.OfType<X509BasicConstraintsExtension>().FirstOrDefault();
                var usage = root.Extensions.OfType<X509KeyUsageExtension>().FirstOrDefault();
                if (constraints == null || !constraints.CertificateAuthority
                    || (usage != null && (usage.KeyUsages & X509KeyUsageFlags.KeyCertSign) == 0))
                    throw new InvalidDataException("公司根证书无效。");
                rootBytes = root.RawData;
            }
        }

        internal static CompanyCertificatePolicy FromEmbeddedCertificate()
        {
            byte[] pem;
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Uten.Legacy.Core.uten-imp-root-ca.crt"))
            {
                if (stream == null || stream.Length > 16384) throw new InvalidDataException("公司根证书缺失。");
                using (var buffer = new MemoryStream()) { stream.CopyTo(buffer); pem = buffer.ToArray(); }
            }
            string digest;
            using (var sha = SHA256.Create()) digest = BitConverter.ToString(sha.ComputeHash(pem)).Replace("-", "").ToLowerInvariant();
            if (digest != BundledPemSha256) throw new InvalidDataException("公司根证书校验失败。");
            var match = Regex.Match(Encoding.ASCII.GetString(pem), "-----BEGIN CERTIFICATE-----([\\s\\S]+?)-----END CERTIFICATE-----");
            if (!match.Success) throw new InvalidDataException("公司根证书格式错误。");
            return new CompanyCertificatePolicy(Convert.FromBase64String(Regex.Replace(match.Groups[1].Value, "\\s", "")));
        }

        internal static bool IsCompanyOrigin(Uri uri)
        {
            return uri != null && uri.Scheme == Uri.UriSchemeHttps && uri.Port == 443
                && uri.UserInfo.Length == 0
                && (uri.Host.Equals("imp.utenelec", StringComparison.OrdinalIgnoreCase)
                    || uri.Host == "192.168.1.13");
        }

    }
}
