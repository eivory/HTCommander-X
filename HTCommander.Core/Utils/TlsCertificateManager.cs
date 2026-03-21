/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace HTCommander
{
    public static class TlsCertificateManager
    {
        private static readonly object certLock = new object();
        private static X509Certificate2 cachedCert;

        public static X509Certificate2 GetOrCreateCertificate(string configDir)
        {
            lock (certLock)
            {
                if (cachedCert != null) return cachedCert;

                string pfxPath = Path.Combine(configDir, "htcommander-tls.pfx");

                if (File.Exists(pfxPath))
                {
                    try
                    {
                        var cert = X509CertificateLoader.LoadPkcs12FromFile(pfxPath, null, X509KeyStorageFlags.Exportable);
                        if (cert.NotAfter > DateTime.UtcNow)
                        {
                            cachedCert = cert;
                            return cachedCert;
                        }
                        cert.Dispose();
                    }
                    catch { }
                }

                cachedCert = GenerateAndSave(pfxPath);
                return cachedCert;
            }
        }

        public static void InvalidateCache()
        {
            lock (certLock)
            {
                cachedCert?.Dispose();
                cachedCert = null;
            }
        }

        private static X509Certificate2 GenerateAndSave(string pfxPath)
        {
            using (var rsa = RSA.Create(2048))
            {
                var req = new CertificateRequest(
                    "CN=HTCommander",
                    rsa,
                    HashAlgorithmName.SHA256,
                    RSASignaturePadding.Pkcs1);

                // Basic constraints: not a CA
                req.CertificateExtensions.Add(
                    new X509BasicConstraintsExtension(false, false, 0, true));

                // Key usage: digital signature, key encipherment
                req.CertificateExtensions.Add(
                    new X509KeyUsageExtension(
                        X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment,
                        true));

                // Enhanced key usage: server authentication
                req.CertificateExtensions.Add(
                    new X509EnhancedKeyUsageExtension(
                        new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") },
                        false));

                // Subject Alternative Names
                var sanBuilder = new SubjectAlternativeNameBuilder();
                sanBuilder.AddDnsName("localhost");
                sanBuilder.AddIpAddress(IPAddress.Loopback);
                sanBuilder.AddIpAddress(IPAddress.IPv6Loopback);

                try
                {
                    foreach (var iface in NetworkInterface.GetAllNetworkInterfaces())
                    {
                        if (iface.OperationalStatus != OperationalStatus.Up) continue;
                        if (iface.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;

                        var props = iface.GetIPProperties();
                        foreach (var addr in props.UnicastAddresses)
                        {
                            if (addr.Address.AddressFamily == AddressFamily.InterNetwork ||
                                addr.Address.AddressFamily == AddressFamily.InterNetworkV6)
                            {
                                sanBuilder.AddIpAddress(addr.Address);
                            }
                        }
                    }
                }
                catch { }

                req.CertificateExtensions.Add(sanBuilder.Build());

                var cert = req.CreateSelfSigned(
                    DateTimeOffset.UtcNow.AddDays(-1),
                    DateTimeOffset.UtcNow.AddYears(10));

                // Export and re-import to ensure private key is persistable on all platforms
                byte[] pfxBytes = cert.Export(X509ContentType.Pfx);
                cert.Dispose();

                Directory.CreateDirectory(Path.GetDirectoryName(pfxPath));
                File.WriteAllBytes(pfxPath, pfxBytes);

                return X509CertificateLoader.LoadPkcs12(pfxBytes, null, X509KeyStorageFlags.Exportable);
            }
        }
    }
}
