import Foundation

/// Exact CZK amounts represented as signed haléře.
public enum Money {
  public static func parse(_ text: String) throws -> Int64 {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw FinanceError.invalid("Částka je prázdná.") }

    var index = value.startIndex
    var negative = false
    if value[index] == "+" || value[index] == "-" {
      negative = value[index] == "-"
      index = value.index(after: index)
    }
    guard index < value.endIndex else { throw FinanceError.invalid("Částka nemá číslice.") }

    let unsigned = String(value[index...])
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "\u{00A0}", with: "")
    let separatorCount = unsigned.reduce(into: 0) { count, character in
      if character == "," || character == "." { count += 1 }
    }
    guard separatorCount <= 1 else {
      throw FinanceError.invalid("Částka obsahuje více desetinných oddělovačů.")
    }

    let components = unsigned.split(
      omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
    guard components.count == 1 || components.count == 2,
      !components[0].isEmpty,
      components[0].allSatisfy({ $0.isASCII && $0.isNumber })
    else {
      throw FinanceError.invalid("Částka má neplatný formát.")
    }
    let fractional = components.count == 2 ? String(components[1]) : ""
    guard fractional.count <= 2,
      fractional.allSatisfy({ $0.isASCII && $0.isNumber })
    else {
      throw FinanceError.invalid("Částka může mít nejvýše dvě desetinná místa.")
    }

    var parsedMajor: UInt64 = 0
    for byte in components[0].utf8 {
      guard (48...57).contains(byte) else {
        throw FinanceError.invalid("Částka má neplatný formát.")
      }
      let digit = UInt64(byte - 48)
      let multiplied = parsedMajor.multipliedReportingOverflow(by: 10)
      let added = multiplied.partialValue.addingReportingOverflow(digit)
      guard !multiplied.overflow, !added.overflow else {
        throw FinanceError.invalid("Částka je příliš velká.")
      }
      parsedMajor = added.partialValue
    }

    let fractionBytes = Array(fractional.utf8)
    let fractionValue: UInt64
    switch fractionBytes.count {
    case 0: fractionValue = 0
    case 1:
      guard let first = fractionBytes.first, (48...57).contains(first) else {
        throw FinanceError.invalid("Částka má neplatný formát.")
      }
      fractionValue = UInt64(first - 48) * 10
    case 2:
      guard let first = fractionBytes.first, let last = fractionBytes.last,
        (48...57).contains(first), (48...57).contains(last)
      else {
        throw FinanceError.invalid("Částka má neplatný formát.")
      }
      fractionValue = UInt64(first - 48) * 10 + UInt64(last - 48)
    default: throw FinanceError.invalid("Částka může mít nejvýše dvě desetinná místa.")
    }
    let magnitudeBase = parsedMajor.multipliedReportingOverflow(by: 100)
    let magnitude = magnitudeBase.partialValue.addingReportingOverflow(fractionValue)
    guard !magnitudeBase.overflow, !magnitude.overflow else {
      throw FinanceError.invalid("Částka je příliš velká.")
    }

    let maxMagnitude = negative ? UInt64(Int64.max) + 1 : UInt64(Int64.max)
    guard magnitude.partialValue <= maxMagnitude else {
      throw FinanceError.invalid("Částka je příliš velká.")
    }
    if negative {
      if magnitude.partialValue == UInt64(Int64.max) + 1 { return Int64.min }
      return -Int64(magnitude.partialValue)
    }
    return Int64(magnitude.partialValue)
  }

  public static func format(_ amount: Int64) -> String {
    let negative = amount < 0
    let magnitude: UInt64
    if amount == Int64.min {
      magnitude = UInt64(Int64.max) + 1
    } else {
      magnitude = UInt64(negative ? -amount : amount)
    }
    let major = magnitude / 100
    let minor = magnitude % 100
    let digits = String(major)
    var grouped = ""
    for (offset, character) in digits.enumerated() {
      if offset > 0 && (digits.count - offset) % 3 == 0 { grouped.append(" ") }
      grouped.append(character)
    }
    return "\(negative ? "-" : "")\(grouped),\(String(format: "%02llu", minor)) Kč"
  }

  public static func sum(_ amounts: [Int64]) throws -> Int64 {
    var result: Int64 = 0
    for amount in amounts {
      let addition = result.addingReportingOverflow(amount)
      guard !addition.overflow else { throw FinanceError.invalid("Součet částek je příliš velký.") }
      result = addition.partialValue
    }
    return result
  }

  public static func subtract(_ a: Int64, _ b: Int64) throws -> Int64 {
    let result = a.subtractingReportingOverflow(b)
    guard !result.overflow else { throw FinanceError.invalid("Výsledek operace je příliš velký.") }
    return result.partialValue
  }
}
