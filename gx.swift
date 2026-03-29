// gx — Ghostty terminal control CLI
//
// Compile:  swiftc -O ~/.claude/tools/gx.swift -o ~/.local/bin/gx -framework Cocoa
//
// Requires: Accessibility permission (System Settings > Privacy & Security > Accessibility)
//           Grant to Ghostty (the app running this CLI)

import Cocoa

// MARK: - Private API for stable window IDs

// _AXUIElementGetWindow: undocumented API that extracts CGWindowID from AXUIElement.
// CGWindowID is a UInt32 stable for the lifetime of a window — doesn't change when title changes.
// Used by alt-tab-macos and other window managers. Available since at least macOS 10.10.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

private func cgWindowID(_ el: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(el, &wid) == .success, wid != 0 else { return nil }
    return wid
}

// MARK: - AX Utilities

private func ax<T>(_ el: AXUIElement, _ attr: String) -> T? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref as? T
}

private func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    ax(el, kAXChildrenAttribute as String) ?? []
}

private func axPerform(_ el: AXUIElement, _ action: String) {
    AXUIElementPerformAction(el, action as CFString)
}

/// Get window position as (x, y) for deterministic sorting
private func axPosition(_ el: AXUIElement) -> (Float, Float) {
    var pos: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success else {
        return (0, 0)
    }
    var point = CGPoint.zero
    AXValueGetValue(pos as! AXValue, .cgPoint, &point)
    return (Float(point.x), Float(point.y))
}

// MARK: - AppleScript Helpers

/// Execute AppleScript and return trimmed stdout. Returns nil on failure.
@discardableResult
private func runAS(_ script: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let out = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = out
    proc.standardError = errPipe
    do { try proc.run() } catch { return nil }
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        if let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !errStr.isEmpty {
            fputs("debug: osascript error: \(errStr)\n", stderr)
        }
        return nil
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Check if Ghostty AppleScript API is available (1.3+)
private func asAvailable() -> Bool {
    return runAS("tell application \"Ghostty\" to get version") != nil
}

/// Get all Ghostty terminal UUIDs with their titles via AppleScript
private func asListTerminals() -> [(uuid: String, name: String)] {
    // Get IDs and names in parallel — AppleScript returns comma-separated lists
    guard let idsRaw = runAS("tell application \"Ghostty\" to get id of every terminal"),
          let namesRaw = runAS("tell application \"Ghostty\" to get name of every terminal") else {
        return []
    }
    let ids = idsRaw.components(separatedBy: ", ")
    let names = namesRaw.components(separatedBy: ", ")
    guard ids.count == names.count else { return [] }
    return zip(ids, names).map { (uuid: $0, name: $1) }
}

/// Get all windows' terminal UUIDs, grouped by window, in order.
/// Returns array of arrays: [[window0_terminals], [window1_terminals], ...]
/// No title matching — pure ordinal, avoids spinner/focus title-shift issues.
/// Returns [(windowName, [terminalUUIDs])] — one entry per window, terminals across ALL tabs.
private func asAllWindowTerminals() -> [(name: String, uuids: [String])] {
    guard let result = runAS("""
        tell application "Ghostty"
            set output to ""
            repeat with w in every window
                set wName to name of w
                set output to output & wName & "\\t"
                set allTerms to {}
                repeat with t in every tab of w
                    set allTerms to allTerms & (id of every terminal of t)
                end repeat
                repeat with i from 1 to count of allTerms
                    set output to output & item i of allTerms
                    if i < count of allTerms then set output to output & ","
                end repeat
                set output to output & "\\n"
            end repeat
            return output
        end tell
    """), !result.isEmpty else { return [] }

    // Parse "windowName\tuuid1,uuid2\nwindowName2\tuuid3\n..." into [(name, [uuid])]
    return result.components(separatedBy: "\n")
        .filter { !$0.isEmpty }
        .compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return (name: parts[0], uuids: parts[1].components(separatedBy: ","))
        }
}

/// Get terminal UUIDs for a specific window across all tabs, in order.
/// Returns UUIDs in the same order AS enumerates them (should match AX surface order).
private func asTerminalsForWindow(title: String) -> [String] {
    // Strip leading spinner/braille chars for stable matching — spinners rotate between
    // AX enumeration and AS enumeration, causing exact match to fail
    let stableTitle = title.drop(while: { !$0.isASCII || $0.isWhitespace })
    let escaped = String(stableTitle).replacingOccurrences(of: "\\", with: "\\\\")
                                      .replacingOccurrences(of: "\"", with: "\\\"")
    guard !escaped.isEmpty else { return [] }

    // Use `contains` instead of `is` — spinner prefix changes between calls
    guard let result = runAS("""
        tell application "Ghostty"
            repeat with w in every window
                if name of w contains "\(escaped)" then
                    set allTerms to {}
                    repeat with t in every tab of w
                        set allTerms to allTerms & (id of every terminal of t)
                    end repeat
                    set output to ""
                    repeat with i from 1 to count of allTerms
                        set output to output & item i of allTerms
                        if i < count of allTerms then set output to output & ","
                    end repeat
                    return output
                end if
            end repeat
            return ""
        end tell
    """), !result.isEmpty else {
        return []
    }
    return result.components(separatedBy: ",")
}

/// Send text to a terminal by UUID via AppleScript. No clipboard, no focus raise.
@discardableResult
private func asSendText(_ uuid: String, _ text: String) -> Bool {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                      .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "tell application \"Ghostty\" to input text \"\(escaped)\" to terminal id \"\(uuid)\""
    return runAS(script) != nil
}

/// Send a key event to a terminal by UUID via AppleScript. No focus raise.
@discardableResult
private func asSendKey(_ uuid: String, _ key: String) -> Bool {
    let script = "tell application \"Ghostty\" to send key \"\(key)\" to terminal id \"\(uuid)\""
    return runAS(script) != nil
}

/// Close a terminal by UUID via AppleScript. Idempotent.
private func asCloseTerminal(_ uuid: String) -> Bool {
    let script = "tell application \"Ghostty\" to close terminal id \"\(uuid)\""
    return runAS(script) != nil
}

/// Split a terminal by UUID via AppleScript. Returns new terminal's UUID.
/// direction: "right", "left", "down", "up"
/// New pane inherits parent's cwd by default (Ghostty behavior).
private func asSplitTerminal(_ uuid: String, direction: String) -> String? {
    let script = """
    tell application "Ghostty"
        set newTerm to split terminal id "\(uuid)" direction \(direction)
        get id of newTerm
    end tell
    """
    return runAS(script)
}

