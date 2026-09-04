import Foundation

/// A hand-picked split of the open windows into screen bands, top to
/// bottom: `[4, 1]` is four windows across the top and one below.
public struct RowPlan: Equatable {
    public static let maximumColumns = 5
    public static let maximumRows = 5

    /// Windows per band, top to bottom. Empty bands are dropped.
    public let rows: [Int]

    public init(rowCounts: [Int]) {
        rows = rowCounts.filter { $0 > 0 }
    }

    public var windowCount: Int { rows.reduce(0, +) }

    public var isValid: Bool {
        !rows.isEmpty
            && rows.count <= Self.maximumRows
            && rows.allSatisfy { $0 <= Self.maximumColumns }
    }

    /// True when the plan places exactly the given number of windows.
    public func fits(windowCount count: Int) -> Bool {
        isValid && windowCount == count
    }

    /// "4 + 1"
    public var title: String { rows.map(String.init).joined(separator: " + ") }
}
