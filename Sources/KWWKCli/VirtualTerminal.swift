import Foundation

/// In-memory terminal used by tests. Interprets a small subset of ANSI escape
/// sequences sufficient to validate rendering output:
///  - printable bytes advance the cursor
///  - `\n` moves to the next row (col 0)
///  - `\r` moves cursor to col 0
///  - `\x1b[<n>A/B/C/D` moves the cursor
///  - `\x1b[<n>G` moves the cursor to a given column
///  - `\x1b[2J` clears the visible screen
///  - `\x1b[3J` clears the scrollback (no-op in this mock)
///  - `\x1b[K` clears from cursor to end of line
///  - `\x1b[?2026h` / `\x1b[?2026l` synchronized output markers (no-op)
final class VirtualTerminal: Terminal, @unchecked Sendable {
    private let lock = NSLock()

    private(set) var width: Int
    private(set) var height: Int

    // Grid: height rows × width columns.
    private var grid: [[Character]]
    private var row: Int = 0
    private var col: Int = 0

    private var resizeHandlers: [UUID: @Sendable (Int, Int) -> Void] = [:]
    private var writeBuffer: [String] = []
    private var pendingRender: Bool = false

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.grid = Array(repeating: Array(repeating: " ", count: width), count: height)
    }

    // MARK: - Terminal

    func write(_ data: String) {
        lock.lock()
        writeBuffer.append(data)
        processWrite(data)
        pendingRender = false
        lock.unlock()
    }

    func onResize(_ handler: @escaping @Sendable (Int, Int) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        resizeHandlers[id] = handler
        lock.unlock()
        return { [weak self] in
            self?.lock.lock()
            self?.resizeHandlers.removeValue(forKey: id)
            self?.lock.unlock()
        }
    }

    // MARK: - Test helpers

    func resize(width: Int, height: Int) {
        let handlers: [@Sendable (Int, Int) -> Void]
        lock.lock()
        self.width = width
        self.height = height
        var newGrid = Array(repeating: Array(repeating: Character(" "), count: width), count: height)
        for r in 0..<min(self.grid.count, height) {
            for c in 0..<min(self.grid[r].count, width) {
                newGrid[r][c] = self.grid[r][c]
            }
        }
        self.grid = newGrid
        handlers = Array(resizeHandlers.values)
        pendingRender = true
        lock.unlock()
        for h in handlers { h(width, height) }
    }

    /// Snapshot the visible viewport as an array of strings (rows).
    func getViewport() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return grid.map { String($0) }
    }

    /// Concatenation of everything written since construction; useful for
    /// asserting ANSI sequences.
    func getWrites() -> String {
        lock.lock(); defer { lock.unlock() }
        return writeBuffer.joined()
    }

    func clearWrites() {
        lock.lock(); defer { lock.unlock() }
        writeBuffer.removeAll()
    }

    /// Yield until the next batch of writes has been processed. For the mock
    /// this just yields once to let the event loop flush.
    func waitForRender() async {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    // MARK: - Minimal ANSI processing
    //
    // We iterate by Unicode scalar rather than Character because Swift treats
    // `\r\n` as a single grapheme cluster — which would cause neither the
    // `\r` nor the `\n` handler to match when both bytes arrive together.

    private func processWrite(_ data: String) {
        let scalars = Array(data.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar.value == 0x1B {
                i = handleEscape(scalars, startingAfter: i)
                continue
            }
            if scalar.value == 0x0A { // \n
                row += 1
                col = 0
                if row >= height { row = height - 1 }
                i += 1
                continue
            }
            if scalar.value == 0x0D { // \r
                col = 0
                i += 1
                continue
            }
            // Printable
            if row >= 0 && row < height && col >= 0 && col < width {
                grid[row][col] = Character(scalar)
            }
            col += 1
            if col >= width {
                col = width - 1
            }
            i += 1
        }
    }

    private func handleEscape(_ scalars: [Unicode.Scalar], startingAfter index: Int) -> Int {
        let next = index + 1
        guard next < scalars.count else { return next }
        let marker = scalars[next]
        if marker.value == 0x5B { // '['
            var end = next + 1
            var params = ""
            while end < scalars.count, !isCSIFinal(scalars[end]) {
                params.unicodeScalars.append(scalars[end])
                end += 1
            }
            guard end < scalars.count else { return end }
            let final = Character(scalars[end])
            applyCSI(params: params, final: final)
            return end + 1
        }
        if marker.value == 0x5F { // '_' APC: swallow until BEL (0x07)
            var end = next + 1
            while end < scalars.count, scalars[end].value != 0x07 {
                end += 1
            }
            return end < scalars.count ? end + 1 : end
        }
        // Unknown — skip ESC
        return next
    }

    private func isCSIFinal(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // Letters A-Z, a-z
        if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) { return true }
        if v == 0x7E { return true } // ~
        if v == 0x40 { return true } // @
        return false
    }

    private func applyCSI(params: String, final: Character) {
        let nums = params.split(separator: ";").map { Int($0) ?? 0 }
        let first = nums.first ?? 0
        switch final {
        case "A":
            row = max(0, row - max(1, first))
        case "B":
            row = min(height - 1, row + max(1, first))
        case "C":
            col = min(width - 1, col + max(1, first))
        case "D":
            col = max(0, col - max(1, first))
        case "G":
            col = max(0, min(width - 1, first - 1))
        case "H":
            let r = (nums.count > 0 ? nums[0] : 1) - 1
            let c = (nums.count > 1 ? nums[1] : 1) - 1
            row = max(0, min(height - 1, r))
            col = max(0, min(width - 1, c))
        case "J":
            if first == 2 {
                // Clear visible screen
                for r in 0..<height { grid[r] = Array(repeating: " ", count: width) }
            } else if first == 0 {
                // Clear from cursor to end of screen
                if row >= 0 && row < height {
                    if col < width {
                        for c in col..<width { grid[row][c] = " " }
                    }
                    for r in (row + 1)..<height {
                        grid[r] = Array(repeating: " ", count: width)
                    }
                }
            }
            // 3 → clear scrollback (no-op in mock)
        case "K":
            // Clear line based on param: 0 = from cursor to end, 1 = from start to cursor, 2 = full
            if row >= 0 && row < height {
                switch first {
                case 1:
                    for c in 0...min(col, width - 1) { grid[row][c] = " " }
                case 2:
                    grid[row] = Array(repeating: " ", count: width)
                default:
                    if col < width {
                        for c in col..<width { grid[row][c] = " " }
                    }
                }
            }
        default:
            break
        }
    }
}
