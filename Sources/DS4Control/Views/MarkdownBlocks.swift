import Foundation

/// Pure, dependency-free markdown block splitting for incremental streaming.
///
/// `splitBlocks` separates a (possibly partial) markdown string into *completed* blocks —
/// safe to render once and freeze — and a *mutable tail* that may still grow with the next
/// token. A block is completed only when a blank line at fence-depth 0 follows it; an open
/// code fence keeps everything from the fence onward in the tail until it closes. Blocks are
/// trimmed of the blank-line delimiters; the renderer re-introduces spacing via its layout.
enum MarkdownBlocks {
    static func splitBlocks(_ input: String) -> (completed: [String], tail: String) {
        var completed: [String] = []
        var current: [String] = []
        var fenceOpen = false

        func flush() {
            let block = current.joined(separator: "\n")
            if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completed.append(block)
            }
            current.removeAll()
        }

        for line in input.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenceOpen.toggle()
                current.append(line)
                continue
            }
            if !fenceOpen && trimmed.isEmpty {
                flush()  // blank line at depth 0 ends the current block
                continue
            }
            current.append(line)
        }
        // Whatever remains (including an unterminated open fence) is the mutable tail.
        let tail = current.joined(separator: "\n")
        return (completed, tail)
    }
}
