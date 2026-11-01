import Observation
import SwiftUI
import UIKit

/// A file to hand to the share sheet (`.sheet(item:)` needs Identifiable).
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// UIActivityViewController, presented as a sheet once an export is ready
/// so the family does not have to find a second button.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let item: ShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Runs `RosettaExporter.makeExportZip` off the main thread and publishes
/// progress, the finished zip, or the error (B5: export used to copy every
/// clip three times on the main thread from a Button).
@MainActor
@Observable
final class ExportController {
    /// 0...1 while an export runs; nil when idle.
    private(set) var progress: Double?
    /// The finished archive, presented in the share sheet; cleared on dismiss.
    var result: ShareItem?
    private(set) var error: String?

    var isRunning: Bool { progress != nil }

    func run(_ exporter: RosettaExporter) {
        guard !isRunning else { return }
        progress = 0
        error = nil
        result = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try exporter.makeExportZip { fraction in
                    Task { @MainActor in
                        self?.progress = fraction
                    }
                }
                await MainActor.run {
                    self?.progress = nil
                    self?.result = ShareItem(url: url)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self?.progress = nil
                    self?.error = message
                }
            }
        }
    }
}

/// Restores a Rosetta export folder (B2). Rows merge by id and never
/// overwrite; clips the backfill gave up on this process are retried
/// (`MissingClipRegistry`); the ranking index is rebuilt afterwards.
@MainActor
@Observable
final class ImportController {
    private(set) var isRunning = false
    /// Plain-language outcome (counts, or the importer's own message), for
    /// an alert. Clear it to dismiss.
    var message: String?

    func run(url: URL, env: AppEnvironment, completion: (() -> Void)? = nil) {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            do {
                let summary = try await RosettaImporter.restore(from: url, into: env.db)
                MissingClipRegistry.shared.removeAll()
                PhotoCache.shared.removeAll()
                await env.suggestions.reload()
                message = Self.describe(summary)
            } catch {
                message = error.localizedDescription
            }
            isRunning = false
            completion?()
        }
    }

    static func describe(_ summary: RosettaImporter.ImportSummary) -> String {
        if summary.rowsInserted == 0 && summary.clipsCopied == 0 && summary.photosCopied == 0 {
            return "Nothing new to add — everything in that export is already on this phone."
        }
        var parts: [String] = []
        parts.append("Added \(summary.intents) word\(summary.intents == 1 ? "" : "s"), "
            + "\(summary.exemplars) confirmed clip\(summary.exemplars == 1 ? "" : "s"), "
            + "\(summary.segments) recording\(summary.segments == 1 ? "" : "s") "
            + "and \(summary.events) event\(summary.events == 1 ? "" : "s").")
        parts.append("Copied \(summary.clipsCopied) audio file\(summary.clipsCopied == 1 ? "" : "s") "
            + "and \(summary.photosCopied) photo\(summary.photosCopied == 1 ? "" : "s").")
        if summary.skippedRows > 0 {
            parts.append("\(summary.skippedRows) row\(summary.skippedRows == 1 ? " was" : "s were") skipped because something they refer to is missing from the export.")
        }
        return parts.joined(separator: " ")
    }
}