/// Get the focused terminal's UUID
private func asFocusedTerminalUUID() -> String? {
    return runAS("""
        tell application "Ghostty"
            get id of focused terminal of selected tab of front window
        end tell
    """)
}

/// Get all terminal UUIDs as a flat set.
private func asAllTerminalUUIDs() -> Set<String> {
    return Set(asAllWindowTerminals().flatMap { $0.uuids })
}

/// Detect a newly created terminal by diffing UUIDs before and after a window-creation action.
/// Polls until a new UUID appears that wasn't in `before`, or times out.
private func awaitNewTerminal(before: Set<String>, attempts: Int = 15, delayMicros: useconds_t = 100_000) -> String? {
    for _ in 0..<attempts {
        let after = asAllTerminalUUIDs()
        let newUUIDs = after.subtracting(before)
        if let uuid = newUUIDs.first { return uuid }
        usleep(delayMicros)
    }
    return nil
}

/// Check if a UUID looks like a Ghostty terminal UUID (standard UUID format)
private func isUUID(_ s: String) -> Bool {
    let parts = s.split(separator: "-")
    return parts.count == 5 && s.count >= 32
}

// MARK: - Pane Discovery

struct Pane {
    let textArea: AXUIElement
    let position: String  // "main", "left", "right", "top", "bottom", "left/top", etc.
}

/// Recursively discover terminal panes (text areas) within a window's content area.
/// Handles single panes, horizontal/vertical splits, and nested splits.
///
/// Ghostty's AX tree has two split patterns:
///   1. Explicit: AXGroup desc="Vertical split view" > AXGroup desc="Top pane", "Bottom pane"
///   2. Nested:   AXGroup desc="Bottom pane" > AXGroup desc="Left pane", "Right pane"
///      (no intermediate "split view" wrapper — the pane IS the container)
/// We detect both by looking for groups with multiple "pane" children.
private func discoverPanes(_ el: AXUIElement, prefix: String = "", depth: Int = 0) -> [Pane] {
    guard depth < 15 else { return [] }

    let children = axChildren(el)

    // 1. Check for explicit "split view" container
    for child in children {
        let role: String? = ax(child, kAXRoleAttribute as String)
        let desc: String = ax(child, kAXDescriptionAttribute as String) ?? ""
        if role == kAXGroupRole as String && desc.lowercased().contains("split view") {
            let panes = collectPaneChildren(child, prefix: prefix, depth: depth)
            if !panes.isEmpty { return panes }
        }
    }

    // 2. Check if this element itself is a nested split container
    //    (a pane group whose children include multiple sub-panes, without a "split view" wrapper)
    let paneChildren = children.filter { child in
        let role: String? = ax(child, kAXRoleAttribute as String)
        let desc: String = ax(child, kAXDescriptionAttribute as String) ?? ""
        return role == kAXGroupRole as String && desc.lowercased().contains("pane")
    }
    if paneChildren.count > 1 {
        let panes = collectPaneChildren(el, prefix: prefix, depth: depth)
        if !panes.isEmpty { return panes }
    }

    // 3. Found a text area directly (single pane / leaf)
    for child in children {
        let role: String? = ax(child, kAXRoleAttribute as String)
        if role == kAXTextAreaRole as String {
            return [Pane(textArea: child, position: prefix.isEmpty ? "main" : prefix)]
        }
    }

    // 4. Recurse into wrapper groups (e.g. AXHostingView, AXScrollArea added in Ghostty 1.3)
    for child in children {
        let role: String? = ax(child, kAXRoleAttribute as String)
        if role == kAXGroupRole as String || role == "AXScrollArea" {
            let result = discoverPanes(child, prefix: prefix, depth: depth + 1)
            if !result.isEmpty { return result }
        }
    }

    return []
}

/// Collect pane children from a split container and recurse into each.
/// Works for both explicit "split view" groups and pane groups with nested sub-panes.
private func collectPaneChildren(_ container: AXUIElement, prefix: String, depth: Int) -> [Pane] {
    var panes: [Pane] = []
    for child in axChildren(container) {
        let childDesc: String = ax(child, kAXDescriptionAttribute as String) ?? ""
        if childDesc.lowercased().contains("pane") {
            let pos = extractPosition(childDesc)
            let fullPos = prefix.isEmpty ? pos : "\(prefix)/\(pos)"
            let nested = discoverPanes(child, prefix: fullPos, depth: depth + 1)
            if nested.isEmpty {
                // Leaf pane — find its text area directly
                if let ta = findFirstTextArea(child, depth: 0) {
                    panes.append(Pane(textArea: ta, position: fullPos))
                }
            } else {
                panes += nested
            }
        }
    }
    return panes
}

/// Extract position name from AX description: "Left pane" -> "left", "Right pane" -> "right"
private func extractPosition(_ desc: String) -> String {
    let lower = desc.lowercased()
    for keyword in ["left", "right", "top", "bottom"] {
        if lower.contains(keyword) { return keyword }
    }
    return "pane"
}

/// Find first AXTextArea in a subtree (for leaf panes)
private func findFirstTextArea(_ el: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth < 10 else { return nil }
    let role: String? = ax(el, kAXRoleAttribute as String)
    if role == kAXTextAreaRole as String { return el }
    for child in axChildren(el) {
        if let found = findFirstTextArea(child, depth: depth + 1) { return found }
    }
    return nil
}

// MARK: - Surface Discovery

enum SurfaceKind {
    case tab
    case splitPane(position: String)
}

struct Surface {
    let window: AXUIElement
    let tabButton: AXUIElement?   // nil if single-tab or no tab bar
    let textArea: AXUIElement?    // direct reference; nil only for inactive tabs
    let title: String
    let index: Int
    let isActive: Bool            // whether this tab is currently selected
    let windowIndex: Int          // which window this surface belongs to
    let kind: SurfaceKind
    let windowID: CGWindowID?     // stable CGWindowID — doesn't change when title changes

    /// Display title including split position label
    var displayTitle: String {
        switch kind {
        case .tab: return title
        case .splitPane(let pos): return "\(title) [\(pos)]"
        }
    }
}

private func findGhosttyPID() -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first { $0.bundleIdentifier == "com.mitchellh.ghostty" }?
        .processIdentifier
}

/// Global flag: when true, operate across all windows (--all flag)
private var scopeAllWindows = false
/// Explicit window scope: match by title substring (--window flag or GX_WINDOW env)
private var windowScope: String? = nil

