import Foundation

struct AdvancedSearchDraft: Equatable {
    var from = ""
    var to = ""
    var subject = ""
    var words = ""
    var excludedWords = ""
    var hasAttachment = false
    var useAfterDate = false
    var afterDate = Date()
    var useBeforeDate = false
    var beforeDate = Date()

    func gmailQuery(calendar: Calendar = .current) -> String {
        var terms: [String] = []
        appendOperator("from", value: from, to: &terms)
        appendOperator("to", value: to, to: &terms)
        appendOperator("subject", value: subject, quote: true, to: &terms)
        appendWords(words, prefix: "", to: &terms)
        appendWords(excludedWords, prefix: "-", to: &terms)
        if hasAttachment { terms.append("has:attachment") }
        if useAfterDate { terms.append("after:\(Self.dateString(afterDate, calendar: calendar))") }
        if useBeforeDate { terms.append("before:\(Self.dateString(beforeDate, calendar: calendar))") }
        return terms.joined(separator: " ")
    }

    private func appendOperator(_ name: String, value: String, quote: Bool = false, to terms: inout [String]) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        terms.append("\(name):\(quote && value.contains(" ") ? "\"\(value)\"" : value)")
    }

    private func appendWords(_ value: String, prefix: String, to terms: inout [String]) {
        terms.append(contentsOf: value.split(whereSeparator: { $0.isWhitespace }).map { "\(prefix)\($0)" })
    }

    private static func dateString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
