import CommonCrypto
import Foundation
@testable import SwitcherCore
import Testing

private let sampleConfig = """
{
\t"darkMode": "dark",
\t"oauth:tokenCache": "abc",
\t"nested": {
\t\t"a": [1, "}", {"b": "\\"x\\""}]
\t},
\t"oauth:tokenCacheV2": "djEw",
\t"lastKnownAccountUuid": "acct-1",
\t"tail": 0
}
"""

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "switcher-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Suite struct JSONObjectTextTests {
    @Test func readsMembers() throws {
        let obj = try JSONObjectText(data: Data(sampleConfig.utf8))
        #expect(obj.keys == ["darkMode", "oauth:tokenCache", "nested", "oauth:tokenCacheV2", "lastKnownAccountUuid", "tail"])
        #expect(obj.string("lastKnownAccountUuid") == "acct-1")
        #expect(obj.raw("tail") == Data("0".utf8))
    }

    @Test func removeThenSetRestoresEveryByte() throws {
        let original = try JSONObjectText(data: Data(sampleConfig.utf8))
        var edited = original
        for key in ClaudeDesktop.authKeys { try edited.remove(key) }
        #expect(edited.keys == ["darkMode", "nested", "tail"])
        #expect(!String(decoding: edited.data, as: UTF8.self).contains("oauth"))
        // Keys come back at the end, as Claude itself appends them after a sign-in.
        for key in ClaudeDesktop.authKeys { try edited.set(key, raw: original.raw(key)!) }
        let text = String(decoding: edited.data, as: UTF8.self)
        #expect(text.hasSuffix("\t\"tail\": 0,\n\t\"oauth:tokenCache\": \"abc\",\n\t\"oauth:tokenCacheV2\": \"djEw\",\n\t\"lastKnownAccountUuid\": \"acct-1\"\n}"))
        #expect(try JSONSerialization.jsonObject(with: edited.data) is [String: Any])
    }

    @Test func setReplacesInPlace() throws {
        var obj = try JSONObjectText(data: Data(sampleConfig.utf8))
        try obj.set("lastKnownAccountUuid", raw: Data("\"acct-2\"".utf8))
        #expect(String(decoding: obj.data, as: UTF8.self) == sampleConfig.replacingOccurrences(of: "acct-1", with: "acct-2"))
    }

    @Test func removingFirstAndOnlyMembers() throws {
        var obj = try JSONObjectText(data: Data("{\n\t\"a\": 1,\n\t\"b\": 2\n}".utf8))
        try obj.remove("a")
        #expect(String(decoding: obj.data, as: UTF8.self) == "{\n\t\"b\": 2\n}")
        try obj.remove("b")
        #expect(String(decoding: obj.data, as: UTF8.self) == "{}")
        try obj.set("c", raw: Data("true".utf8))
        #expect(String(decoding: obj.data, as: UTF8.self) == "{\n\t\"c\": true\n}")
    }

    @Test func rejectsBrokenFiles() {
        #expect(throws: JSONTextError.self) { try JSONObjectText(data: Data("[1]".utf8)) }
        #expect(throws: JSONTextError.self) { try JSONObjectText(data: Data("{\"a\": 1".utf8)) }
    }
}

@Suite struct SignInTests {
    @Test func switchRoundTripIsByteIdentical() throws {
        let root = try tempDir()
        let desktop = ClaudeDesktop(root: root)
        try write(sampleConfig, desktop.configURL)
        try write("cookies-1", root.appending(path: "Cookies"))
        let store = Store(root: root.appending(path: "store"))
        let original = try Data(contentsOf: desktop.configURL)

        try desktop.saveSignIn(to: store.signInDir("acct-1"))
        try desktop.clearSignIn()
        #expect(try desktop.activeAccount() == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Cookies").path))

        try desktop.restoreSignIn(from: store.signInDir("acct-1"))
        #expect(try desktop.activeAccount() == "acct-1")
        #expect(try String(contentsOf: root.appending(path: "Cookies"), encoding: .utf8) == "cookies-1")
        let restored = try JSONObjectText(contentsOf: desktop.configURL)
        for key in ClaudeDesktop.authKeys {
            #expect(restored.raw(key) == (try JSONObjectText(data: original)).raw(key))
        }
    }

