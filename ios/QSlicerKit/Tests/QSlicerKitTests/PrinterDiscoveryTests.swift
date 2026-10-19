import XCTest
@testable import QSlicerKit

final class PrinterDiscoveryTests: XCTestCase {
    func testClassCSubnetCandidates() throws {
        let hosts = PrinterDiscovery.candidateHosts(address: "192.168.1.42", netmask: "255.255.255.0")
        XCTAssertEqual(hosts.count, 253, "254 adresses d'hôte moins la nôtre")
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.42"))
        XCTAssertFalse(hosts.contains("192.168.1.0") || hosts.contains("192.168.1.255"))
    }

    func testBigNetworksAreLimitedToTheNeighbourhood() {
        // un /16 (65 534 adresses) est réduit au /22 qui contient notre adresse
        let hosts = PrinterDiscovery.candidateHosts(address: "10.0.5.20", netmask: "255.255.0.0")
        XCTAssertEqual(hosts.count, 1021)
        XCTAssertEqual(hosts.first, "10.0.4.1")
        XCTAssertEqual(hosts.last, "10.0.7.254")
        XCTAssertTrue(hosts.contains("10.0.5.1"))
        XCTAssertFalse(hosts.contains("10.0.5.20"))
        XCTAssertLessThanOrEqual(PrinterDiscovery.candidateHosts(address: "10.0.0.1", netmask: "255.0.0.0").count, 1022)
    }

    func testSmallSubnetsAndInvalidInput() {
        // /22 -> 1022 hôtes moins nous
        XCTAssertEqual(PrinterDiscovery.candidateHosts(address: "172.16.3.9", netmask: "255.255.252.0").count, 1021)
        XCTAssertEqual(PrinterDiscovery.candidateHosts(address: "192.168.1.5", netmask: "255.255.255.252"), ["192.168.1.6"], "un /30 n'a que deux hôtes : le nôtre et un autre")
        XCTAssertTrue(PrinterDiscovery.candidateHosts(address: "pas une ip", netmask: "255.255.255.0").isEmpty)
        XCTAssertTrue(PrinterDiscovery.candidateHosts(address: "192.168.1.5", netmask: "0.0.0.0").isEmpty)
        XCTAssertTrue(PrinterDiscovery.candidateHosts(address: "192.168.1.5", netmask: "255.255.255.255").isEmpty)
        // masque non contigu : repli sur le /24
        XCTAssertEqual(PrinterDiscovery.candidateHosts(address: "192.168.1.5", netmask: "255.0.255.0").count, 253)
        XCTAssertEqual(PrinterDiscovery.candidateHosts(address: "192.168.1.5", netmask: "255.255.255.0", limit: 10).count, 10)
    }

    func testAddressRoundTrip() {
        XCTAssertEqual(PrinterDiscovery.parseIPv4("192.168.1.42"), 0xC0A8_012A)
        XCTAssertEqual(PrinterDiscovery.format(0xC0A8_012A), "192.168.1.42")
        XCTAssertNil(PrinterDiscovery.parseIPv4("300.1.1.1"))
        XCTAssertNil(PrinterDiscovery.parseIPv4("1.2.3"))
    }

    func testAllCandidatesAreDeduplicated() {
        let a = PrinterDiscovery.Interface(name: "en0", address: "192.168.1.5", netmask: "255.255.255.0")
        let b = PrinterDiscovery.Interface(name: "en1", address: "192.168.1.6", netmask: "255.255.255.0")
        let hosts = PrinterDiscovery.allCandidateHosts(interfaces: [a, b])
        XCTAssertEqual(Set(hosts).count, hosts.count)
        XCTAssertEqual(hosts.count, 254, "chaque adresse une fois ; les deux nôtres ne sont sondées que depuis l'autre interface")
    }

    func testServerInfoParsing() throws {
        let ok = #"{"result":{"klippy_connected":true,"klippy_state":"ready","moonraker_version":"v0.8.0-143","api_version":[1,0,5]}}"#
        let info = try XCTUnwrap(PrinterDiscovery.parseServerInfo(Data(ok.utf8)))
        XCTAssertEqual(info.version, "v0.8.0-143")
        XCTAssertEqual(info.klippyState, "ready")
        XCTAssertNil(PrinterDiscovery.parseServerInfo(Data(#"{"result":{"something":"else"}}"#.utf8)), "pas un Moonraker")
        XCTAssertNil(PrinterDiscovery.parseServerInfo(Data("<html>hello</html>".utf8)))
        XCTAssertNil(PrinterDiscovery.parseServerInfo(Data()))
    }

    func testDiscoveredPrinterTitle() {
        XCTAssertEqual(DiscoveredPrinter(host: "10.0.0.2", port: 7125, hostname: "qidi-q2", klippyState: nil, version: nil).title, "qidi-q2")
        XCTAssertEqual(DiscoveredPrinter(host: "10.0.0.2", port: 7125, hostname: "", klippyState: nil, version: nil).title, "10.0.0.2")
        XCTAssertEqual(DiscoveredPrinter(host: "10.0.0.2", port: 7125, hostname: nil, klippyState: nil, version: nil).id, "10.0.0.2:7125")
    }

    func testLocalInterfacesNeverIncludeLoopback() {
        for interface in PrinterDiscovery.localInterfaces() {
            XCTAssertFalse(interface.address.hasPrefix("127."))
            XCTAssertNotNil(PrinterDiscovery.parseIPv4(interface.netmask))
        }
    }

    func testScanOfUnusedAddressesFindsNothing() async {
        // adresses de documentation (RFC 5737) : aucune réponse, fin rapide
        let found = await PrinterDiscovery.scan(hosts: ["192.0.2.1", "192.0.2.2"], port: 9, concurrency: 2, timeout: 0.3)
        XCTAssertTrue(found.isEmpty)
    }
}