/// Find the window matching the scope — by index (e.g. "0") or title substring.
private func findScopedWindow(_ app: AXUIElement, _ scope: String) -> AXUIElement? {
    let allWindows: [AXUIElement] = sortedWindows(ax(app, kAXWindowsAttribute as String) ?? [])
    // Try numeric index first
    if let idx = Int(scope), idx >= 0, idx < allWindows.count {
        return allWindows[idx]
    }
    // Fall back to title substring
    return allWindows.first { win in
        let title: String = ax(win, kAXTitleAttribute as String) ?? ""
        return title.localizedCaseInsensitiveContains(scope)
    }
}

/// Sort windows by CGWindowID for stable indexing.
/// CGWindowID is a monotonic counter assigned at window creation — doesn't change
/// with title, focus, or position. Falls back to position for windows without an ID.
private func sortedWindows(_ windows: [AXUIElement]) -> [AXUIElement] {
    windows.sorted { w1, w2 in
        let id1 = cgWindowID(w1) ?? UInt32.max
        let id2 = cgWindowID(w2) ?? UInt32.max
        return id1 < id2
    }
}

/// Find surfaces, scoped to the current window by default.
/// Priority: --all > --window/GX_WINDOW > AXFocusedWindow > all
private func findSurfaces() -> (pid_t, [Surface])? {
    guard let pid = findGhosttyPID() else {
        fputs("error: Ghostty not running\n", stderr)
        return nil
    }

    let app = AXUIElementCreateApplication(pid)
    let windows: [AXUIElement]

    if scopeAllWindows {
        windows = sortedWindows(ax(app, kAXWindowsAttribute as String) ?? [])
    } else if let scope = windowScope {
        if let win = findScopedWindow(app, scope) {
            windows = [win]
        } else {
            fputs("error: no window matching '\(scope)'\n", stderr)
            return nil
        }
    } else {
        // Fallback: focused window, or all if none focused
        let focused: AXUIElement? = ax(app, kAXFocusedWindowAttribute as String)
        windows = focused.map { [$0] } ?? sortedWindows(ax(app, kAXWindowsAttribute as String) ?? [])
    }

    var surfaces: [Surface] = []

    for (winIdx, win) in windows.enumerated() {
        let winTitle: String = ax(win, kAXTitleAttribute as String) ?? ""
        let wid = cgWindowID(win)

        // Find the tab group to enumerate all tabs
        var tabButtons: [AXUIElement] = []
        findTabButtons(win, &tabButtons, 0)

        if tabButtons.isEmpty {
            // No tab bar — discover panes directly
            let panes = discoverPanes(win)
            if panes.count <= 1 {
                // Single pane (or no pane found)
                let ta = panes.first?.textArea
                surfaces.append(Surface(window: win, tabButton: nil, textArea: ta, title: winTitle,
                                        index: surfaces.count, isActive: true, windowIndex: winIdx, kind: .tab, windowID: wid))
            } else {
                // Multiple split panes
                for pane in panes {
                    surfaces.append(Surface(window: win, tabButton: nil, textArea: pane.textArea, title: winTitle,
                                            index: surfaces.count, isActive: true, windowIndex: winIdx,
                                            kind: .splitPane(position: pane.position), windowID: wid))
                }
            }
        } else {
            // Has tabs — find which is active, discover panes for active tab
            for btn in tabButtons {
                let title: String = ax(btn, kAXTitleAttribute as String) ?? ""
                let isSelected: Bool = {
                    let val: AnyObject? = ax(btn, kAXValueAttribute as String)
                    return val?.intValue == 1
                }()

                if isSelected {
                    // Active tab — discover its panes (splits are visible)
                    let panes = discoverPanes(win)
                    if panes.count <= 1 {
                        let ta = panes.first?.textArea
                        surfaces.append(Surface(window: win, tabButton: btn, textArea: ta, title: title,
                                                index: surfaces.count, isActive: true, windowIndex: winIdx, kind: .tab, windowID: wid))
                    } else {
                        for pane in panes {
                            surfaces.append(Surface(window: win, tabButton: btn, textArea: pane.textArea, title: title,
                                                    index: surfaces.count, isActive: true, windowIndex: winIdx,
                                                    kind: .splitPane(position: pane.position), windowID: wid))
                        }
                    }
                } else {
                    // Inactive tab — text area not in AX tree
                    surfaces.append(Surface(window: win, tabButton: btn, textArea: nil, title: title,
                                            index: surfaces.count, isActive: false, windowIndex: winIdx, kind: .tab, windowID: wid))
                }
            }
        }
    }
    return (pid, surfaces)
}

/// Walk AX tree to find tab buttons (AXRadioButton with AXTabButton subrole)
private func findTabButtons(_ el: AXUIElement, _ results: inout [AXUIElement], _ depth: Int) {
    guard depth < 10 else { return }
    let role: String? = ax(el, kAXRoleAttribute as String)
    let subrole: String? = ax(el, kAXSubroleAttribute as String)

    if role == kAXRadioButtonRole as String && subrole == "AXTabButton" {
        results.append(el)
        return
    }

    for child in axChildren(el) {
        findTabButtons(child, &results, depth + 1)
    }
}

/// Find the currently active tab button in a window
private func findActiveTabButton(_ win: AXUIElement) -> AXUIElement? {
    var buttons: [AXUIElement] = []
    findTabButtons(win, &buttons, 0)
    return buttons.first { btn in
        let val: AnyObject? = ax(btn, kAXValueAttribute as String)
        return val?.intValue == 1
    }
}

/// Check if a tab button is currently selected (AXValue == 1)
private func isTabSelected(_ btn: AXUIElement) -> Bool {
    let val: AnyObject? = ax(btn, kAXValueAttribute as String)
    return val?.intValue == 1
}

