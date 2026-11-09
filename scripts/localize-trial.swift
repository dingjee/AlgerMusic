import Foundation

// Keep the durable physical name while giving Finder, Dock and AppKit one
// localized display name. Operates only on a staged, identified trial bundle.
let args = Array(CommandLine.arguments.dropFirst())
let verifying = args.first == "--verify"
guard args.count == (verifying ? 2 : 1), let path = args.last else {
    fatalError("Usage: swift scripts/localize-trial.swift [--verify] <AlgerMusicPlayer.app>")
}
let app = URL(fileURLWithPath: path).standardizedFileURL
let legacyName = "AlgerMusicPlayer"
let displayName = "Alger Music"
let locales = ["en", "zh-Hans", "zh-Hant"]
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "AlgerTrial", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
do {
    try require(app.lastPathComponent == "\(legacyName).app", "Unexpected trial bundle path")
    let plist = app.appendingPathComponent("Contents/Info.plist")
    var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
    try require(info["CFBundleIdentifier"] as? String == "com.alger.music.trial", "Not an Alger trial bundle")
    try require(info["CFBundleExecutable"] as? String == legacyName, "Unexpected trial executable")
    if !verifying {
        // Base names must match the on-disk name or Finder treats it as a user
        // rename and ignores localization. Runtime names come from .strings.
        info["CFBundleName"] = legacyName
        info["CFBundleDisplayName"] = legacyName
        info["CFBundleDevelopmentRegion"] = "en"
        info["LSHasLocalizedDisplayName"] = true
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        for locale in locales {
            let directory = app.appendingPathComponent("Contents/Resources/\(locale).lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "\"CFBundleName\" = \"\(displayName)\";\n\"CFBundleDisplayName\" = \"\(displayName)\";\n"
                .write(to: directory.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)
        }
    } else {
        try require(info["CFBundleName"] as? String == legacyName && info["CFBundleDisplayName"] as? String == legacyName, "Base names must match durable path")
        try require(info["LSHasLocalizedDisplayName"] as? Bool == true, "Localized display name not enabled")
        for locale in locales {
            let file = app.appendingPathComponent("Contents/Resources/\(locale).lproj/InfoPlist.strings")
            let names = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: String]
            try require(names?["CFBundleName"] == displayName && names?["CFBundleDisplayName"] == displayName, "Localized names incorrect: \(locale)")
        }
        try require(FileManager.default.displayName(atPath: app.path) == displayName, "Finder display name incorrect")
        try require(Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == displayName, "AppKit display name incorrect")
        print("Verified Finder / Dock display name: \(displayName)")
    }
} catch {
    fputs("Trial display-name preparation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
