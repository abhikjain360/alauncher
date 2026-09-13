import AppKit
import Calc
import Core
import Foundation
import Search
import Testing
@testable import Launcher

/// Rendering runs here on a background thread, as it does on the icon queue. Nothing is shown.
struct IconTests {
    @Test("an app icon is rasterized once into a single 64 px bitmap shown at 32 pt")
    func rasterizedIcon() throws {
        let image = IconRenderer.render(.file(AppIndex.finderPath))
        #expect(image.size == NSSize(width: 32, height: 32))
        #expect(image.representations.count == 1)
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(bitmap.pixelsWide == 64)
        #expect(bitmap.pixelsHigh == 64)
        #expect(!image.isTemplate)
        #expect((bitmap.colorAt(x: 32, y: 32)?.alphaComponent ?? 0) > 0)
    }

    @Test("emoji draw in color; symbols and plain text are templates that follow the appearance")
    func glyphsAndSymbols() {
        #expect(!IconRenderer.render(.glyph("🔐")).isTemplate)
        #expect(IconRenderer.render(.glyph("A")).isTemplate)
        #expect(IconRenderer.render(.symbol("terminal")).isTemplate)
        #expect(IconRenderer.render(.calculator).representations.count == 1)
        let fallback = IconRenderer.render(.image("/nonexistent/icon.png", fallback: AppIndex.finderPath))
        #expect(fallback.representations.count == 1)
        #expect(!fallback.isTemplate)
    }
}

/// The full keystroke path minus drawing: rank and evaluate, then configure and lay
/// out the eight row views. The views are never put in a window.
@MainActor
struct RowViewTimingTests {
    @Test("with the row views updated too, a keystroke stays under 5 ms for 300 items")
    func keystrokeWithRowViews() {
        let benchmark = Fixture.benchmark()
        let views = (0..<8).map { _ in
            ResultRowView(frame: NSRect(x: 0, y: 0, width: LauncherPanel.width, height: ResultRowView.height))
        }
        let milliseconds = Fixture.millisecondsPerKeystroke(benchmark.keystrokes) { query in
            let rows = benchmark.builder.rows(for: query, in: benchmark.catalog, now: Fixture.now)
            for (index, view) in views.enumerated() {
                view.isHidden = index >= rows.count
                if index < rows.count { view.configure(rows[index]) }
                view.layoutSubtreeIfNeeded()
            }
        }
        print("keystroke → rows + row views: \(String(format: "%.3f", milliseconds)) ms per keystroke")
        #expect(milliseconds < 5)
    }
}

/// Reads the real app folders and script headers from the default config. Nothing
/// runs and nothing is shown. Skipped unless `LAUNCHER_SMOKE=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LAUNCHER_SMOKE"] == "1"))
struct RealIndexSmokeTests {
    private func milliseconds(since start: UInt64, count: Int = 1) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / Double(count) / 1_000_000
    }

    @Test("the default folders index quickly, and keystrokes stay fast on the real catalog")
    func realIndex() async {
        let config = Config()
        var start = DispatchTime.now().uptimeNanoseconds
        let catalog = CatalogBuilder.scan(settings: config.launcher, builtIns: [])
        let scan = milliseconds(since: start)
        let kinds = Dictionary(grouping: catalog.items, by: \.kind).mapValues(\.count)
        print(String(format: "real index: %d items (%d apps, %d scripts) in %.1f ms",
                     catalog.items.count, kinds[.app] ?? 0, kinds[.script] ?? 0, scan))
        #expect(catalog.items.contains { $0.id == "app:\(AppIndex.finderPath)" })
        for item in catalog.items where item.kind == .script {
            print("script: \(item.id) title=\(item.title) args=\(item.argumentCount.map(String.init) ?? "nil")")
        }

        let calculator = Calculator()
        let builder = ResultBuilder(ranker: Ranker(frecency: FrecencyStore(fileURL: nil)), calculate: { calculator.evaluate($0) }, maxResults: 8)
        let queries = ["s", "sa", "saf", "safa", "safar", "safari", "t", "te", "ter", "term", "2", "2*", "2*3", "p", "pa", "pass", "v", "vs", "vsc"]
        for query in queries { _ = builder.rows(for: query, in: catalog) }
        let rounds = 20
        start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds {
            for query in queries { _ = builder.rows(for: query, in: catalog) }
        }
        let keystroke = milliseconds(since: start, count: rounds * queries.count)
        print(String(format: "real catalog: %.3f ms per keystroke", keystroke))
        #expect(keystroke < 5)

        let apps = catalog.items.filter { $0.kind == .app }.prefix(40)
        start = DispatchTime.now().uptimeNanoseconds
        for app in apps {
            _ = IconRenderer.render(.file(String(app.id.dropFirst(4))))
        }
        print(String(format: "icon rasterization: %.2f ms per icon over %d apps", milliseconds(since: start, count: max(apps.count, 1)), apps.count))

        for arguments in [["search", "saf"], ["search", "2+2"], ["calc", "2**10"], ["calc", "5 km to mi"]] {
            print("$ alauncher \(arguments.joined(separator: " "))")
            _ = await LauncherCLI.run(arguments, config: config)
        }
    }
}