/// Resolve a Ghostty terminal UUID to an AX surface.
/// Asks AS which window contains the UUID and its position, then matches to AX by window order + position.
private func resolveUUID(_ uuid: String, pid: pid_t, surfaces: [Surface]) -> Surface? {
    // Ask AppleScript: which window has this UUID, and what position is it in?
    // Returns "asWindowIndex:posInWindow:totalTerminals" (1-based)
    guard let result = runAS("""
        tell application "Ghostty"
            set wIdx to 0
            repeat with w in every window
                set wIdx to wIdx + 1
                set tIds to {}
                repeat with t in every tab of w
                    set tIds to tIds & (id of every terminal of t)
                end repeat
                repeat with i from 1 to count of tIds
                    if item i of tIds is "\(uuid)" then
                        return (wIdx as text) & ":" & (i as text) & ":" & ((count of tIds) as text)
                    end if
                end repeat
            end repeat
            return ""
        end tell
    """), !result.isEmpty else { return nil }

    let parts = result.components(separatedBy: ":")
    guard parts.count == 3,
          let asWinIdx = Int(parts[0]),  // 1-based AS window index
          let posInWin = Int(parts[1]),  // 1-based position within window
          let totalTerminals = Int(parts[2]),
          asWinIdx > 0, posInWin > 0 else { return nil }

    // Group AX surfaces by windowIndex, sorted
    var windowSurfaces: [Int: [Surface]] = [:]
    for s in surfaces { windowSurfaces[s.windowIndex, default: []].append(s) }
    let sortedWindowKeys = windowSurfaces.keys.sorted()

    // Match AX window by: same number of surfaces as AS terminals in that window.
    // Among windows with the right count, prefer the one at the same ordinal position.
    // This handles the common case (each window has a unique pane count) robustly.
    let zeroPos = posInWin - 1

    // Try ordinal match first (AS window N → AX window N)
    if asWinIdx - 1 < sortedWindowKeys.count {
        let axKey = sortedWindowKeys[asWinIdx - 1]
        if let winSurfaces = windowSurfaces[axKey],
           winSurfaces.count == totalTerminals,
           zeroPos < winSurfaces.count {
            return winSurfaces[zeroPos]
        }
    }

    // Fallback: find any AX window with matching terminal count
    for key in sortedWindowKeys {
        if let winSurfaces = windowSurfaces[key],
           winSurfaces.count == totalTerminals,
           zeroPos < winSurfaces.count {
            return winSurfaces[zeroPos]
        }
    }

    return nil
}

private func resolveSurface(_ id: String) -> (pid_t, Surface)? {
    // Special "focused" pseudo-ID — resolve to the focused terminal
    if id == "focused" {
        guard let (pid, surfaces) = findSurfaces() else { return nil }
        if let focused = surfaces.first(where: { $0.isActive }) {
            return (pid, focused)
        }
        if let first = surfaces.first { return (pid, first) }
        fputs("error: no surfaces found\n", stderr)
        return nil
    }

    // UUID: Ghostty terminal UUID (from AppleScript split)
    if isUUID(id) {
        guard let (pid, surfaces) = findSurfaces() else { return nil }
        if let match = resolveUUID(id, pid: pid, surfaces: surfaces) {
            return (pid, match)
        }
        fputs("error: no surface matching UUID '\(id)'\n", stderr)
        fputs("hint: terminal may have been closed\n", stderr)
        return nil
    }

    guard let (pid, surfaces) = findSurfaces() else { return nil }

    // Stable window ID: w<CGWindowID> (e.g. "w1234")
    if id.hasPrefix("w"), let wid = UInt32(id.dropFirst()) {
        if let match = surfaces.first(where: { $0.windowID == wid }) {
            return (pid, match)
        }
        fputs("error: no surface with window ID \(wid)\n", stderr)
        fputs("hint: re-run 'gx \(scopeAllWindows ? "--all " : "")list' to see current IDs\n", stderr)
        return nil
    }

    // Numeric index
    if let idx = Int(id) {
        if idx >= 0 && idx < surfaces.count {
            return (pid, surfaces[idx])
        }
        fputs("error: surface index \(idx) out of range (found \(surfaces.count) surfaces)\n", stderr)
        fputs("hint: re-run 'gx \(scopeAllWindows ? "--all " : "")list' to see current indices\n", stderr)
        return nil
    }

    // Title substring match
    if let match = surfaces.first(where: { $0.displayTitle.localizedCaseInsensitiveContains(id) }) {
        return (pid, match)
    }

    fputs("error: surface '\(id)' not found\n", stderr)
    return nil
}

// MARK: - Text Content Reading

/// Find the pane matching a surface's split position, falling back to .first for non-split surfaces.
private func findMatchingPane(_ panes: [Pane], for surface: Surface) -> Pane? {
    if case .splitPane(let pos) = surface.kind {
        return panes.first(where: { $0.position == pos }) ?? panes.first
    }
    return panes.first
}

/// Read text content from a surface. Uses stored textArea when available (no tree walk, no tab switch).
/// Falls back to tab switching for inactive tabs.
private func peekTextContent(_ surface: Surface) -> String? {
    // Fast path: text area already captured at discovery time
    if let ta = surface.textArea {
        if let text: String = ax(ta, kAXValueAttribute as String) {
            return text
        }
        // Stale reference — fall through to re-discover
    }

    // No stored text area — either inactive tab or stale reference
    // For non-tab surfaces without textArea, retry discovery (AX tree may be delayed for new windows)
    if surface.tabButton == nil {
        for _ in 0..<5 {
            let panes = discoverPanes(surface.window)
            if let match = findMatchingPane(panes, for: surface) {
                return ax(match.textArea, kAXValueAttribute as String)
            }
            usleep(200_000)
        }
        return nil
    }

    // Inactive tab — must switch tabs
    // Snapshot a fingerprint of the current content so we can detect the swap
    let preSwitch = findMatchingPane(discoverPanes(surface.window), for: surface)?.textArea
    let preFingerprint: String? = preSwitch.flatMap { ta in
        guard let val: String = ax(ta, kAXValueAttribute as String) else { return nil }
        // Use last 200 chars as fingerprint — cheap and unique per tab
        return String(val.suffix(200))
    }

    let previousTab = findActiveTabButton(surface.window)
    axPerform(surface.tabButton!, kAXPressAction as String)

    // Poll until the target tab reports as selected (up to 500ms)
    var tabActivated = false
    for _ in 0..<10 {
        usleep(50_000)
        if isTabSelected(surface.tabButton!) {
            tabActivated = true
            break
        }
    }

    // After activation, poll until the text area content actually changes (up to 500ms)
    // Ghostty reuses the same AXTextArea element — it swaps content backing in-place
    var text: String?
    if tabActivated {
        for attempt in 0..<10 {
            usleep(50_000)
            let panes = discoverPanes(surface.window)
            if let match = findMatchingPane(panes, for: surface) {
                let content: String? = ax(match.textArea, kAXValueAttribute as String)
                let newFingerprint = content.flatMap { String($0.suffix(200)) }
                // Accept if: no pre-switch fingerprint, content changed, or last attempt
                if preFingerprint == nil || newFingerprint != preFingerprint || attempt == 9 {
                    text = content
                    break
                }
            }
        }
    }

    // Always switch back
    if let prev = previousTab {
        axPerform(prev, kAXPressAction as String)
    }

    return text
}

// MARK: - Key Events

