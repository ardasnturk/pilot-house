import Foundation

/// The JSON dialect used on the wire and in the on-disk logs.
///
/// Dates are ISO 8601 with fractional seconds (`2026-10-24T03:47:33.439Z`) so
/// logs stay human-readable and ordering survives a round trip.
public enum PilothouseJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(iso8601))
        }
        var formatting: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]
        if pretty { formatting.formUnion([.prettyPrinted, .sortedKeys]) }
        encoder.outputFormatting = formatting
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            if let date = parseDate(string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date: \(string)"
            )
        }
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601Whole = Date.ISO8601FormatStyle()

    static func parseDate(_ string: String) -> Date? {
        if let date = try? iso8601.parse(string) { return date }
        return try? iso8601Whole.parse(string)
    }
}
