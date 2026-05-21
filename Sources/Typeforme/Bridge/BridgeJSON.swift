import Foundation

enum BridgeJSON {
    private static let lock = NSLock()
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let prettySortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try decoder.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try encoder.encode(value)
    }

    static func encodeSorted<T: Encodable>(_ value: T) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try sortedEncoder.encode(value)
    }

    static func encodePrettySorted<T: Encodable>(_ value: T) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try prettySortedEncoder.encode(value)
    }
}
