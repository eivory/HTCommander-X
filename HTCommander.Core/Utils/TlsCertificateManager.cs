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
                        // Try loading with file-based passphrase, then legacy hardcoded, then no password
                        X509Certificate2 cert = null;
                        string passphrasePath = pfxPath + ".key";
                        string filePassphrase = File.Exists(passphrasePath) ? File.ReadAllText(passphrasePath).Trim() : null;
                        try
                        {
                            if (filePassphrase != null) cert = X509CertificateLoader.LoadPkcs12FromFile(pfxPath, filePassphrase, X509KeyStorageFlags.EphemeralKeySet);
                            else throw new Exception("No passphrase file");
                        }
                        catch
                        {
                            try { cert = X509CertificateLoader.LoadPkcs12FromFile(pfxPath, "htcommander-tls-local", X509KeyStorageFlags.EphemeralKeySet); }
                            catch { cert = X509CertificateLoader.LoadPkcs12FromFile(pfxPath, null, X509KeyStorageFlags.EphemeralKeySet); }
                        }
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
            using (var rsa = RSA.Create(3072))
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

                // Generate a random passphrase for on-disk protection (defense-in-depth beyond chmod 600)
                byte[] passphraseBytes = new byte[32];
                using (var passRng = RandomNumberGenerator.Create()) { passRng.GetBytes(passphraseBytes); }
                string pfxPassword = Convert.ToBase64String(passphraseBytes);
                byte[] pfxBytes = cert.Export(X509ContentType.Pfx, pfxPassword);
                cert.Dispose();

                Directory.CreateDirectory(Path.GetDirectoryName(pfxPath));
                File.WriteAllBytes(pfxPath, pfxBytes);

                // Save passphrase alongside PFX with restrictive permissions
                string passphrasePath = pfxPath + ".key";
                File.WriteAllText(passphrasePath, pfxPassword);
                try { File.SetUnixFileMode(passphrasePath, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }

                // Set restrictive file permissions on Linux/macOS (owner-only read/write)
                try { File.SetUnixFileMode(pfxPath, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }

                return X509CertificateLoader.LoadPkcs12(pfxBytes, pfxPassword, X509KeyStorageFlags.EphemeralKeySet);
            }
        }
    }
}
