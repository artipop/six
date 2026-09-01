import Foundation

/// The certificate authorities six carries a copy of, so that trusting one is a switch rather than a
/// download, a search for the right file and a trip through Keychain Access.
///
/// Being in here is not being trusted. Every bundle starts switched off and stays off until somebody
/// turns it on in the Certificates panel; see `CertificateStore` for what turning it on does, which
/// is less than the keychain would do.
///
/// The bytes are in the source rather than in `Resources/` on purpose. A trust anchor is exactly the
/// kind of thing that should be readable in a diff and impossible to swap out by dropping a file
/// into the bundle, and three certificates cost six kilobytes of base64. Each one is written down
/// below with the fingerprint its authority publishes, so what six ships can be checked against what
/// was meant to be shipped without decoding anything.
nonisolated enum BundledCertificates {
    static let all: [CertificateBundle] = [russianTrusted]

    // MARK: Минцифры России — the Russian Trusted CA

    /// The Ministry of Digital Development's certificate authority.
    ///
    /// Since 2022 the western authorities will not issue for a good part of the Russian internet —
    /// banks first of all — and those sites are served under this CA instead. No operating system
    /// ships it, so to any browser on a stock machine `alfabank.ru` and an attack look the same. The
    /// official instructions are to install it into the system keychain and mark it Always Trust,
    /// which grants it to every application on the machine; this switch grants it to six.
    ///
    /// Three certificates: the root everything chains to, and the two intermediates it has signed —
    /// the 2022 one, which expires in March 2027, and its 2024 replacement. Both are here because
    /// which one a site is under depends on when its certificate was issued, and a server that does
    /// not send its intermediate needs six to already have it.
    ///
    /// The GOST-signed pair published beside these is deliberately **not** here. Apple's Security
    /// framework has no GOST R 34.10 at all, so those certificates cannot be verified on this
    /// platform whatever six does with them; they are for the browsers that ship their own crypto.
    static let russianTrustedID = "ru.trusted-ca"

    private static let russianTrusted = CertificateBundle(
        id: russianTrustedID,
        name: String(localized: "Russian Trusted CA"),
        detail: String(localized: "Ministry of Digital Development of Russia — needed by Russian bank and government sites"),
        source: URL(string: "https://www.gosuslugi.ru/crt"),
        certificates: [rootRSA2022, subRSA2022, subRSA2024].compactMap {
            Data(base64Encoded: $0).flatMap(TrustedCertificate.init(der:))
        },
        isBuiltIn: true,
        file: nil
    )

    // subject= /C=RU/O=The Ministry of Digital Development and Communications/CN=Russian Trusted Root CA
    // notBefore=Mar 1 21:04:15 2022 GMT notAfter=Feb 27 21:04:15 2032 GMT
    // SHA-256 d26d2d0231b7c39f92cc738512ba54103519e4405d68b5bd703e9788ca8ecf31
    private static let rootRSA2022 =
        "MIIFwjCCA6qgAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwcDELMAkGA1UEBhMCUlUxPzA9BgNV" +
        "BAoMNlRoZSBNaW5pc3RyeSBvZiBEaWdpdGFsIERldmVsb3BtZW50IGFuZCBDb21tdW5pY2F0" +
        "aW9uczEgMB4GA1UEAwwXUnVzc2lhbiBUcnVzdGVkIFJvb3QgQ0EwHhcNMjIwMzAxMjEwNDE1" +
        "WhcNMzIwMjI3MjEwNDE1WjBwMQswCQYDVQQGEwJSVTE/MD0GA1UECgw2VGhlIE1pbmlzdHJ5" +
        "IG9mIERpZ2l0YWwgRGV2ZWxvcG1lbnQgYW5kIENvbW11bmljYXRpb25zMSAwHgYDVQQDDBdS" +
        "dXNzaWFuIFRydXN0ZWQgUm9vdCBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB" +
        "AMfFOZ8pUAL3+r2nqqE0Zp52selXsKGFYoG0GM5bwz1bSFtCt+AZQMhkWQheI3poZAToYJu6" +
        "9pHLKS6QXBiwBC1cvzYmUYKMYZC7jE5YhEU2bSL0mX7NaMxMDmH2/NwuOVRj8OImVa5s1F4U" +
        "zn4Kv3PFlDBjjSjXKVY9kmjUBsXQrIHeaqmUIsPIlNWUnimXS0I0abExqkbdrXbXYwCOXhOO" +
        "2pDUx3ckmJlCMUGacUTnylyQW2VsJIyIGA8V0xzdaeUXg0VZ6ZmNUr5YBer/EAOLPb8NYpsA" +
        "hJe2mXjMB/J9HNsoFMBFJ0lLOT/+dQvjbdRZoOT8eqJpWnVDU+QL/qEZnz57N88OWM3rabJk" +
        "RNdU/Z7x5SFIM9FrqtN8xewsiBWBI0K6XFuOBOTD4V08o4TzJ8+Ccq5XlCUW2L48pZNCYuBD" +
        "fBh7FxkB7qDgGDiaftEkZZfApRg2E+M9G8wkNKTPLDc4wH0FDTijhgxR3Y4PiS1HL2Zhw7bD" +
        "3CbslmEGgfnnZojNkJtcLeBHBLa52/dSwNU4WWLubaYSiAmA9IUMX1/RpfpxOxd4Ykmhz97o" +
        "FbUaDJFipIggx5sXePAlkTdWnv+RWBxlJwMQ25oEHmRguNYf4Zr/Rxr9cS93Y+mdXIZaBEE0" +
        "KS2iLRqaOiWBki9IMQU4phqPOBAaG7A+eP8PAgMBAAGjZjBkMB0GA1UdDgQWBBTh0YHlzlpf" +
        "BKrS6badZrHF+qwshzAfBgNVHSMEGDAWgBTh0YHlzlpfBKrS6badZrHF+qwshzASBgNVHRMB" +
        "Af8ECDAGAQH/AgEEMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOCAgEAALIY1wki" +
        "lt/urfEVM5vKzr6utOeDWCUczmWX/RX4ljpRdgF+5fAIS4vHtmXkqpSCOVeWUrJV9QvZn6L2" +
        "27ZwuE15cWi8DCDal3Ue90WgAJJZMfTshN4OI8cqW9E4EG9wglbEtMnObHlms8F3CHmrw3k6" +
        "KmUkWGoa+/ENmcVl68u/cMRl1JbW2bM+/3A+SAg2c6iPDlehczKx2oa95QW0SkPPWGuNA/CE" +
        "8CpyANIhu9XFrj3RQ3EqeRcSAQQod1RNuHpfETLU/A2gMmvn/w/sx7TB3W5BPs6rprOA37tu" +
        "tPq9u6FTZOcG1OqjC/B7yTqgI7rbyvox7DEXoX7rIiEqyNNUguTk/u3SZ4VXE2kmxdmSh3TQ" +
        "vybfbnXV4JbCZVaqiZraqc7oZMnRoWrXRG3ztbnbes/9qhRGI7PqXqeKJBztxRTEVj8ONs1d" +
        "WN5szTwaPIvhkhO3CO5ErU2rVdUr89wKpNXbBODFKRtgxUT70YpmJ46VVaqdAhOZD9EUUn4Y" +
        "aeLaS8AjSF/h7UkjOibNc4qVDiPP+rkehFWM66PVnP1Msh93tc+taIfCEYVMxjh8zNbFuoc7" +
        "fzvvrFILLe7ifvEIUqSVIC/AzplM/Jxw7buXFeGP1qVCBEHq391d/9RAfaZ12zkwFsl+IKwE" +
        "/OZxW8AHa9i1p4GO0YSNuczzEm4="

    // subject= /C=RU/O=The Ministry of Digital Development and Communications/CN=Russian Trusted Sub CA
    // notBefore=Mar 2 11:25:19 2022 GMT notAfter=Mar 6 11:25:19 2027 GMT
    // SHA-256 bbbde2103e790b999ec62bd03cf625a5a2e7c316e10afe6a490eedead8b3fd9b
    private static let subRSA2022 =
        "MIIHQjCCBSqgAwIBAgICEAIwDQYJKoZIhvcNAQELBQAwcDELMAkGA1UEBhMCUlUxPzA9BgNV" +
        "BAoMNlRoZSBNaW5pc3RyeSBvZiBEaWdpdGFsIERldmVsb3BtZW50IGFuZCBDb21tdW5pY2F0" +
        "aW9uczEgMB4GA1UEAwwXUnVzc2lhbiBUcnVzdGVkIFJvb3QgQ0EwHhcNMjIwMzAyMTEyNTE5" +
        "WhcNMjcwMzA2MTEyNTE5WjBvMQswCQYDVQQGEwJSVTE/MD0GA1UECgw2VGhlIE1pbmlzdHJ5" +
        "IG9mIERpZ2l0YWwgRGV2ZWxvcG1lbnQgYW5kIENvbW11bmljYXRpb25zMR8wHQYDVQQDDBZS" +
        "dXNzaWFuIFRydXN0ZWQgU3ViIENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA" +
        "9YPqBKOk19NFymrEwehzrhBEgT2atLezpduB24mQ7CiOa/HVpFCDRZzdxqlh8drku408/tTm" +
        "WzlNH/brHuQhZ/miWKOf35lpKzjyBd6TPM23uAfJvEOQ2/dnKGGJbsUo1/udKSvxQwVHpVv3" +
        "S80OlluKfhWPDEXQpgyFqIzPoxIQTLZ0deirZwMVHarZ5u8HqHetRuAtmO2ZDGQnvVOJYAjl" +
        "s+Hiueq7Lj7Oce7CQsTwVZeP+XQx28PAaEZ3y6sQEt6rL06ddpSdoTMpBnCqTbxW+eWMyjkI" +
        "n6t9GBtUV45yB1EkHNnj2Ex4GwCiN9T84QQjKSr+8f0psGrZvPbCbQAwNFJjisLixnjlGPLK" +
        "a5vOmNwIh/LAyUW5DjpkCx004LPDuqPpFsKXNKpaL2Dm6uc0x4Jo5m+gUTVORB6hOSzWnWDj" +
        "2GWfomLzzyjG81DRGFBpco/O93zecsIN3SL2Ysjpq1zdoS01CMYxie//9zWvYwzI25/OZigt" +
        "npCIrcd2j1Y6dMUFQAzAtHE+qsXflSL8HIS+IJEFIQobLlYhHkoE3avgNx5jlu+OLYe0dF0Y" +
        "kx1PGNjbwqvTX37RCn32NMjlotW2QcGEZhDKj+3urZizp5xdTPZitA+aEjZM/Ni71VOdiOP0" +
        "igbw6asZ2fxdozZ1TnSSYNYvNATwthNmZysCAwEAAaOCAeUwggHhMBIGA1UdEwEB/wQIMAYB" +
        "Af8CAQAwDgYDVR0PAQH/BAQDAgGGMB0GA1UdDgQWBBTR4XENCy2BTm6KSo9MI7NMXqtpCzAf" +
        "BgNVHSMEGDAWgBTh0YHlzlpfBKrS6badZrHF+qwshzCBxwYIKwYBBQUHAQEEgbowgbcwOwYI" +
        "KwYBBQUHMAKGL2h0dHA6Ly9yb3N0ZWxlY29tLnJ1L2NkcC9yb290Y2Ffc3NsX3JzYTIwMjIu" +
        "Y3J0MDsGCCsGAQUFBzAChi9odHRwOi8vY29tcGFueS5ydC5ydS9jZHAvcm9vdGNhX3NzbF9y" +
        "c2EyMDIyLmNydDA7BggrBgEFBQcwAoYvaHR0cDovL3JlZXN0ci1wa2kucnUvY2RwL3Jvb3Rj" +
        "YV9zc2xfcnNhMjAyMi5jcnQwgbAGA1UdHwSBqDCBpTA1oDOgMYYvaHR0cDovL3Jvc3RlbGVj" +
        "b20ucnUvY2RwL3Jvb3RjYV9zc2xfcnNhMjAyMi5jcmwwNaAzoDGGL2h0dHA6Ly9jb21wYW55" +
        "LnJ0LnJ1L2NkcC9yb290Y2Ffc3NsX3JzYTIwMjIuY3JsMDWgM6Axhi9odHRwOi8vcmVlc3Ry" +
        "LXBraS5ydS9jZHAvcm9vdGNhX3NzbF9yc2EyMDIyLmNybDANBgkqhkiG9w0BAQsFAAOCAgEA" +
        "RBVzZls79AdiSCpar15dA5Hr/rrT4WbrOfzlpI+xrLeRPrUG6eUWIW4vSui1yx3iqGLCjPcK" +
        "b+HOTwoRMbI6ytP/ndp3TlYua2advYBEhSvjs+4vDZNwXr/DanbwIWdurZmViQRBDFebpkvn" +
        "Ivru/RpWud/5r624Wp8voZMRtj/cm6aI9LtvBfT9cfzhOaexI/99c14dyiuk1+6QhdwKaCRT" +
        "c1mdfNQmnfWNRbfWhWBlK3h4GGE9JK33Gk8ZS8DMrkdAh0xby4xAQ/mSWAfWrBmfzlOqGyoB" +
        "1U47WTOeqNbWkkoAP2ys94+sJg4NTkiDVtXRF6nr6fYi0bSOvOFg0IQrMXO2Y8gyg9ARdPJw" +
        "KtvWX8VPADCYMiWHh4n8bZokIrImVKLDQKHY4jCsND2HHdJfnrdL2YJw1qFskNO4cSNmZydw" +
        "0Wkgjv9kF+KxqrDKlB8MZu2Hclph6v/CZ0fQ9YuE8/lsHZ0Qc2HyiSMnvjgK5fDc3TD4fa8F" +
        "E8gMNurM+kV8PT8LNIM+4Zs+LKEV8nqRWBaxkIVJGekkVKO8xDBOG/aN62AZKHOeGcyIdu7y" +
        "NMMRihGVZCYr8rYiJoKiOzDqOkPkLOPdhtVlgnhowzHDxMHND/E2WA5pZHuNM/m0TXt2wTTP" +
        "L7JH2YC0gPz/BvvSzjksgzU5rLbRyUKQkgU="

    // subject= /C=RU/O=The Ministry of Digital Development and Communications/CN=Russian Trusted Sub CA
    // notBefore=Jul 15 12:50:41 2024 GMT notAfter=Jul 19 12:50:41 2029 GMT
    // SHA-256 2155785036c900dbb5f1bb2a1569c80c55595bd6bf94867a29bbddbc7d88a3f2
    private static let subRSA2024 =
        "MIIG6DCCBNCgAwIBAgICEAUwDQYJKoZIhvcNAQELBQAwcDELMAkGA1UEBhMCUlUxPzA9BgNV" +
        "BAoMNlRoZSBNaW5pc3RyeSBvZiBEaWdpdGFsIERldmVsb3BtZW50IGFuZCBDb21tdW5pY2F0" +
        "aW9uczEgMB4GA1UEAwwXUnVzc2lhbiBUcnVzdGVkIFJvb3QgQ0EwHhcNMjQwNzE1MTI1MDQx" +
        "WhcNMjkwNzE5MTI1MDQxWjBvMQswCQYDVQQGEwJSVTE/MD0GA1UECgw2VGhlIE1pbmlzdHJ5" +
        "IG9mIERpZ2l0YWwgRGV2ZWxvcG1lbnQgYW5kIENvbW11bmljYXRpb25zMR8wHQYDVQQDDBZS" +
        "dXNzaWFuIFRydXN0ZWQgU3ViIENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA" +
        "1j0rkZECOt1S8o7IJY+4YKAxuEa5xaHKHXT2EpkuC/0krqMOjUy2oPIRNgR5g8X0Jl6jamxe" +
        "GLc4Q1tfju6or9oSRYThIUhRsFDQNBiBBEXoBgWxTfiKB2eyT97+pz5TBtBiRCPaLGRHYLRb" +
        "9Jz2HkJlxbtNPjtDrF5DPHym+mZ1M1z3hIQYAqJwLpsEBnsw/VxWMlxqHoeewd0huJMd71KQ" +
        "5vOKlz7KrIZ6EobNNa6wItuvsfj3kYCK7O78uLHGXXFxdr8Hae9lMUmC8F7AFwa+bO1LRlTl" +
        "qW7rE3rLf+jj70N01N8T3o22v14YBaFBWQWncAVYD2JuL3tH252+kdNOERf1fLbLRigJAbd+" +
        "hOhWYlNf963TFDgnNPliHNIW72SygVBnI2V3JwO1dp1hVKpK/zt8ziGdHW4gmOLTsH50YKdR" +
        "4jNqUgQv4wASlKn9OpN6zHYc5G8h86fYBM+zxE5ikGI+I/vIqBuI0eaDU92AWN/YjFLpu8tM" +
        "u9kLRSCf1vug6FIfDPWVo7iPac/SI2v8jnnpaW7ph/Pz3WkzaG7ZZJsfFs+8dploWc6LOoDt" +
        "bFBhMdGMxu024msC0PSjZb5ODXPIaO2NsA7fMiAtZcoK6anTUJh4zOP/stA9qsJGNxdrEmiP" +
        "XSmBZY/NY0wkZgZ6JTDhw7038bPvctkblJkCAwEAAaOCAYswggGHMB0GA1UdDgQWBBR3Pdk5" +
        "r0K93FvKduru/c4+YSkwXzAfBgNVHSMEGDAWgBTh0YHlzlpfBKrS6badZrHF+qwshzAOBgNV" +
        "HQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADCBmAYIKwYBBQUHAQEEgYswgYgwQAYI" +
        "KwYBBQUHMAKGNGh0dHA6Ly9udWMtY2RwLnZvc2tob2QucnUvY2RwL3Jvb3RjYV9zc2xfcnNh" +
        "MjAyMi5jcnQwRAYIKwYBBQUHMAKGOGh0dHA6Ly9udWMtY2RwLmRpZ2l0YWwuZ292LnJ1L2Nk" +
        "cC9yb290Y2Ffc3NsX3JzYTIwMjIuY3J0MIGFBgNVHR8EfjB8MDqgOKA2hjRodHRwOi8vbnVj" +
        "LWNkcC52b3NraG9kLnJ1L2NkcC9yb290Y2Ffc3NsX3JzYTIwMjIuY3JsMD6gPKA6hjhodHRw" +
        "Oi8vbnVjLWNkcC5kaWdpdGFsLmdvdi5ydS9jZHAvcm9vdGNhX3NzbF9yc2EyMDIyLmNybDAN" +
        "BgkqhkiG9w0BAQsFAAOCAgEAmsINXtQ7wwUWvIeOr80MdJS/5G4xhyZOVEmeUorThquT672y" +
        "cCg3XCxc4fwbiZqSSbBqntQ7RtiTAKMYMvBageKoVHbzz+R4jX01tKcTx8cDePrzdJ73bLNU" +
        "orE7RU9QsW4KyiUeRmjMDV23AUlEvuQFTwgkHXvbac1BBdPn9CrssQuF5EGohZKcQPFiAAc4" +
        "SHbRNhlr7uAwgpc/erzI9EAcvA6BVAXcVKoeGpV01uexUgZ6St5RP9UmDWNA7T4yVXWJ233N" +
        "0Q8bl+6AswINQ3PosPu6yQQHQjr65YS06epK+AeI6j+oGR4xI7EhTQhQvaobnGmX/8QQ7XDR" +
        "YCP2HXYxiffnn/CfZ/BVyKLYeY1ZipjEnzqdQIC2+Q3WtY8jsVRQMP38WFRmtsIt5snehnPT" +
        "s5bKGVIcYzj3o3Ex/K7agEz0zAJ0JR5ivXZOvNkT0g9x1v+S1IkU3e/nX1a+tpRquMtnHX0L" +
        "2lXArNHUbaOO9EJtd57WaIpofV5cVhhwShOgAuBc9UMJF3/n4t4RKiPxtsK8P67gcmphMhsl" +
        "j7AMYrYMej2NvQZY4m3ub3CPC/PrTjDONvb+8g5xrKtxBjYqC74HSB4dg9G3WimSDUuP2Su6" +
        "G2y2TUeyJuCvCLz289VoO0vg7cNdMobE3KCqAiiNhN2VBFxHAUKmUoRcRdw="
}