private let kVK_Return:    CGKeyCode = 0x24
private let kVK_Escape:    CGKeyCode = 0x35
private let kVK_Tab:       CGKeyCode = 0x30
private let kVK_Delete:    CGKeyCode = 0x33
private let kVK_Space:     CGKeyCode = 0x31
private let kVK_ANSI_C:    CGKeyCode = 0x08
private let kVK_ANSI_W:    CGKeyCode = 0x0D
private let kVK_ANSI_N:    CGKeyCode = 0x2D
private let kVK_ANSI_T:    CGKeyCode = 0x11
/// Virtual key codes for digit keys 0-9 (macOS ANSI layout, non-sequential)
private let digitKeyCodes: [CGKeyCode] = [
    0x1D, // 0
    0x12, // 1
    0x13, // 2
    0x14, // 3
    0x15, // 4
    0x17, // 5
    0x16, // 6
    0x1A, // 7
    0x1C, // 8
    0x19, // 9
]

private func postKey(_ pid: pid_t, _ vk: CGKeyCode, _ flags: CGEventFlags = []) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    down.postToPid(pid)
    up.postToPid(pid)
    usleep(10_000)
}

/// Execute an action on a surface, then restore the user's focused window and active tab.
/// Raises the target window so CGEvent key posts reach the right surface.
private func withFocus(_ pid: pid_t, _ surface: Surface, action: () -> Void) {
    let app = AXUIElementCreateApplication(pid)
    let previousWindow: AXUIElement? = ax(app, kAXFocusedWindowAttribute as String)

    // Raise target window — CGEvent.postToPid delivers to the focused window
    axPerform(surface.window, kAXRaiseAction as String)
    usleep(100_000)

    let previousTab = findActiveTabButton(surface.window)
    let needSwitch = !surface.isActive && surface.tabButton != nil

    if needSwitch {
        axPerform(surface.tabButton!, kAXPressAction as String)
        usleep(150_000)
    }

    // Focus the specific text area (split-aware)
    if let ta = surface.textArea {
        AXUIElementSetAttributeValue(ta, kAXFocusedAttribute as CFString, true as CFBoolean)
    } else if let ta = findFirstTextArea(surface.window, depth: 0) {
        AXUIElementSetAttributeValue(ta, kAXFocusedAttribute as CFString, true as CFBoolean)
    }
    usleep(50_000)

    action()

    if needSwitch, let prev = previousTab {
        axPerform(prev, kAXPressAction as String)
    }

    // Restore the user's original focused window
    if let prevWin = previousWindow {
        usleep(50_000)
        axPerform(prevWin, kAXRaiseAction as String)
    }
}

// MARK: - Peek Range

enum PeekRange {
    case tail(Int)                // last N lines (default)
    case head(Int)                // first N lines from top (+N)
    case tailSlice(Int, Int)      // lines M-N from bottom
}

private func parsePeekRange(_ arg: String) -> PeekRange {
    // +N: first N lines from top
    if arg.hasPrefix("+") {
        let rest = String(arg.dropFirst())
        if let n = Int(rest), n > 0 { return .head(n) }
        fputs("warning: invalid range '+\(rest)' — using default (last 30 lines)\n", stderr)
        return .tail(30)
    }
    // M-N: lines M to N from the bottom
    if arg.contains("-") && !arg.hasPrefix("-") {
        let parts = arg.split(separator: "-", maxSplits: 1)
        if parts.count == 2, let m = Int(parts[0]), let n = Int(parts[1]) {
            if m >= n {
                fputs("warning: invalid range '\(arg)' (start must be less than end) — using default (last 30 lines)\n", stderr)
                return .tail(30)
            }
            return .tailSlice(m, n)
        }
        fputs("warning: invalid range '\(arg)' — using default (last 30 lines)\n", stderr)
        return .tail(30)
    }
    // Plain number: last N lines
    if let n = Int(arg) {
        return .tail(max(0, n))
    }
    fputs("warning: invalid range '\(arg)' — using default (last 30 lines)\n", stderr)
    return .tail(30)
}

private func applyRange(_ lines: [String], _ range: PeekRange) -> ArraySlice<String> {
    switch range {
    case .tail(let n):
        let start = max(0, lines.count - n)
        return lines[start...]
    case .head(let n):
        return lines[..<min(n, lines.count)]
    case .tailSlice(let from, let to):
        // from=50, to=100 means lines [count-100 ..< count-50] from bottom
        let end = max(0, lines.count - from)
        let start = max(0, lines.count - to)
        if start >= end { return lines[0..<0] }
        return lines[start..<end]
    }
}

// MARK: - UUID Resolution

/// Strip leading spinner/braille chars for stable title matching.
/// Spinners rotate between AX and AS enumeration, so exact prefix match fails.
private func stableWindowTitle(_ title: String) -> String {
    String(title.drop(while: { !$0.isASCII || $0.isWhitespace }).drop(while: { $0.isWhitespace }))
}

/// Build a map from surface index → terminal UUID using window-name correlation.
/// Matches AX windows to AS windows by title (stripping spinner prefixes),
/// then assigns UUIDs by surface order within each window.
private func buildUUIDMap(surfaces: [Surface]) -> [Int: String] {
    let asWindows = asAllWindowTerminals()

    // Group surfaces by windowIndex
    var windowSurfaces: [Int: [Surface]] = [:]
    for s in surfaces { windowSurfaces[s.windowIndex, default: []].append(s) }

    // Get the AX window title for each window group (from the first surface or the window element)
    var windowTitles: [Int: String] = [:]
    for (winIdx, winSurfaces) in windowSurfaces {
        if let firstSurface = winSurfaces.first {
            let axTitle: String = ax(firstSurface.window, kAXTitleAttribute as String) ?? ""
            windowTitles[winIdx] = axTitle
        }
    }

    var uuidMap: [Int: String] = [:]
    var usedASWindows: Set<Int> = []

    // Match by title: for each AX window, find the AS window with the best title match
    for (winIdx, winSurfaces) in windowSurfaces {
        let axTitle = stableWindowTitle(windowTitles[winIdx] ?? "")
        guard !axTitle.isEmpty else { continue }

        for (asIdx, asWin) in asWindows.enumerated() {
            guard !usedASWindows.contains(asIdx) else { continue }
            let asTitle = stableWindowTitle(asWin.name)
            // Match: title contains (spinner-stripped) and terminal count matches surface count
            if asTitle.contains(axTitle) || axTitle.contains(asTitle),
               asWin.uuids.count == winSurfaces.count {
                usedASWindows.insert(asIdx)
                for (i, s) in winSurfaces.enumerated() {
                    uuidMap[s.index] = asWin.uuids[i]
                }
                break
            }
        }
    }

    // Fallback: any unmatched windows, try count-based matching (legacy behavior)
    let unmatchedAX = windowSurfaces.keys.filter { winIdx in
        windowSurfaces[winIdx]?.first.map({ uuidMap[$0.index] == nil }) ?? false
    }
    for winIdx in unmatchedAX {
        guard let winSurfaces = windowSurfaces[winIdx] else { continue }
        for (asIdx, asWin) in asWindows.enumerated() {
            guard !usedASWindows.contains(asIdx),
                  asWin.uuids.count == winSurfaces.count else { continue }
            usedASWindows.insert(asIdx)
            for (i, s) in winSurfaces.enumerated() {
                uuidMap[s.index] = asWin.uuids[i]
            }
            break
        }
    }

    return uuidMap
}

