@testable import MulticastDiscovery

/// Real records from this LAN (resolved with `dns-sd -L`, 2026-11-26).
enum Fixture {
    // AirConnect airupnp bridge on pi.local (TXT exactly as advertised).
    static let bridgeTXT = "am=airupnp tp=UDP sm=false sv=false ek=1 et=0,1 md=0,1,2 cn=0,1 ch=2 ss=16 sr=44100 vn=3 txtvers=1"

    static let sonosRAOPTXT = "cn=0,1 da=true et=0,4 ft=0x445F8A00,0x801C340 fv=p20.98.0-82170 md=0,1,2 am=One sf=0x404 tp=UDP vn=65537 vs=366.0 pk=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
    static let sonosAirPlayTXT = "acl=0 deviceid=54:2A:1B:00:11:22 features=0x445F8A00,0x801C340 fex=AIpfREDDAQgQIQ rsf=0x0 fv=p20.98.0-82170 flags=0x404 model=One manufacturer=Sonos serialNumber=54-2A-1B-00-11-22:A protovers=1.1 srcvers=366.0 pi=54:2A:1B:00:11:22 gid=54:2A:1B:00:11:22 gcgl=0 pk=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 bat=W"

    static let denonRAOPTXT = #"cn=0,1 da=true et=0,4 ft=0x445F8A00,0x801C340 fv=p20.3.139.174 md=0,1,2 am=Denon\ AVR-X2800H sf=0x804 tp=UDP vn=65537 vs=366.0 pk=b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"#
    static let denonAirPlayTXT = #"acl=0 deviceid=8C:A9:6F:00:11:E9 features=0x445F8A00,0x801C340 fex=AIpfREDDAQgQIQ rsf=0x0 fv=p20.3.139.174 flags=0x804 model=Denon\ AVR-X2800H manufacturer=Denon serialNumber=ABCD012345678 protovers=1.1 srcvers=366.0 gcgl=0 bat=WN100"#

    static let macRAOPTXT = "cn=0,1,2,3 da=true et=0,3,5 ft=0x4A7FCFD5,0x38174FDE sf=0x204 md=0,1,2 am=Mac17,4 pk=c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3 tp=UDP vn=65537 vs=960.13.25 vv=0"
    static let macAirPlayTXT = "act=2 acl=0 deviceid=2A:41:9D:00:11:25 features=0x4A7FCFD5,0x38174FDE rsf=0x8 flags=0x204 model=Mac17,4 at=4 protovers=1.1 srcvers=960.13.25"
    static let macHost = "Taylors-MacBook-Air.local."

    static func raop(_ instance: String, host: String, port: UInt16, txt: String, interface: UInt32 = 12) -> ResolvedService {
        ResolvedService(type: .raop, instanceName: instance, host: host, port: port,
                        txt: TXTRecord.parse(displayString: txt), interfaceIndex: interface, seenOnLoopback: interface == 1)
    }

    static func airplay(_ instance: String, host: String, port: UInt16 = 7000, txt: String, interface: UInt32 = 12) -> ResolvedService {
        ResolvedService(type: .airplay, instanceName: instance, host: host, port: port,
                        txt: TXTRecord.parse(displayString: txt), interfaceIndex: interface, seenOnLoopback: interface == 1)
    }

    static let masterBedroom = raop("BBBB58000020@Master Bedroom", host: "pi.local.", port: 49152, txt: bridgeTXT)
    static let mainBedroom = raop("BBBB58000010@Main Bedroom", host: "pi.local.", port: 48179, txt: bridgeTXT)
    static let patio = raop("BBBB58000030@Patio", host: "pi.local.", port: 50111, txt: bridgeTXT)
    static let denonBridge = raop("BBBB6F0011E7@Denon AVR-X2800H+", host: "pi.local.", port: 53263, txt: bridgeTXT)
    static let sonosRAOP = raop("542A1B001122@Hall Sonos", host: "Sonos-542A1B001122.local.", port: 7000, txt: sonosRAOPTXT)
    static let sonosAirPlay = airplay("Hall Sonos", host: "Sonos-542A1B001122.local.", txt: sonosAirPlayTXT)
    static let denonRAOP = raop("8CA96F0011E9@Denon AVR-X2800H", host: "HEOS-Player.local.", port: 7000, txt: denonRAOPTXT)
    static let denonAirPlay = airplay("Denon AVR-X2800H", host: "HEOS-Player.local.", txt: denonAirPlayTXT)
    static let macRAOP = raop("2A419D001125@Taylor’s MacBook Air", host: macHost, port: 7000, txt: macRAOPTXT)
    static let macAirPlay = airplay("Taylor’s MacBook Air", host: macHost, txt: macAirPlayTXT)
    static let macRAOPLoopback = raop("2A419D001125@Taylor’s MacBook Air", host: macHost, port: 7000, txt: macRAOPTXT, interface: 1)

    /// Everything the LAN advertises, as the browser would collect it.
    static let all: [ResolvedService] = [
        masterBedroom, mainBedroom, patio, denonBridge,
        sonosRAOP, sonosAirPlay, denonRAOP, denonAirPlay,
        macRAOP, macAirPlay,
    ]

    static let macIdentity = LocalMachineIdentity(hostNames: ["Taylors-MacBook-Air.local"])
}
