import Foundation

enum CleanupDeletionMethod: String, Codable, Sendable {
    case permanentDeletion, moveToTrash, emptyEntireTrash

    var description: String {
        switch self {
        case .permanentDeletion: String(localized: "Permanently deletes the selected item and everything inside it.")
        case .moveToTrash: String(localized: "Moves the selected item and everything inside it to the Trash.")
        case .emptyEntireTrash: String(localized: "Empties the entire Trash, including items outside this selection.")
        }
    }
}

struct CleanupAnalysisSummary: Codable, Sendable {
    struct Application: Codable, Sendable {
        let name: String
        let bundleIdentifier: String?
        let version: String?
    }

    let path: String
    let category: String
    let deletionMethod: CleanupDeletionMethod
    let sizeBytes: UInt64?
    let directories: [String]
    let applications: [Application]
    let notes: [String]

    var preview: String {
        var lines = [path, category, deletionMethod.description]
        if let sizeBytes { lines.append(AppFormatters.bytes(sizeBytes)) }
        if !applications.isEmpty {
            lines.append("\n" + String(localized: "Possible applications"))
            lines += applications.map {
                "\($0.name) · \($0.version ?? String(localized: "Unknown"))" + ($0.bundleIdentifier.map { " · \($0)" } ?? "")
            }
        }
        if !directories.isEmpty {
            lines.append("\n" + String(localized: "Directory sample"))
            lines += directories
        }
        lines.append("")
        lines += notes
        return lines.joined(separator: "\n")
    }
}

final class CleanupAnalysisService {
    static func makeSummary(
        item: CleanupItem,
        kind: CleanupKind,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationRoots: [URL]? = nil
    ) -> CleanupAnalysisSummary {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var directories: [String] = []
        var notes = [String(localized: "Only directory names from two levels are sampled. File contents and deeper entries are not inspected.")]
        let rootValues = try? item.url.resourceValues(forKeys: keys)

        if rootValues?.isSymbolicLink == true {
            notes.append(String(localized: "This item is a symbolic link; its target was not inspected."))
        } else if rootValues?.isDirectory == true {
            // The enumerator avoids materializing an unbounded directory listing.
            if let enumerator = manager.enumerator(at: item.url, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in
                notes.append(String(localized: "Some directory metadata could not be read."))
                return true
            }) {
                var inspected = 0
                for case let url as URL in enumerator {
                    if inspected == 100 {
                        notes.append(String(localized: "The directory sample was truncated after 100 entries."))
                        break
                    }
                    inspected += 1
                    let values = try? url.resourceValues(forKeys: keys)
                    if values?.isSymbolicLink == true {
                        enumerator.skipDescendants()
                        continue
                    }
                    if values?.isDirectory == true {
                        directories.append(url.pathComponents.suffix(enumerator.level).joined(separator: "/"))
                    }
                    if enumerator.level >= 2 { enumerator.skipDescendants() }
                }
            } else {
                notes.append(String(localized: "Some directory metadata could not be read."))
            }
        } else if rootValues == nil {
            notes.append(String(localized: "Some directory metadata could not be read."))
        }

        let roots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        let hints = ([item.url.lastPathComponent] + directories).map { $0.lowercased() }
        var applications: [CleanupAnalysisSummary.Application] = []
        for root in roots {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: keys).isSymbolicLink) == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "app", let bundle = Bundle(url: url) else { continue }
                enumerator.skipDescendants()
                let name = bundle.productName ?? url.deletingPathExtension().lastPathComponent
                let identifier = bundle.bundleIdentifier
                let matches = hints.contains { hint in
                    hint.hasPrefix(name.lowercased()) || identifier?.lowercased() == hint
                        || (identifier?.lowercased().hasPrefix("com.\(hint).") ?? false)
                }
                if matches {
                    applications.append(.init(name: name, bundleIdentifier: identifier, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String))
                }
            }
        }
        notes.append(String(localized: "Application matches are inferred from names and identifiers; ownership and custom paths are not confirmed."))
        return CleanupAnalysisSummary(
            path: anonymousPath(item.url.path, home: home.path),
            category: kind.title,
            deletionMethod: kind == .trash ? .emptyEntireTrash : (kind.movesToTrash ? .moveToTrash : .permanentDeletion),
            sizeBytes: item.isSizeEstimated ? item.size : nil,
            directories: directories.sorted(),
            applications: applications,
            notes: notes
        )
    }

    private static func anonymousPath(_ path: String, home: String) -> String {
        let path = path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return path.replacingOccurrences(of: "/Users/[^/]+", with: "/Users/<user>", options: .regularExpression)
    }
}