/// Resolve any target ID to a Ghostty terminal UUID.
/// Always searches all windows — UUID resolution is scope-independent.
private func resolveToUUID(_ id: String) -> String? {
    if isUUID(id) { return id }
    if id == "focused" { return asFocusedTerminalUUID() }

    // Search all windows regardless of --all/--window flags
    let savedScope = scopeAllWindows
    let savedWindow = windowScope
    scopeAllWindows = true
    windowScope = nil
    let result = findSurfaces()
    scopeAllWindows = savedScope
    windowScope = savedWindow

    guard let (_, surfaces) = result else { return nil }
    let surface: Surface?
    if id.hasPrefix("w"), let wid = UInt32(id.dropFirst()) {
        surface = surfaces.first(where: { $0.windowID == wid })
    } else if let idx = Int(id), idx >= 0, idx < surfaces.count {
        surface = surfaces[idx]
    } else {
        surface = surfaces.first(where: { $0.displayTitle.localizedCaseInsensitiveContains(id) })
    }
    guard let surface = surface else { return nil }
    return buildUUIDMap(surfaces: surfaces)[surface.index]
}

// MARK: - Commands

private func cmdFocused() {
    guard let pid = findGhosttyPID() else { fputs("error: Ghostty not running\n", stderr); exit(1) }
    let app = AXUIElementCreateApplication(pid)
    guard let win: AXUIElement = ax(app, kAXFocusedWindowAttribute as String) else {
        fputs("error: no focused window\n", stderr); exit(1)
    }
    let allWindows = sortedWindows(ax(app, kAXWindowsAttribute as String) ?? [])
    var winIndex = 0
    let fTitle: String = ax(win, kAXTitleAttribute as String) ?? ""
    let (fx, fy) = axPosition(win)
    for (i, w) in allWindows.enumerated() {
        let wTitle: String = ax(w, kAXTitleAttribute as String) ?? ""
        let (wx, wy) = axPosition(w)
        if wTitle == fTitle && wx == fx && wy == fy { winIndex = i; break }
    }
    print(winIndex)
}

private func cmdList() {
    guard let (_, surfaces) = findSurfaces() else { exit(1) }
    if surfaces.isEmpty { print("no surfaces found"); return }

    let uuidMap = buildUUIDMap(surfaces: surfaces)

    var lastWin = -1
    for s in surfaces {
        if scopeAllWindows && s.windowIndex != lastWin {
            if lastWin >= 0 { print() }
            let winTitle: String = ax(s.window, kAXTitleAttribute as String) ?? "window \(s.windowIndex)"
            let widStr = s.windowID.map { "w\($0)" } ?? "w?"
            print("── window \(s.windowIndex): \(winTitle) [\(widStr)] ──")
            lastWin = s.windowIndex
        }
        let active = s.isActive ? "*" : " "
        let uuid = uuidMap[s.index] ?? "?"
        print("\(s.index)\t\(active)\t\(s.displayTitle)\t\(uuid)")
    }
}

private func cmdPeek(_ id: String, _ range: PeekRange) {
    guard let (_, surface) = resolveSurface(id) else { exit(1) }

    guard let text = peekTextContent(surface) else {
        fputs("error: cannot read text from surface '\(id)'\n", stderr)
        fputs("try: gx dump\n", stderr)
        exit(1)
    }

    let all = text.components(separatedBy: "\n")
    for line in applyRange(all, range) { print(line) }
}

private func cmdSend(_ id: String, _ text: String, enter: Bool) {
    guard let uuid = resolveToUUID(id) else {
        fputs("error: could not resolve '\(id)' to a terminal UUID\n", stderr)
        exit(1)
    }
    var ok = true
    if !text.isEmpty, !asSendText(uuid, text) { ok = false }
    if enter, !asSendKey(uuid, "enter") { ok = false }
    if !ok { fputs("warning: AppleScript send may have partially failed\n", stderr) }
    print("sent \(id)\(enter ? "" : " (no enter)")")
}

private func cmdKey(_ id: String, _ keyName: String) {
    guard let (pid, surface) = resolveSurface(id) else { exit(1) }

    withFocus(pid, surface) {
        switch keyName.lowercased() {
        case "enter", "return":     postKey(pid, kVK_Return)
        case "escape", "esc":       postKey(pid, kVK_Escape)
        case "ctrl-c":              postKey(pid, kVK_ANSI_C, .maskControl)
        case "tab":                 postKey(pid, kVK_Tab)
        case "backspace", "delete": postKey(pid, kVK_Delete)
        case "space":               postKey(pid, kVK_Space)
        default:
            fputs("unknown key '\(keyName)' — supported: enter, escape, ctrl-c, tab, backspace, space\n", stderr)
            exit(1)
        }
    }
}

private func cmdApprove(_ id: String, _ option: Int) {
    guard let (pid, surface) = resolveSurface(id) else { exit(1) }
    guard option >= 1, option <= 9 else {
        fputs("error: option \(option) out of range (1-9)\n", stderr)
        exit(1)
    }

    withFocus(pid, surface) {
        postKey(pid, digitKeyCodes[option])
        usleep(50_000)
        postKey(pid, kVK_Return)
    }
    print("approved \(id) option=\(option)")
}

private func cmdDeny(_ id: String) {
    guard let (pid, surface) = resolveSurface(id) else { exit(1) }

    withFocus(pid, surface) {
        postKey(pid, digitKeyCodes[3])
        usleep(50_000)
        postKey(pid, kVK_Return)
    }
    print("denied \(id)")
}

