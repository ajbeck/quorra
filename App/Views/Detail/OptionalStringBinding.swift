import SwiftUI

extension Binding where Value == String? {
    func unwrapped(default fallback: String = "") -> Binding<String> {
        Binding<String>(
            get: { wrappedValue ?? fallback },
            set: { wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

extension Binding where Value == [String]? {
    func commaJoinedString(default fallback: String = "") -> Binding<String> {
        Binding<String>(
            get: { (wrappedValue ?? []).joined(separator: ", ") },
            set: { input in
                let trimmed = input
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                wrappedValue = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
}
