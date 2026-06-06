import Foundation

/// Display helper that turns a raw project directory name into a human-readable
/// title. Kept as a `String` extension in its own file, mirroring the
/// type-extension idiom used by `TaskType+Glyph.swift` / `TaskStatus+Glance.swift`.
///
/// Used at the single project-name derivation site in `TaskParser.swift` so all
/// three display surfaces (menu bar, project card, plan detail) render the
/// titleized form without any view-level changes.
extension String {
    /// Returns a title-cased version of the receiver:
    /// - `-` and `_` separators become spaces;
    /// - camelCase boundaries are split (a space is inserted before an uppercase
    ///   letter that follows a non-space character);
    /// - runs of whitespace collapse to a single space (and leading/trailing
    ///   whitespace is trimmed);
    /// - each resulting word is capitalized (first letter upper, rest lower).
    ///
    /// Examples: `"plans-desktop" -> "Plans Desktop"`,
    /// `"PlansDesktop" -> "Plans Desktop"`, `"" -> ""`.
    func titleized() -> String {
        // Normalize separators to spaces.
        var spaced = ""
        var previousWasSpace = true // treat start-of-string like a space boundary
        for character in self {
            if character == "-" || character == "_" || character == " " {
                if !previousWasSpace {
                    spaced.append(" ")
                    previousWasSpace = true
                }
                continue
            }
            // Split camelCase: insert a space before an uppercase letter that
            // follows a non-space character.
            if character.isUppercase && !previousWasSpace {
                spaced.append(" ")
            }
            spaced.append(character)
            previousWasSpace = false
        }

        return spaced
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