    @Test func failedSwitchPutsFilesBack() throws {
        let root = try tempDir()
        let desktop = ClaudeDesktop(root: root)
        try write(sampleConfig, desktop.configURL)
        let engine = SwitchEngine(desktop: desktop, store: Store(root: root.appending(path: "store")))
        var target = Account(profile: Profile(accountID: "acct-2", organizationID: "org", name: "B", email: "", plan: ""))
        target.org = "org"
        #expect(throws: SwitchError.noSavedSignIn) { try engine.switchFiles(to: target) }
        #expect(try String(contentsOf: desktop.configURL, encoding: .utf8) == sampleConfig)
        #expect(FileManager.default.fileExists(atPath: engine.store.safetyBackupRoot.appending(path: "config.json").path))
    }
}

@Suite struct ChatSyncTests {
    @Test func copiesMissingRefreshesOlderSkipsDeleted() throws {
        let root = try tempDir()
        try write(#"{"lastActivityAt": 5, "title": "new"}"#, root.appending(path: "a/o1/local_1.json"))
        try write(#"{"lastActivityAt": 9}"#, root.appending(path: "a/o1/local_2.json"))
        try write(#"{"lastActivityAt": 1}"#, root.appending(path: "a/o1/local_3.json"))
        try write("", root.appending(path: "a/o1/deleted_3"))
        try write(#"{"lastActivityAt": 2, "title": "old"}"#, root.appending(path: "b/o2/local_1.json"))
        try write(#"{"lastActivityAt": 10}"#, root.appending(path: "b/o2/local_2.json"))
        try write(#"{"lastActivityAt": 1}"#, root.appending(path: "b/o2/local_4.json"))

        let n = try ChatSync.sessions(root: root, account: "b", org: "o2")
        #expect(n == 1)
        let target = root.appending(path: "b/o2")
        #expect(try String(contentsOf: target.appending(path: "local_1.json"), encoding: .utf8).contains("new"))
        #expect(try String(contentsOf: target.appending(path: "local_2.json"), encoding: .utf8).contains("10"))
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "local_3.json").path))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "local_4.json").path))
    }

