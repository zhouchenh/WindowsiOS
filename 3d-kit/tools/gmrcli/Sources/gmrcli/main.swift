import Foundation
import StosSign_API
import StosSign_Auth
import StosSign_Common

// Enables extra capabilities (Extended Virtual Addressing, Increased Memory Limit) on a free
// developer account's App ID through Apple's developer services API, the way GetMoreRam does on
// iOS, then downloads the resulting development provisioning profile.
//
//   gmrcli <bundle id> <profile output path>

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: gmrcli <bundle id> <profile output path> [anisette server]")
    exit(2)
}
let bundleID = args[1]
let outPath = args[2]
let anisetteServer = args.count > 3 ? args[3] : "https://ani.sidestore.io"
let wanted = ["com.apple.developer.kernel.extended-virtual-addressing",
              "com.apple.developer.kernel.increased-memory-limit"]

func prompt(_ text: String) -> String {
    print(text, terminator: "")
    return (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func run() async throws {
    let appleID = prompt("Apple ID (email): ")
    guard let pw = getpass("Password (not shown): "), !appleID.isEmpty else { throw "no credentials" }
    let password = String(cString: pw)

    AnisetteDataHelper.shared.url = URL(string: anisetteServer)
    print("Getting anisette data from \(anisetteServer) ...")
    let anisette = try await AnisetteDataHelper.shared.getAnisetteData()

    print("Signing in ...")
    let (account, session) = try await AppleAPI.shared.authenticate(
        appleID: appleID, password: password, anisetteData: anisette
    ) { completion in
        let code = prompt("Two-factor code (sent to your devices): ")
        completion(code.isEmpty ? nil : code)
    }
    print("Signed in.")

    let teams = try await AppleAPI.shared.fetchTeamsForAccount(account: account, session: session)
    for t in teams { print("team: \(t.identifier) \(t.name) type=\(t.type)") }
    guard let team = teams.first else { throw "no team" }

    let caps = try await AppleAPI.shared.fetchCapabilitiesForTeam(team: team, session: session)
    var capIDs: [String] = []
    for c in caps {
        let keys = (c.attributes.entitlements ?? []).map { $0.key }
        if keys.contains(where: { wanted.contains($0) }) {
            print("capability \(c.id): \(keys.joined(separator: ", ")) teams=\(c.attributes.validTeamTypes)")
            capIDs.append(c.id)
        }
    }
    if capIDs.isEmpty {
        print("No matching capability listed; trying the known ids.")
        capIDs = ["EXTENDED_VIRTUAL_ADDRESSING", "INCREASED_MEMORY_LIMIT"]
    }

    let ids = try await AppleAPI.shared.fetchAppIDsForTeam(team: team, session: session)
    guard let appID = ids.first(where: { $0.bundleIdentifier == bundleID }) else {
        throw "App ID \(bundleID) not found (have: \(ids.map { $0.bundleIdentifier }.joined(separator: ", ")))"
    }
    print("App ID: \(appID.bundleIdentifier) (\(appID.identifier)) entitlements before: \(appID.entitlements)")

    for cap in capIDs {
        do {
            let updated = try await AppleAPI.shared.updateAppID(appID, capabilities: [cap], team: team, session: session)
            print("enabled \(cap): entitlements now \(updated.entitlements)")
        } catch {
            print("could not enable \(cap): \(error)")
        }
    }
    // all wanted capabilities at once too (an update may replace the set)
    if capIDs.count > 1 {
        do {
            let updated = try await AppleAPI.shared.updateAppID(appID, capabilities: capIDs, team: team, session: session)
            print("enabled all: entitlements now \(updated.entitlements)")
        } catch {
            print("could not enable all together: \(error)")
        }
    }

    let refreshed = try await AppleAPI.shared.fetchAppIDsForTeam(team: team, session: session)
        .first(where: { $0.bundleIdentifier == bundleID }) ?? appID
    let profile = try await AppleAPI.shared.fetchProvisioningProfileForAppID(
        appID: refreshed, deviceType: .iPad, team: team, session: session)
    try profile.data.write(to: URL(fileURLWithPath: outPath))
    print("profile \(profile.name) \(profile.uuid) expires \(profile.expirationDate) devices=\(profile.deviceIDs.count)")
    for (k, _) in profile.entitlements.sorted(by: { $0.key < $1.key }) { print("  entitlement: \(k)") }
    print("saved to \(outPath)")
}

let sem = DispatchSemaphore(value: 0)
Task {
    do { try await run() } catch { print("error: \(error)") }
    sem.signal()
}
sem.wait()