private func cmdInterrupt(_ id: String) {
    guard let (pid, surface) = resolveSurface(id) else { exit(1) }

    withFocus(pid, surface) {
        postKey(pid, kVK_Escape)
        usleep(100_000)
        postKey(pid, kVK_ANSI_C, .maskControl)
        usleep(50_000)
        postKey(pid, kVK_ANSI_C, .maskControl)
    }
    print("interrupted \(id)")
}

private func cmdPeekAll(_ lines: Int) {
    guard let (_, surfaces) = findSurfaces() else { exit(1) }
    if surfaces.isEmpty { print("no surfaces found"); return }

    for s in surfaces {
        let active = s.isActive ? "*" : " "
        print("=== [\(s.index)] \(active) \(s.displayTitle) ===")
        if let text = peekTextContent(s) {
            let all = text.components(separatedBy: "\n")
            let start = max(0, all.count - lines)
            for line in all[start...] { print("  \(line)") }
        } else {
            print("  (unreadable)")
        }
        print()
    }
}

private func cmdSpawn(_ cwd: String?, _ cmd: String?) {
    guard let pid = findGhosttyPID() else { fputs("error: Ghostty not running\n", stderr); exit(1) }

    let before = asAllTerminalUUIDs()

    // Cmd+N sends "new window" to the running Ghostty instance.
    // Using `open -a` without `-n` doesn't create windows; using `-na` creates a second app instance.
    postKey(pid, kVK_ANSI_N, .maskCommand)
    usleep(500_000)

    guard let uuid = awaitNewTerminal(before: before) else {
        fputs("error: new window created but could not detect new terminal UUID\n", stderr)
        exit(1)
    }

    if let cwd = cwd {
        asSendText(uuid, "cd \"\(cwd)\"")
        asSendKey(uuid, "enter")
        usleep(50_000)
    }
    if let cmd = cmd {
        usleep(100_000)
        asSendText(uuid, cmd)
        asSendKey(uuid, "enter")
    }

    print("spawned \(uuid)")
}

private func cmdNewTab(_ cwd: String?) {
    guard let pid = findGhosttyPID() else { fputs("error: Ghostty not running\n", stderr); exit(1) }

    let before = asAllTerminalUUIDs()
    postKey(pid, kVK_ANSI_T, .maskCommand)
    usleep(300_000)

    guard let uuid = awaitNewTerminal(before: before) else {
        fputs("error: new tab created but could not detect new terminal UUID\n", stderr)
        exit(1)
    }

    if let cwd = cwd {
        asSendText(uuid, "cd \"\(cwd)\"")
        asSendKey(uuid, "enter")
    }

    print("new tab \(uuid)")
}

private func cmdClose(_ id: String) {
    // Try AppleScript path for UUIDs
    if isUUID(id) {
        if asCloseTerminal(id) {
            print("closed \(id)")
            return
        }
        // Terminal might already be gone — that's OK (idempotent)
        print("closed \(id)")
        return
    }

    // AX fallback: focus + Cmd+W
    guard let (pid, surface) = resolveSurface(id) else { exit(1) }
    withFocus(pid, surface) {
        postKey(pid, kVK_ANSI_W, .maskCommand)
    }
    print("closed \(id)")
}

private func cmdSplit(_ id: String, vertical: Bool) {
    let direction = vertical ? "down" : "right"

    // Determine target UUID
    var targetUUID: String?
    if id == "focused" {
        targetUUID = asFocusedTerminalUUID()
    } else if isUUID(id) {
        targetUUID = id
    } else {
        // Resolve AX surface, then correlate to UUID using positional matching
        guard let (_, surfaces) = findSurfaces() else { exit(1) }
        guard let surface = (Int(id).flatMap({ idx in idx >= 0 && idx < surfaces.count ? surfaces[idx] : nil })
            ?? surfaces.first(where: { id.hasPrefix("w") ? $0.windowID.map({ "w\($0)" }) == id : false })
            ?? surfaces.first(where: { $0.displayTitle.localizedCaseInsensitiveContains(id) })) else {
            fputs("error: surface '\(id)' not found\n", stderr)
            exit(1)
        }

        // Group surfaces by window and find this surface's position within its window
        let winTitle: String = ax(surface.window, kAXTitleAttribute as String) ?? ""
        let winSurfaces = surfaces.filter { ax($0.window, kAXTitleAttribute as String) as String? == winTitle }
        let posInWindow = winSurfaces.firstIndex(where: { $0.index == surface.index }) ?? 0
        let uuids = asTerminalsForWindow(title: winTitle)

        if posInWindow < uuids.count {
            targetUUID = uuids[posInWindow]
        }
    }

    guard let uuid = targetUUID else {
        fputs("error: could not resolve target '\(id)' to a Ghostty terminal UUID\n", stderr)
        fputs("hint: ensure Ghostty 1.3+ with AppleScript enabled\n", stderr)
        exit(1)
    }

    // Split and get new terminal UUID (new pane inherits parent's cwd)
    guard let newUUID = asSplitTerminal(uuid, direction: direction) else {
        fputs("error: split failed — AppleScript returned an error\n", stderr)
        exit(1)
    }

    // Output in it2-compatible format
    print("Created new pane: \(newUUID)")
}

private func cmdDump(_ id: String?) {
    if let id = id, let (_, surface) = resolveSurface(id) {
        if let ta = surface.textArea {
            dumpTree(ta, 0)
        } else {
            // Inactive tab — switch, dump, switch back
            let needSwitch = !surface.isActive && surface.tabButton != nil
            var previousTab: AXUIElement?
            if needSwitch {
                previousTab = findActiveTabButton(surface.window)
                axPerform(surface.tabButton!, kAXPressAction as String)
                usleep(200_000)
            }
            dumpTree(surface.window, 0)
            if needSwitch, let prev = previousTab {
                axPerform(prev, kAXPressAction as String)
                usleep(100_000)
            }
        }
    } else {
        guard let pid = findGhosttyPID() else { fputs("Ghostty not running\n", stderr); exit(1) }
        dumpTree(AXUIElementCreateApplication(pid), 0)
    }
}

