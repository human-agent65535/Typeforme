import Foundation

@MainActor
final class BridgeService {
    let store = PairingStore()
    let routeResolver = BridgeRouteResolver()
}