    @Test func scheduledTasksFollowTheSwitchAndStayDeleted() throws {
        let root = try tempDir()
        let seen = root.appending(path: "seen.json")
        func tasks(_ path: String) throws -> [String] {
            let o = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: path))) as? [String: Any]
            return (o?["scheduledTasks"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
        }
        try write(#"{"scheduledTasks": [{"id": "daily"}, {"id": "weekly"}], "recordedSkips": {}}"#, root.appending(path: "a/o/scheduled-tasks.json"))
        try write(#"{"scheduledTasks": [{"id": "own"}], "recordedSkips": {}}"#, root.appending(path: "b/o/scheduled-tasks.json"))
        // A to B: B gets A's tasks and keeps its own.
        try ChatSync.scheduledTasks(root: root, from: ("a", "o"), to: ("b", "o"), seenURL: seen)
        #expect(try tasks("b/o/scheduled-tasks.json") == ["daily", "own", "weekly"])
        // "weekly" is deleted in B; back to A, it does not come back.
        try write(#"{"scheduledTasks": [{"id": "daily"}, {"id": "own"}]}"#, root.appending(path: "b/o/scheduled-tasks.json"))
        try ChatSync.scheduledTasks(root: root, from: ("b", "o"), to: ("a", "o"), seenURL: seen)
        #expect(try tasks("a/o/scheduled-tasks.json") == ["daily", "own"])
    }

    @Test func resumeMarkersMoveWithTheChat() throws {
        let root = try tempDir()
        let interrupted = #"{"lastActivityAt": 5, "interruptedByQuitAt": 99, "interruptedAwaitingPerson": false, "remoteMcpServersConfig": [{"uuid": "x"}]}"#
        try write(interrupted, root.appending(path: "a/o1/local_1.json"))
        // The target's copy is as new as the source, but has no marker.
        try write(#"{"lastActivityAt": 5, "remoteMcpServersConfig": []}"#, root.appending(path: "b/o2/local_1.json"))

        #expect(try ChatSync.sessions(root: root, account: "b", org: "o2") == 1)
        let moved = try JSONObjectText(contentsOf: root.appending(path: "b/o2/local_1.json"))
        #expect(moved.raw("interruptedByQuitAt") == Data("99".utf8))
        #expect(moved.raw("remoteMcpServersConfig") == Data("[]".utf8))
        let left = try JSONObjectText(contentsOf: root.appending(path: "a/o1/local_1.json"))
        #expect(!left.contains("interruptedByQuitAt"))
        #expect(!left.contains("interruptedAwaitingPerson"))
        #expect(left.raw("lastActivityAt") == Data("5".utf8))
        // Nothing left to move the second time.
        #expect(try ChatSync.sessions(root: root, account: "b", org: "o2") == 0)
    }

    @Test func projectsLeaveOutOtherOrgLinksAndStayDeleted() throws {
        let root = try tempDir()
        let seen = root.appending(path: "seen.json")
        try write(#"{"spaces": [{"id": "s1", "name": "P", "updatedAt": 5, "projects": ["x"], "migration": {}}]}"#,
                  root.appending(path: "a/o1/spaces.json"))

        #expect(try ChatSync.spaces(root: root, account: "b", org: "o2", seenURL: seen) == 1)
        let (_, list) = try ChatSync.readSpaces(root.appending(path: "b/o2/spaces.json"))
        #expect(list.count == 1)
        #expect(list[0]["projects"] == nil)
        #expect(list[0]["name"] as? String == "P")

        // The user deletes the project in b; it does not come back.
        try write(#"{"spaces": []}"#, root.appending(path: "b/o2/spaces.json"))
        #expect(try ChatSync.spaces(root: root, account: "b", org: "o2", seenURL: seen) == 0)
        #expect(try ChatSync.readSpaces(root.appending(path: "b/o2/spaces.json")).1.isEmpty)
    }
}

@Suite struct SettingsMirrorTests {
    @Test func copiesPerAccountSettingsOnly() throws {
        let root = try tempDir()
        let desktop = ClaudeDesktop(root: root)
        try write("""
        {"preferences": {"sidebarMode": "x",
          "bypassPermissionsOptInByAccount": {"A": true},
          "epitaxyPrefs": {
            "epitaxy-folder-permission-mode-v2.A": {"/p": "auto"},
            "epitaxy-folder-permission-mode-v2.B": {"/q": "ask", "/p": "ask"},
            "epitaxy-auto-mode-denial-count.A": 3,
            "dframe-code-sections": {"A/oa": {"sections": [1]}}}}}
        """, root.appending(path: "claude_desktop_config.json"))
        try write(#"{"byAccount": {"A": {"presets": [1]}}}"#, root.appending(path: "ccd-session-presets.json"))
        let a = Account(profile: Profile(accountID: "A", organizationID: "oa", name: "", email: "", plan: ""))
        let b = Account(profile: Profile(accountID: "B", organizationID: "ob", name: "", email: "", plan: ""))

        #expect(try SettingsMirror.mirror(in: desktop, from: a, to: b))
        let prefs = try #require(try SettingsMirror.readObject(root.appending(path: "claude_desktop_config.json"))?["preferences"] as? [String: Any])
        #expect((prefs["bypassPermissionsOptInByAccount"] as? [String: Bool])?["B"] == true)
        let epitaxy = try #require(prefs["epitaxyPrefs"] as? [String: Any])
        #expect(epitaxy["epitaxy-folder-permission-mode-v2.B"] as? [String: String] == ["/p": "auto", "/q": "ask"])
        #expect(epitaxy["epitaxy-auto-mode-denial-count.B"] == nil)
        #expect((epitaxy["dframe-code-sections"] as? [String: Any])?["B/ob"] != nil)
        let presets = try #require(try SettingsMirror.readObject(root.appending(path: "ccd-session-presets.json"))?["byAccount"] as? [String: Any])
        #expect(presets["B"] != nil)
        #expect(try !SettingsMirror.mirror(in: desktop, from: a, to: b))
    }
}

@Suite struct TokenTests {
    @Test func picksTheNewestUnexpiredProfileToken() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let cache = """
        {"acct:A|c:o:aud:user:profile user:inference": {"token": "old", "expiresAt": 1500000},
         "acct:A|c:o:aud:user:profile": {"token": "new", "expiresAt": 1900000},
         "acct:A|c:o:aud:user:inference": {"token": "noscope", "expiresAt": 9900000},
         "acct:B|c:o:aud:user:profile": {"token": "other", "expiresAt": 9900000},
         "acct:A|c:o:aud:user:profile x": {"token": "expired", "expiresAt": 900000}}
        """
        #expect(try TokenCache.accessToken(fromPlain: Data(cache.utf8), account: "A", now: now) == "new")
        #expect(throws: APIError.signedOut) {
            try TokenCache.accessToken(fromPlain: Data(cache.utf8), account: "C", now: now)
        }
    }

    @Test func decryptsChromiumV10() throws {
        let key = try SafeStorage.derive(password: Data("peanuts".utf8))
        let plain = Data("{\"hello\": \"world\"}".utf8)
        let iv = [UInt8](repeating: UInt8(ascii: " "), count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let status = plain.withUnsafeBytes { p in
            key.withUnsafeBytes { k in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, k.count, iv, p.baseAddress, p.count, &out, out.count, &moved)
            }
        }
        #expect(status == kCCSuccess)
        #expect(try SafeStorage.aesCBC(kCCDecrypt, Data(out.prefix(moved)), key: key) == plain)
    }
}

@Suite struct PolicyTests {
    private func account(_ id: String, session: Double, weekly: Double = 0, weeklyReset: Date? = nil, checked: Date) -> Account {
        var a = Account(profile: Profile(accountID: id, organizationID: "o", name: id, email: "", plan: "Max"))
        a.usage = Usage(session: session, sessionReset: nil, weekly: weekly, weeklyReset: weeklyReset, checkedAt: checked)
        return a
    }

    @Test func nearlyFullMovesToTheAccountWithMostRoom() {
        let now = Date.now
        var st = SwitcherState()
        st.autoSwitch = true
        st.accounts = [account("A", session: 97, checked: now), account("B", session: 50, checked: now), account("C", session: 20, checked: now)]
        let target = Policy.autoTarget(st, active: "A/o", context: .init(claudeRunning: true, now: now))
        #expect(target?.0.account.id == "C")
        #expect(target?.1 == .nearlyFull)
        #expect(target?.2 == .soon)
        #expect(Policy.autoTarget(st, active: "A/o", context: .init(claudeRunning: false, now: now)) == nil)
        // Room that resets soon goes first: B's window ends in half an hour, C's room keeps.
        st.accounts[1].usage?.session = 40
        st.accounts[1].usage?.sessionReset = now.addingTimeInterval(1800)
        #expect(Policy.autoTarget(st, active: "A/o", context: .init(claudeRunning: true, now: now))?.0.account.id == "B")
        // A free account is never rotated to.
        st.accounts[1].plan = ""
        #expect(Policy.autoTarget(st, active: "A/o", context: .init(claudeRunning: true, now: now))?.0.account.id == "C")
        st.accounts[1].plan = "Max"
        // Paused: nothing moves.
        st.pausedUntil = now.addingTimeInterval(600)
        #expect(Policy.autoTarget(st, active: "A/o", context: .init(claudeRunning: true, now: now)) == nil)
        st.pausedUntil = nil
        st.lastSwitch = now.addingTimeInterval(-60)
        #expect(Policy.autoTarget(st, active: "A/o", context: .init(claudeRunning: true, now: now)) == nil)
    }

    @Test func spendWeeklyWaitsForIdleChats() {
        let now = Date.now
        var st = SwitcherState()
        st.spendWeekly = true
        st.accounts = [account("A", session: 10, weekly: 70, checked: now),
                       account("B", session: 0, weekly: 20, weeklyReset: now.addingTimeInterval(3600), checked: now)]
        #expect(Policy.autoTarget(st, active: "A/o", context: .init(claudeRunning: true, lastChat: now.addingTimeInterval(-60), now: now)) == nil)
        #expect(Policy.autoTarget(st, active: "A/o", context: .init(claudeRunning: true, lastChat: now.addingTimeInterval(-3600), commandRunning: true, now: now)) == nil)
        #expect(Policy.autoTarget(st, active: "A/o", context: .init(claudeRunning: true, lastChat: now.addingTimeInterval(-3600), now: now))?.1 == .spendWeekly)
    }

    @Test func suggestionNeedsClearlyMoreRoom() {
        let now = Date.now
        var st = SwitcherState()
        st.accounts = [account("A", session: 60, checked: now), account("B", session: 55, checked: now)]
        #expect(Policy.suggestion(st, active: "A/o", now: now) == nil)
        st.accounts[1].usage?.session = 10
        #expect(Policy.suggestion(st, active: "A/o", now: now)?.account.id == "B")
    }
}

/// Run with SWITCHER_REAL_CONFIG=<a copy of Claude's config.json> to check the
/// editor against the file Claude writes today.
@Suite struct RealConfigTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHER_REAL_CONFIG"] != nil))
    func inPlaceSetKeepsEveryByte() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHER_REAL_CONFIG"]!)
        let data = try Data(contentsOf: url)
        var obj = try JSONObjectText(data: data)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(obj.keys) == Set(parsed.keys))
        #expect(obj.keys.count == parsed.count)
        for key in ClaudeDesktop.authKeys { try obj.set(key, raw: #require(obj.raw(key))) }
        #expect(obj.data == data)
        #expect(ClaudeDesktop.signedInAccount(of: obj) != nil)
    }
}

@Suite struct AccountPrefsTests {
    @Test func settingsClaudeDroppedComeBack() throws {
        let root = try tempDir()
        let desktop = ClaudeDesktop(root: root)
        let config = root.appending(path: "claude_desktop_config.json")
        try write("""
        {"preferences": {"bypassPermissionsOptInByAccount": {"A": true}, "epitaxyPrefs": {
          "epitaxy-folder-permission-mode-v2.A": {"/p": "auto"}, "epitaxy-perm-mode-acks-v2.A": ["x"],
          "autoResumeRateLimit.A": {"local_1": {}}, "epitaxy-folder-permission-mode-v2.B": {"/q": "ask"}}}}
        """, config)
        let dir = root.appending(path: "store/A")
        try AccountPrefs.capture(in: desktop, account: "A", into: dir)

        // Claude signs A out and drops its permission settings; the user picks a new mode meanwhile.
        try write("""
        {"preferences": {"epitaxyPrefs": {"epitaxy-folder-permission-mode-v2.A": {"/r": "ask"},
          "epitaxy-folder-permission-mode-v2.B": {"/q": "ask"}}}}
        """, config)
        #expect(try AccountPrefs.restore(in: desktop, account: "A", from: dir))
        let prefs = try #require(try SettingsMirror.readObject(config)?["preferences"] as? [String: Any])
        let epitaxy = try #require(prefs["epitaxyPrefs"] as? [String: Any])
        #expect(epitaxy["epitaxy-folder-permission-mode-v2.A"] as? [String: String] == ["/p": "auto", "/r": "ask"])
        #expect(epitaxy["epitaxy-perm-mode-acks-v2.A"] as? [String] == ["x"])
        #expect(epitaxy["autoResumeRateLimit.A"] == nil)
        #expect((prefs["bypassPermissionsOptInByAccount"] as? [String: Bool])?["A"] == true)
        #expect(try !AccountPrefs.restore(in: desktop, account: "A", from: dir))
    }
}

@Suite struct CutOffTurnsTests {
    private func transcript(_ records: [String]) -> String { records.joined(separator: "\n") + "\n" }

    @Test func marksMainChatsOfWhatWasCutOff() throws {
        let root = try tempDir()
        let desktop = ClaudeDesktop(root: root.appending(path: "Claude"))
        let projects = root.appending(path: "projects")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let at = "2033-05-18T03:30:00.000Z" // three minutes before `now`
        let working = #"{"type":"assistant","timestamp":"\#(at)","message":{"stop_reason":"tool_use"}}"#
        let done = #"{"type":"assistant","timestamp":"\#(at)","message":{"stop_reason":"end_turn"}}"#
        func chat(_ id: String, _ records: [String], parent: String? = nil, active: Int = 1) throws {
            let spawned = parent.map { #", "spawnedFrom": {"sessionId": "local_\#($0)"}"# } ?? ""
            try write(#"{"cliSessionId": "\#(id)", "title": "T\#(id)", "lastActivityAt": \#(active)\#(spawned)}"#,
                      desktop.sessionsRoot.appending(path: "A/O/local_\(id).json"))
            try write(transcript(records), projects.appending(path: "-p/\(id).jsonl"))
        }
        // A lead waiting on its side sessions; one of them, and its own side session, were working.
        try chat("lead", [done], active: 5)
        try chat("side1", [working], parent: "lead")
        try chat("side2", [done], parent: "lead")
        try chat("side1a", [#"{"type":"user","timestamp":"\#(at)","message":{"content":[{"type":"tool_result"}]}}"#], parent: "side1")
        // A chat on its own, waiting on an hour-long command since 01:00.
        try chat("solo", [#"{"type":"assistant","timestamp":"2033-05-18T01:00:00.000Z","message":{"stop_reason":"tool_use"}}"#], active: 9)
        // Working, but its process had already gone to sleep.
        try chat("asleep", [working])
        try chat("idle", [done])
        // Stopped by the account's limit; its process went to sleep since.
        let limit = #"{"type":"assistant","timestamp":"\#(at)","error":"rate_limit","isApiErrorMessage":true,"message":{"model":"<synthetic>","stop_reason":"stop_sequence"}}"#
        try chat("limited", [working, limit], active: 1_999_999_820_000)

        let live = LiveConversations(ids: ["lead", "side1", "side2", "side1a", "solo", "idle"])
        let marked = try CutOffTurns.mark(desktop: desktop, account: "A", org: "O", live: live, projects: projects, now: now)
        #expect(marked.map(\.id) == ["limited", "solo", "lead"])
        #expect(marked.map(\.sideSessions) == [0, 0, 2])
        let lead = try JSONObjectText(contentsOf: desktop.sessionsRoot.appending(path: "A/O/local_lead.json"))
        #expect(lead.raw("interruptedByQuitAt") == Data("2000000000000".utf8))
        #expect(lead.raw("interruptedAwaitingPerson") == Data("false".utf8))
        let side = try JSONObjectText(contentsOf: desktop.sessionsRoot.appending(path: "A/O/local_side1.json"))
        #expect(!side.contains("interruptedByQuitAt"))
    }
}

@Suite struct BackgroundWorkTests {
    @Test func endedTurnsWithBackgroundWorkCountAsCutOff() throws {
        let root = try tempDir()
        let desktop = ClaudeDesktop(root: root.appending(path: "Claude"))
        let projects = root.appending(path: "projects")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let done = #"{"type":"assistant","timestamp":"2033-05-18T03:30:00.000Z","message":{"stop_reason":"end_turn"}}"#
        func launch(_ id: String, at time: String) -> String {
            #"{"type":"user","timestamp":"\#(time)","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"\#(id)"},"message":{"content":[{"type":"tool_result"}]}}"#
        }
        func report(_ id: String) -> String {
            #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>\#(id)</task-id>\n<status>completed</status>"}"#
        }
        func chat(_ id: String, _ records: [String]) throws {
            try write(#"{"cliSessionId": "\#(id)", "title": "T\#(id)", "lastActivityAt": 1}"#,
                      desktop.sessionsRoot.appending(path: "A/O/local_\(id).json"))
            try write(records.joined(separator: "\n") + "\n", projects.appending(path: "-p/\(id).jsonl"))
        }
        let started = Date(timeIntervalSince1970: 1_999_990_000) // 2033-05-18T00:46:40Z
        try chat("command", [done])
        try chat("agent", [launch("a1", at: "2033-05-18T03:00:00.000Z"), done])
        try chat("reported", [launch("a2", at: "2033-05-18T03:00:00.000Z"), report("a2"), done])
        try chat("earlier", [launch("a3", at: "2033-05-17T20:00:00.000Z"), done])
        try chat("idle", [done])

        let live = LiveConversations(
            ids: ["command", "agent", "reported", "earlier", "idle"], runningCommands: ["command"],
            startedAt: ["agent": started, "reported": started, "earlier": started])
        let marked = try CutOffTurns.mark(desktop: desktop, account: "A", org: "O", live: live, projects: projects, now: now)
        #expect(Set(marked.map(\.id)) == ["command", "agent"])
    }
}

/// Run with SWITCHER_REAL_CLAUDE=<a copy of Claude's data folder>, SWITCHER_REAL_ACCOUNT=<account/org>
/// and SWITCHER_REAL_NOW=<epoch seconds of a quit> to list the chats that quit cut off.
@Suite struct RealCutOffTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHER_REAL_CLAUDE"] != nil))
    func listsCutOffChats() throws {
        let env = ProcessInfo.processInfo.environment
        let desktop = ClaudeDesktop(root: URL(fileURLWithPath: env["SWITCHER_REAL_CLAUDE"]!))
        let parts = env["SWITCHER_REAL_ACCOUNT"]!.split(separator: "/").map(String.init)
        let now = Date(timeIntervalSince1970: Double(env["SWITCHER_REAL_NOW"]!)!)
        let live = LiveConversations(ids: Set((env["SWITCHER_REAL_LIVE"] ?? "").split(separator: ",").map(String.init)))
        let marked = try CutOffTurns.mark(desktop: desktop, account: parts[0], org: parts[1], live: live, now: now)
        print("CUT OFF:", marked.map { "\($0.title) [+\($0.sideSessions) side]" })
    }
}

/// Run with SWITCHER_REAL_LIVE_CHECK=1 to list the chats Claude runs a process for right now.
@Suite struct RealLiveConversationsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHER_REAL_LIVE_CHECK"] != nil))
    func listsLiveConversations() {
        let live = ClaudeProcess.liveConversations()
        print("LIVE:", live.ids.sorted(), "COMMANDS:", live.runningCommands.sorted(), "STARTED:", live.startedAt.mapValues { $0.formatted(date: .omitted, time: .standard) })
    }
}

@Suite struct SetupCopyTests {
    @Test func toolSettingsMoveToTheNewConnector() {
        let ids = ["old": "new"]
        #expect(SetupCopy.move("old:create_issue", ids) == "new:create_issue")
        #expect(SetupCopy.move("old:create_issue-0123456789abcdef0123456789abcdef", ids) == "new:create_issue-0123456789abcdef0123456789abcdef")
        #expect(SetupCopy.move("blocked=old%3Adelete_issue", ids) == "blocked=new%3Adelete_issue")
        #expect(SetupCopy.move("other:tool", ids) == nil)
        #expect(CloudSetup.sameURL("https://mcp.linear.app/mcp/", "https://MCP.linear.app/mcp"))
    }

    @Test func gapsNameWhatToAddAndWhatToSignIn() {
        func connector(_ id: String, _ url: String, connected: Bool) -> CloudSetup.Connector {
            CloudSetup.Connector(id: id, name: id, url: url, directoryID: nil, connected: connected, customOAuth: false)
        }
        var reference = CloudSetup()
        reference.connectors = [connector("r1", "https://a", connected: true), connector("r2", "https://b", connected: true)]
        reference.plugins = [CloudSetup.Item(id: "p1", name: "P1"), CloudSetup.Item(id: "p2", name: "P2")]
        reference.skills = [CloudSetup.Item(id: "s1", name: "S1"), CloudSetup.Item(id: "s2", name: "S2")]
        var mine = CloudSetup()
        mine.offeredSkills = ["s1"]
        mine.connectors = [connector("m1", "https://a/", connected: false)]
        mine.plugins = [CloudSetup.Item(id: "p2", name: "P2")]
        let gaps = mine.gaps(from: reference)
        #expect(gaps.missingConnectors.map(\.id) == ["r2"])
        #expect(gaps.signIn.map(\.id) == ["m1"])
        #expect(gaps.plugins.map(\.id) == ["p1"])
        #expect(gaps.skills.map(\.id) == ["s1"])
        #expect(gaps.unavailableSkills.map(\.id) == ["s2"])
        #expect(gaps.copyable == 3)
    }
}

@Suite struct AnalyticsTests {
    @Test func streamedRepliesCountOnceAndSubagentsCountForTheirChat() async throws {
        let root = try tempDir()
        let projects = root.appending(path: "projects")
        let reply = #"{"type":"assistant","timestamp":"2026-10-24T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_1h_input_tokens":200}}}}"#
        try write([reply, reply, #"{"type":"user","message":{}}"#].joined(separator: "\n") + "\n", projects.appending(path: "-p/chat1.jsonl"))
        try write(reply.replacingOccurrences(of: "m1", with: "m2") + "\n", projects.appending(path: "-p/chat1/subagents/agent-a.jsonl"))
        let index = UsageIndex(projects: projects, cacheURL: root.appending(path: "cache.json"))
        let buckets = await index.refresh()
        #expect(buckets.count == 1)
        let t = try #require(buckets.values.first)
        #expect(t.messages == 2)
        #expect(t.output == 200)
        #expect(t.write1h == 400)
        #expect(t.write5m == 600)
        #expect(buckets.keys.first?.conversation == "chat1")

        // Only what was appended is read again.
        try write([reply, reply, #"{"type":"user","message":{}}"#, reply.replacingOccurrences(of: "m1", with: "m3")].joined(separator: "\n") + "\n",
                  projects.appending(path: "-p/chat1.jsonl"))
        #expect(await index.refresh().values.first?.messages == 3)

        // $4 / $20 / $0.20 per million, writes 1.25x and 2x input.
        let cost = try #require(Pricing.cost(model: "claude-opus-5-5", input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000))
        #expect(abs(cost - (4 + 20 + 0.2 + 5 + 8)) < 0.0001)
        #expect(Pricing.displayName("claude-opus-5-5") == "Opus 5.5")
    }

    @Test func usageCountsForTheAccountSignedInThen() {
        var timeline = AccountTimeline()
        timeline.native = ["old": "A"]
        timeline.record("B", at: Date(timeIntervalSince1970: 1000))
        timeline.record("C", at: Date(timeIntervalSince1970: 2000))
        #expect(timeline.account(at: Date(timeIntervalSince1970: 500), conversation: "old") == "A")
        #expect(timeline.account(at: Date(timeIntervalSince1970: 1500), conversation: "old") == "B")
        #expect(timeline.account(at: Date(timeIntervalSince1970: 2500), conversation: "x") == "C")
    }
}

/// Run with SWITCHER_REAL_USAGE=1 to index the real transcripts and print totals.
@Suite struct RealUsageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHER_REAL_USAGE"] != nil))
    func indexesRealTranscripts() async {
        let cache = FileManager.default.temporaryDirectory.appending(path: "switcher-usage-\(UUID().uuidString).json")
        let index = UsageIndex(cacheURL: cache)
        let clock = ContinuousClock()
        let start = clock.now
        let buckets = await index.refresh()
        let first = clock.now - start
        let again = clock.now
        _ = await index.refresh()
        let second = clock.now - again
        let report = UsageReport.make(buckets, timeline: AccountTimeline(), range: Date.distantPast...Date.distantFuture)
        print("INDEX first \(first) second \(second) buckets \(buckets.count) messages \(report.total.tokens.messages) tokens \(report.total.tokens.total) cost $\(Int(report.total.cost)) unpriced \(report.total.unpriced)")
        for (model, t) in report.byModel.sorted(by: { $0.value.cost > $1.value.cost }).prefix(8) {
            print("MODEL \(model): \(t.tokens.messages) msgs, \(t.tokens.total / 1_000_000)M tokens, $\(Int(t.cost))")
        }
        try? FileManager.default.removeItem(at: cache)
    }
}
