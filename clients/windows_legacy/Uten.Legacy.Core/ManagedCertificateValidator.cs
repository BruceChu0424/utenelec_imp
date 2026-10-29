using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Org.BouncyCastle.Asn1.X509;
using BcCertificate = Org.BouncyCastle.X509.X509Certificate;

namespace Uten.Legacy.Core
{
    /// <summary>CryptoAPI validates PKIX/SSL policy; BC parses SAN. Neither performs a Schannel handshake.</summary>
    internal sealed class ManagedCertificateValidator
    {
        private readonly byte[] companyRoot;
        internal ManagedCertificateValidator(CompanyCertificatePolicy companyPolicy)
        { companyRoot = companyPolicy.RootDer; }

        internal void Validate(Uri origin, IList<byte[]> supplied)
        {
            if (origin == null || origin.Scheme != Uri.UriSchemeHttps || origin.UserInfo.Length != 0
                || supplied == null || supplied.Count < 1 || supplied.Count > 8
                || supplied.Any(value => value == null || value.Length < 1 || value.Length > 32768)
                || supplied.Sum(value => (long)value.Length) > 65536)
                throw InvalidCertificate();
            try
            {
                var parsed = new BcCertificate(supplied[0]);
                if (!MatchesSubjectAlternativeName(origin, parsed)) throw InvalidCertificate();
                using (var leaf = new X509Certificate2(supplied[0]))
                using (var root = new X509Certificate2(companyRoot))
                using (var chain = new X509Chain())
                {
                    var now = DateTime.UtcNow;
                    if (leaf.NotBefore.ToUniversalTime() > now || leaf.NotAfter.ToUniversalTime() < now)
                        throw InvalidCertificate();
                    var basic = leaf.Extensions.OfType<X509BasicConstraintsExtension>().FirstOrDefault();
                    var usage = leaf.Extensions.OfType<X509KeyUsageExtension>().FirstOrDefault();
                    var eku = leaf.Extensions.OfType<X509EnhancedKeyUsageExtension>().FirstOrDefault();
                    if ((basic != null && basic.CertificateAuthority)
                        || (usage != null && (usage.KeyUsages & X509KeyUsageFlags.DigitalSignature) == 0)
                        || eku == null || !eku.EnhancedKeyUsages.Cast<Oid>().Any(value => value.Value == "1.3.6.1.5.5.7.3.1"))
                        throw InvalidCertificate();
                    var extra = new List<X509Certificate2>();
                    try
                    {
                        foreach (var bytes in supplied.Skip(1))
                        {
                            var certificate = new X509Certificate2(bytes);
                            extra.Add(certificate);
                            chain.ChainPolicy.ExtraStore.Add(certificate);
                        }
                        var company = CompanyCertificatePolicy.IsCompanyOrigin(origin);
                        if (company) chain.ChainPolicy.ExtraStore.Add(root);
                        chain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1"));
                        chain.ChainPolicy.VerificationFlags = X509VerificationFlags.NoFlag;
                        chain.ChainPolicy.VerificationTime = now;
                        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                        chain.ChainPolicy.UrlRetrievalTimeout = TimeSpan.FromSeconds(2);
                        var built = chain.Build(leaf);
                        if (company)
                        {
                            if (chain.ChainElements.Count < 2
                                || !chain.ChainElements[chain.ChainElements.Count - 1].Certificate.RawData.SequenceEqual(companyRoot)
                                || root.NotBefore.ToUniversalTime() > now || root.NotAfter.ToUniversalTime() < now)
                                throw InvalidCertificate();
                            var statuses = chain.ChainStatus;
                            if ((!built && !statuses.Any(value => value.Status == X509ChainStatusFlags.UntrustedRoot))
                                || statuses.Any(value => value.Status != X509ChainStatusFlags.NoError
                                    && value.Status != X509ChainStatusFlags.UntrustedRoot))
                                throw InvalidCertificate();
                        }
                        else if (!built || chain.ChainStatus.Any(value => value.Status != X509ChainStatusFlags.NoError))
                            throw InvalidCertificate();
                        // No ignore-name, ignore-time, ignore-usage or ignore-constraints flags.
                        // Unknown CA is allowed only after the exact pinned company root check above.
                        if (!VerifyWindowsSslPolicy(chain, origin.IdnHost.Trim('[', ']').TrimEnd('.'), company))
                            throw InvalidCertificate();
                    }
                    finally { foreach (var certificate in extra) certificate.Dispose(); }
                }
            }
            catch (AuthenticationException) { throw; }
            catch (Exception error) when (error is CryptographicException || error is ArgumentException
                || error is System.IO.IOException || error is Org.BouncyCastle.Security.Certificates.CertificateException)
            { throw InvalidCertificate(); }
        }

