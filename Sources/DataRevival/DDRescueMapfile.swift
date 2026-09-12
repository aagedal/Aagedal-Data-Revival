import Foundation

/// A validated summary of the rescue domain recorded by GNU ddrescue.
struct DDRescueMapSnapshot: Sendable, Equatable {
    let currentPosition: Int64
    let currentStatus: Character
    let currentPass: Int
    let rescuedByteCount: Int64
    let badSectorByteCount: Int64
    let pendingByteCount: Int64

    var totalByteCount: Int64 {
        rescuedByteCount + badSectorByteCount + pendingByteCount
    }

    var rescuedFraction: Double {
        guard totalByteCount > 0 else { return 0 }
        return Double(rescuedByteCount) / Double(totalByteCount)
    }

    var isFinished: Bool {
        currentStatus == "+" && pendingByteCount == 0
    }
}

enum DDRescueMapfile {
    enum ParseError: Error, Equatable {
        case invalid
    }

    /// Parses the strict mapfile shape produced by Data Revival's whole-device
    /// ddrescue command. The block list must cover the source exactly, without
    /// gaps or overlaps, before it is trusted for a resumed write.
    static func parse(_ data: Data, expectedByteCount: Int64) throws -> DDRescueMapSnapshot {
        guard expectedByteCount > 0,
              let contents = String(data: data, encoding: .utf8) else {
            throw ParseError.invalid
        }

        let records = contents.split(whereSeparator: \Character.isNewline).compactMap { line -> [Substring]? in
            let fields = fields(in: line)
            return fields.isEmpty ? nil : fields
        }
        guard let statusFields = records.first,
              statusFields.count == 3,
              let currentPosition = parseNonnegativeInteger(statusFields[0]),
              currentPosition <= expectedByteCount,
              let currentStatus = singleCharacter(statusFields[1]),
              "?*%/-+".contains(currentStatus),
              let currentPass = Int(statusFields[2]),
              currentPass > 0,
              records.count > 1 else {
            throw ParseError.invalid
        }

        var expectedPosition: Int64 = 0
        var rescuedByteCount: Int64 = 0
        var badSectorByteCount: Int64 = 0
        var pendingByteCount: Int64 = 0

        for fields in records.dropFirst() {
            guard fields.count == 3,
                  let position = parseNonnegativeInteger(fields[0]),
                  let size = parseNonnegativeInteger(fields[1]),
                  size > 0,
                  position == expectedPosition,
                  let blockStatus = singleCharacter(fields[2]),
                  "?*/-+".contains(blockStatus) else {
                throw ParseError.invalid
            }

            let (end, overflow) = position.addingReportingOverflow(size)
            guard !overflow, end <= expectedByteCount else {
                throw ParseError.invalid
            }
            expectedPosition = end

            switch blockStatus {
            case "+":
                rescuedByteCount += size
            case "-":
                badSectorByteCount += size
            default:
                pendingByteCount += size
            }
        }

        guard expectedPosition == expectedByteCount else {
            throw ParseError.invalid
        }

        return DDRescueMapSnapshot(
            currentPosition: currentPosition,
            currentStatus: currentStatus,
            currentPass: currentPass,
            rescuedByteCount: rescuedByteCount,
            badSectorByteCount: badSectorByteCount,
            pendingByteCount: pendingByteCount
        )
    }

    private static func singleCharacter(_ value: Substring) -> Character? {
        guard value.count == 1 else { return nil }
        return value.first
    }

    private static func fields(in line: Substring) -> [Substring] {
        var content = line
        if let commentStart = line.firstIndex(of: "#") {
            let beginsLine = commentStart == line.startIndex
            let followsWhitespace = !beginsLine && line[line.index(before: commentStart)].isWhitespace
            if beginsLine || followsWhitespace {
                content = line[..<commentStart]
            }
        }
        return content.split(whereSeparator: \Character.isWhitespace)
    }

    /// GNU ddrescue accepts the C++ integer forms used in mapfiles: decimal,
    /// hexadecimal with 0x, and octal with a leading zero.
    private static func parseNonnegativeInteger(_ value: Substring) -> Int64? {
        let text = String(value)
        guard !text.isEmpty, text.first != "+", text.first != "-" else { return nil }

        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            return Int64(text.dropFirst(2), radix: 16)
        }
        if text.count > 1, text.first == "0" {
            return Int64(text.dropFirst(), radix: 8)
        }
        return Int64(text, radix: 10)
    }
}
