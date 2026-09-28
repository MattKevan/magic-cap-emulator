import Testing
@testable import DataRoverWeb

@Suite struct DestinationPolicyTests {
    @Test func rejectsLocalNames() {
        for host in ["localhost", "a.localhost", "printer.local", "[::1]", "fe80::1"] {
            #expect(DestinationPolicy.isForbiddenHost(host), "\(host)")
        }
    }

    @Test func rejectsPrivateAndReservedIPv4Literals() {
        for host in ["0.0.0.0", "10.0.2.2", "127.0.0.1", "169.254.1.1", "172.16.0.1", "172.31.255.255",
                     "192.168.1.1", "100.64.0.1", "192.0.0.8", "198.18.0.1", "224.0.0.1", "240.0.0.1"] {
            #expect(DestinationPolicy.isForbiddenHost(host), "\(host)")
        }
    }

    @Test func rejectsNumericEncodingsBeforeDNS() {
        for host in ["2130706433", "0x7f000001", "017700000001", "93.184.216.34"] {
            #expect(!DestinationPolicy.resolvesOnlyPublicAddresses(host), "\(host)")
        }
    }

    @Test func allowsOrdinaryPublicNamesLexically() {
        #expect(!DestinationPolicy.isForbiddenHost("en.wikipedia.org"))
        #expect(!DestinationPolicy.isForbiddenHost("172.32.0.1"))
    }
}
