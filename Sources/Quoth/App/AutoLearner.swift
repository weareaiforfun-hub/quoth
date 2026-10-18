import AppKit
import ApplicationServices
import QuothCore

/// Watches a just-pasted field for a few seconds and reports words the user corrected.
@MainActor
final class AutoLearner {
    private var task: Task<Void, Never>?
    private let checker = NSSpellChecker.shared
    static let delay: UInt64 = 8_000_000_000

    func watch(element: AXUIElement, pasted: String, onLearn: @escaping ([String]) -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            // Let the paste land, then snapshot the field.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let before = ContextCapture.currentValue(of: element), before.contains(pasted) else { return }
            try? await Task.sleep(nanoseconds: Self.delay)
            guard !Task.isCancelled, let self, let after = ContextCapture.currentValue(of: element) else { return }
            let personal = AppState.shared.personal
            let words = AutoLearn.candidates(
                pasted: pasted, before: before, after: after,
                isCommonWord: { self.isCommonWord($0) },
                known: Set(personal.dictionary.map(\.output)),
                deleted: Set(personal.deletedWords))
            if !words.isEmpty { onLearn(words) }
        }
    }

    /// An ordinary lowercase dictionary word per the system spell checker.
    private func isCommonWord(_ w: String) -> Bool {
        let range = checker.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}