        internal static bool MatchesSubjectAlternativeName(Uri origin, BcCertificate certificate)
        {
            // Never fall back to CN. DNS and IP identities must have their corresponding SAN type.
            var names = certificate.GetSubjectAlternativeNames();
            if (names == null || names.Count > 100) return false;
            var host = origin.IdnHost.Trim('[', ']').TrimEnd('.');
            IPAddress expectedAddress;
            var isAddress = IPAddress.TryParse(host, out expectedAddress);
            foreach (var name in names)
            {
                if (name == null || name.Count != 2 || !(name[0] is int) || !(name[1] is string)) continue;
                var kind = (int)name[0];
                var text = (string)name[1];
                if (isAddress && kind == GeneralName.IPAddress)
                {
                    IPAddress candidate;
                    if (IPAddress.TryParse(text, out candidate)
                        && candidate.GetAddressBytes().SequenceEqual(expectedAddress.GetAddressBytes())) return true;
                }
                else if (!isAddress && kind == GeneralName.DnsName && MatchesDns(host, text)) return true;
            }
            return false;
        }

        private static bool MatchesDns(string host, string pattern)
        {
            if (String.IsNullOrEmpty(pattern) || pattern.Length > 253
                || pattern.Any(value => value <= 32 || value >= 127)) return false;
            pattern = pattern.TrimEnd('.');
            if (pattern.IndexOf('*') < 0) return host.Equals(pattern, StringComparison.OrdinalIgnoreCase);
            if (!pattern.StartsWith("*.", StringComparison.Ordinal) || pattern.LastIndexOf('*') != 0) return false;
            var hostLabels = host.Split('.');
            var patternLabels = pattern.Split('.');
            if (hostLabels.Length != patternLabels.Length || patternLabels.Length < 3
                || hostLabels.Any(value => value.StartsWith("xn--", StringComparison.OrdinalIgnoreCase))) return false;
            return host.Substring(host.IndexOf('.') + 1).Equals(pattern.Substring(2), StringComparison.OrdinalIgnoreCase);
        }

        private static AuthenticationException InvalidCertificate()
        { return new AuthenticationException("服务器证书未通过名称、有效期、用途或信任链校验。"); }

        private static bool VerifyWindowsSslPolicy(X509Chain chain, string serverName, bool pinnedCompanyRoot)
        {
            var serverNamePointer = Marshal.StringToHGlobalUni(serverName);
            var extraPointer = IntPtr.Zero;
            try
            {
                var extra = new SslExtraPolicy
                {
                    Size = (uint)Marshal.SizeOf(typeof(SslExtraPolicy)),
                    AuthenticationType = 2, // AUTHTYPE_SERVER
                    Checks = 0,
                    ServerName = serverNamePointer
                };
                extraPointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SslExtraPolicy)));
                Marshal.StructureToPtr(extra, extraPointer, false);
                var parameters = new ChainPolicyParameters
                {
                    Size = (uint)Marshal.SizeOf(typeof(ChainPolicyParameters)),
                    Flags = pinnedCompanyRoot ? 0x00000010u : 0u, // CERT_CHAIN_POLICY_ALLOW_UNKNOWN_CA_FLAG only
                    Extra = extraPointer
                };
                var status = new ChainPolicyStatus { Size = (uint)Marshal.SizeOf(typeof(ChainPolicyStatus)) };
                return CertVerifyCertificateChainPolicy(new IntPtr(4), chain.ChainContext, ref parameters, ref status)
                    && status.Error == 0;
            }
            finally
            {
                if (extraPointer != IntPtr.Zero) Marshal.FreeHGlobal(extraPointer);
                Marshal.FreeHGlobal(serverNamePointer);
            }
        }
        [DllImport("crypt32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CertVerifyCertificateChainPolicy(IntPtr policy, IntPtr chain,
            ref ChainPolicyParameters parameters, ref ChainPolicyStatus status);
        [StructLayout(LayoutKind.Sequential)]
        private struct SslExtraPolicy { internal uint Size; internal uint AuthenticationType; internal uint Checks; internal IntPtr ServerName; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ChainPolicyParameters { internal uint Size; internal uint Flags; internal IntPtr Extra; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ChainPolicyStatus { internal uint Size; internal uint Error; internal int ChainIndex; internal int ElementIndex; internal IntPtr Extra; }
    }
}
