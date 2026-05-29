import Foundation

/// True when a ds4-server stderr line announces the bound HTTP listener.
func isReadyLine(_ line: String) -> Bool {
    line.lowercased().contains("listening on http://")
}