private func dumpTree(_ el: AXUIElement, _ depth: Int) {
    guard depth < 10 else { return }
    let pad = String(repeating: "  ", count: depth)
    let role: String = ax(el, kAXRoleAttribute as String) ?? "?"
    let subrole: String? = ax(el, kAXSubroleAttribute as String)
    let title: String? = ax(el, kAXTitleAttribute as String)
    let desc: String? = ax(el, kAXDescriptionAttribute as String)
    let val: String? = ax(el, kAXValueAttribute as String)

    var line = "\(pad)\(role)"
    if let s = subrole { line += " (\(s))" }
    if let t = title, !t.isEmpty { line += " title=\"\(t)\"" }
    if let d = desc, !d.isEmpty { line += " desc=\"\(d)\"" }
    if let v = val {
        let preview = String(v.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
        line += " value[\(v.count)ch]=\"\(preview)\""
    }
    print(line)

    for child in axChildren(el) { dumpTree(child, depth + 1) }
}

// MARK: - Main

private func checkAX() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(opts) {
        fputs("error: accessibility permission required\n", stderr)
        fputs("grant in: System Settings > Privacy & Security > Accessibility\n", stderr)
        exit(1)
    }
}

var rawArgs = Array(CommandLine.arguments.dropFirst())

// Parse global flags before command dispatch
if rawArgs.contains("--all") {
    scopeAllWindows = true
    rawArgs.removeAll { $0 == "--all" }
}
if let idx = rawArgs.firstIndex(of: "--window") {
    guard idx + 1 < rawArgs.count else {
        fputs("error: --window requires a value\n", stderr)
        exit(1)
    }
    windowScope = rawArgs[idx + 1]
    rawArgs.remove(at: idx + 1)
    rawArgs.remove(at: idx)
} else if let envScope = ProcessInfo.processInfo.environment["GX_WINDOW"] {
    windowScope = envScope
}

let args = rawArgs
if args.first == "--version" || args.first == "-V" {
    print("gx 1.3.2")
    exit(0)
}
guard let cmd = args.first, cmd != "help" && cmd != "--help" && cmd != "-h" else {
    print("""
    gx — Ghostty terminal control

    Usage: gx [--all] <command> [args]

    Commands:
      list                          List terminal surfaces (* = active tab)
      peek <id> [lines|range]       Read scrollback (default: last 30 lines)
      peek-all [lines]              Read all surfaces (default: 5 lines each)
      send <id> <text> [--no-enter] Send text (appends Enter by default)
      key <id> <keyname>            Send key (enter|escape|ctrl-c|tab|backspace|space)
      approve <id> [1-9]             Approve prompt (1=Yes, 2=Yes+always, 3=No)
      deny <id>                     Deny prompt (sends 3+Enter)
      interrupt <id>                Escape + Ctrl-C×2
      spawn [--cwd dir] [-e cmd]    Open new Ghostty window (clean env)
      new-tab [--cwd dir]           Open new tab in current window
      split <id> [-v|-h]             Split terminal (default: -h horizontal) [AS]
      close <id>                    Close terminal [AS for UUID, Cmd+W fallback]
      focused                       Print focused window index
      dump [id]                     Debug: dump accessibility tree

    Peek ranges:
      gx peek <id>                  Last 30 lines (default)
      gx peek <id> 100              Last 100 lines
      gx peek <id> +50              First 50 lines from top of scrollback
      gx peek <id> 50-100           Lines 50-100 from the bottom

    Flags:
      --window <title>              Scope to window matching title (or set GX_WINDOW env)
      --all                         Operate across all windows

    Split panes:
      Windows with splits show each pane as a separate surface with [position]:
        0  *  my-window [left]
        1  *  my-window [right]
      Each pane can be peeked, sent to, and focused independently.

    ID: numeric index, title substring, wNNNNN (window ID), UUID, or "focused".
    [AS] = uses Ghostty AppleScript API (1.3+), stable UUID targeting.
    All commands restore your active tab after acting on another.
    Scoped to current window by default. Use --all for cross-window operations.
    """)
    exit(0)
}

switch cmd {
case "spawn":
    checkAX()
    var cwd: String?; var c: String?; var i = 1
    while i < args.count {
        if args[i] == "--cwd", i + 1 < args.count { i += 1; cwd = args[i] }
        else if (args[i] == "--cmd" || args[i] == "-e"), i + 1 < args.count { i += 1; c = args[i] }
        i += 1
    }
    cmdSpawn(cwd, c)

case "new-tab":
    checkAX()
    var cwd: String?; var i = 1
    while i < args.count {
        if args[i] == "--cwd", i + 1 < args.count { i += 1; cwd = args[i] }
        i += 1
    }
    cmdNewTab(cwd)

case "split":
    checkAX()
    guard args.count > 1 else { fputs("usage: gx split <id> [-v|-h]\n", stderr); exit(1) }
    let vertical = args.contains("-v")
    cmdSplit(args[1], vertical: vertical)

case "list", "ls":
    checkAX()
    cmdList()

case "peek":
    checkAX()
    let id = args.count > 1 ? args[1] : "0"
    let range = args.count > 2 ? parsePeekRange(args[2]) : .tail(30)
    cmdPeek(id, range)

case "send":
    checkAX()
    guard args.count > 2 else { fputs("usage: gx send <id> <text>\n", stderr); exit(1) }
    let noEnter = args.contains("--no-enter")
    let textArgs = args[2...].filter { $0 != "--no-enter" }
    cmdSend(args[1], textArgs.joined(separator: " "), enter: !noEnter)

case "key":
    checkAX()
    guard args.count > 2 else { fputs("usage: gx key <id> <keyname>\n", stderr); exit(1) }
    cmdKey(args[1], args[2])

case "approve":
    checkAX()
    guard args.count > 1 else { fputs("usage: gx approve <id> [1-9]\n", stderr); exit(1) }
    if args.count > 2 {
        guard let option = Int(args[2]) else {
            fputs("error: option must be a number (1-9), got '\(args[2])'\n", stderr)
            exit(1)
        }
        cmdApprove(args[1], option)
    } else {
        cmdApprove(args[1], 1)
    }

case "deny":
    checkAX()
    guard args.count > 1 else { fputs("usage: gx deny <id>\n", stderr); exit(1) }
    cmdDeny(args[1])

case "interrupt":
    checkAX()
    guard args.count > 1 else { fputs("usage: gx interrupt <id>\n", stderr); exit(1) }
    cmdInterrupt(args[1])

case "peek-all":
    checkAX()
    let lines = args.count > 1 ? Int(args[1]) ?? 5 : 5
    cmdPeekAll(lines)

case "close":
    checkAX()
    guard args.count > 1 else { fputs("usage: gx close <id>\n", stderr); exit(1) }
    cmdClose(args[1])

case "focused":
    checkAX()
    cmdFocused()

case "dump":
    checkAX()
    cmdDump(args.count > 1 ? args[1] : nil)

default:
    fputs("error: unknown command '\(cmd)' — run 'gx' or 'gx help' for usage\n", stderr)
    exit(1)
}
