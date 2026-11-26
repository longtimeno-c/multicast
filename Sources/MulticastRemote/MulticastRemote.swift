import MulticastHubModel

// MulticastRemote: the network link between the Mac hub and its remotes.
//
//   HubServer          (Mac)    serves any HubBackend on the LAN: Bonjour, pairing, sessions
//   RemoteHubBackend   (iPhone) HubBackend as a client of a HubServer
//   HubBrowser         (iPhone) finds hubs over Bonjour
//   PairingKeyStore             where pairing keys live (Keychain, or memory in tests)
//
// Protocol and framing: Wire.swift. Pairing and session cryptography, with the threat model:
// Crypto.swift.
public enum MulticastRemoteModule {
    public static let isImplemented = true
}
