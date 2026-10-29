import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Model

enum PDFMode: String, CaseIterable, Identifiable {
    case lossless, high, small

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lossless: return "Lossless"
        case .high: return "Tinggi"
        case .small: return "Hemat"
        }
    }

    var detail: String {
        switch self {
        case .lossless: return "Isi PDF tidak berubah. Hemat sedikit, aman untuk semua jenis PDF."
        case .high: return "Gambar di atas 300 dpi dikecilkan. Cocok untuk dokumen yang akan dicetak."
        case .small: return "Gambar di atas 150 dpi dikecilkan. Ukuran paling kecil, enak dibaca di layar."
        }
    }
}

struct Item: Identifiable {
    enum State {
        case waiting, running
        case done(before: Int64, after: Int64)
        case optimal
        case skipped
        case failed(String)
    }

    let id = UUID()
    let path: String
    let base: String?
    let size: Int64
    var state: State = .waiting

    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
}

// MARK: - Mesin kompresi (kompres.py)

enum Engine {
    static let python: String = ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    static let script = Bundle.main.path(forResource: "kompres", ofType: "py") ?? ""

    /// Jalankan kompres.py dan kembalikan tiap baris JSON dari keluarannya.
    static func run(_ args: [String]) -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    struct Outcome {
        var state: Item.State
        var saved: Int64 = 0
        var original: Int64 = 0
        var outDir: String?
    }

    /// Kompres satu file dan terjemahkan jawaban kompres.py ke status untuk tampilan.
    static func compress(path: String, base: String?, mode: PDFMode, video: Bool, out: String?) -> Outcome {
        var args = ["--json", "--pdf", mode.rawValue]
        if video { args.append("--video") }
        if let out { args += ["-o", out] }
        if let base { args += ["--base", base] }
        args.append(path)

        let row = run(args).first
        let before = (row?["before"] as? NSNumber)?.int64Value ?? 0
        let after = (row?["after"] as? NSNumber)?.int64Value ?? 0
        let note = row?["note"] as? String ?? ""
        switch row?["status"] as? String {
        case "ok":
            return Outcome(state: .done(before: before, after: after), saved: before - after,
                           original: before, outDir: row?["out"] as? String)
        case "optimal": return Outcome(state: .optimal)
        case "lewati": return Outcome(state: .skipped)
        default: return Outcome(state: .failed(note.isEmpty ? "Gagal diproses" : note))
        }
    }

    static func summary(saved: Int64, total: Int64) -> String {
        guard saved > 0 else { return "Selesai · tidak ada file yang bisa diperkecil lagi" }
        let percent = String(format: "%.1f", Double(saved) / Double(total) * 100)
        return "Selesai · hemat \(formatSize(saved)) (\(percent)%)"
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var items: [Item] = []
    @Published var pdfMode: PDFMode = .lossless
    @Published var includeVideo = false
    @Published var outputDir: String?
    @Published var running = false
    @Published var finished = 0
    @Published var summary: String?
    private(set) var resultDirs: Set<String> = []

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    func add(_ urls: [URL]) {
        let paths = urls.map(\.path)
        guard !paths.isEmpty, !running else { return }
        Task.detached {
            let rows = Engine.run(["--list"] + paths)
            await MainActor.run { self.append(rows) }
        }
    }

    private func append(_ rows: [[String: Any]]) {
        var known = Set(items.map(\.path))
        for row in rows {
            guard let path = row["path"] as? String, known.insert(path).inserted else { continue }
            let size = (row["size"] as? NSNumber)?.int64Value ?? 0
            items.append(Item(path: path, base: row["base"] as? String, size: size))
        }
        summary = nil
    }

    func clear() {
        guard !running else { return }
        items = []
        summary = nil
        finished = 0
    }

    func remove(_ id: UUID) {
        guard !running else { return }
        items.removeAll { $0.id == id }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Tambah"
        panel.message = "Pilih file atau folder"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Pilih"
        if panel.runModal() == .OK { outputDir = panel.url?.path }
    }

    func revealResults() {
        for dir in resultDirs { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
    }

    private func setState(_ id: UUID, _ state: Item.State) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = state }
    }

    func start() {
        guard !running, !items.isEmpty else { return }
        running = true
        finished = 0
        summary = nil
        resultDirs = []
        for i in items.indices { items[i].state = .waiting }
        let jobs = items, mode = pdfMode, video = includeVideo, out = outputDir

        Task.detached {
            var saved: Int64 = 0, total: Int64 = 0
            var dirs: Set<String> = []
            for job in jobs {
                await MainActor.run { self.setState(job.id, .running) }
                let result = Engine.compress(path: job.path, base: job.base, mode: mode, video: video, out: out)
                saved += result.saved
                total += result.original
                if let dir = result.outDir { dirs.insert(dir) }
                await MainActor.run {
                    self.setState(job.id, result.state)
                    self.finished += 1
                }
            }
            let finalDirs = dirs
            let summary = Engine.summary(saved: saved, total: total)
            await MainActor.run {
                self.resultDirs = finalDirs
                self.summary = summary
                self.running = false
            }
        }
    }
}

@MainActor let store = Store()

// MARK: - Tampilan

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            header
            if store.items.isEmpty { dropZone } else { fileList }
            options
            footer
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        lock.lock(); urls.append(url); lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { store.add(urls) }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kompres Lossless").font(.title2.weight(.bold))
                Text("Perkecil PDF, JPG, dan PNG. File asli tidak diubah.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("Lepas file atau folder di sini").font(.headline)
            Text("PDF, JPG, PNG, dan video MP4/MOV").font(.subheadline).foregroundStyle(.secondary)
            Button("Pilih File…") { store.chooseFiles() }
                .controlSize(.large)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(targeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.2),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        )
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private var fileList: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(store.items.count) file · \(formatSize(store.totalSize))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Tambah…") { store.chooseFiles() }.buttonStyle(.borderless).disabled(store.running)
                Button("Kosongkan") { store.clear() }.buttonStyle(.borderless).disabled(store.running)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.items) { item in
                        Row(item: item, canRemove: !store.running) { store.remove(item.id) }
                        if item.id != store.items.last?.id { Divider().padding(.leading, 58) }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxHeight: .infinity)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kualitas PDF").font(.subheadline.weight(.semibold))
                Picker("", selection: $store.pdfMode) {
                    ForEach(PDFMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(store.pdfMode.detail).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle(isOn: $store.includeVideo) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sertakan video")
                    Text("Dikodekan ulang ke HEVC. Hampir tanpa beda, tapi bukan lossless murni dan lebih lambat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("Simpan ke").font(.subheadline.weight(.semibold))
                Text(store.outputDir ?? "Folder “Terkompres” di samping file asli")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if store.outputDir != nil {
                    Button("Reset") { store.outputDir = nil }.buttonStyle(.borderless)
                }
                Button("Pilih…") { store.chooseOutput() }
            }
        }
        .disabled(store.running)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if store.running {
                ProgressView(value: Double(store.finished), total: Double(max(store.items.count, 1)))
                    .frame(maxWidth: .infinity)
                Text("\(store.finished) dari \(store.items.count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(store.summary ?? "")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.summary != nil && !store.resultDirs.isEmpty {
                    Button("Buka Hasil") { store.revealResults() }.controlSize(.large)
                }
                Button("Kompres") { store.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.items.isEmpty)
            }
        }
        .frame(height: 32)
    }
}

struct Row: View {
    let item: Item
    let canRemove: Bool
    let onRemove: () -> Void

    private var icon: (name: String, tint: Color) {
        switch item.ext {
        case "pdf": return ("doc.text.fill", .red)
        case "mp4", "mov", "m4v": return ("film.fill", .purple)
        default: return ("photo.fill", .blue)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(icon.tint.gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(formatSize(item.size)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            status
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .waiting:
            if canRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Hapus dari daftar")
            }
        case .running:
            ProgressView().controlSize(.small)
        case let .done(before, after):
            VStack(alignment: .trailing, spacing: 2) {
                Text("−\(String(format: "%.1f", Double(before - after) / Double(max(before, 1)) * 100))%")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                Text("\(formatSize(before)) → \(formatSize(after))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .optimal:
            Text("Sudah optimal").font(.callout).foregroundStyle(.secondary)
        case .skipped:
            Text("Dilewati").font(.callout).foregroundStyle(.secondary)
        case let .failed(note):
            Text(note).font(.callout).foregroundStyle(.red).lineLimit(1)
        }
    }
}

// MARK: - Popup saat file ditahan

/// Panel yang tidak mengambil fokus, supaya app yang sedang dipakai tetap aktif selama drag.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Memantau drag file di seluruh sistem. Kalau kursor diam 2 detik sambil membawa file,
/// popup muncul di dekat kursor dan file bisa dilepas di atasnya untuk dikompres.
@MainActor
final class QuickDrop: ObservableObject {
    enum Phase {
        case hidden, offer
        case running(done: Int, total: Int)
        case result(String, [String])
    }

    static let holdRadius: CGFloat = 24
    static let supported: Set<String> = ["pdf", "png", "jpg", "jpeg", "mp4", "mov", "m4v"]
    static let videoTypes: Set<String> = ["mp4", "mov", "m4v"]

    @Published var phase: Phase = .hidden
    @Published var visible = false
    @Published private(set) var urls: [URL] = []

    private var panel: PopupPanel?
    private var timer: Timer?
    private var wasDown = false
    private var dragging = false
    private var baseline = 0
    private var anchor = NSPoint.zero
    private var dwellStart = Date()
    private var hideTask: DispatchWorkItem?
    private var orderOutTask: DispatchWorkItem?

    private var enabled: Bool { UserDefaults.standard.object(forKey: "holdPopup") as? Bool ?? true }
    private var holdSeconds: Double { UserDefaults.standard.object(forKey: "holdSeconds") as? Double ?? 0.8 }

    var hasPDF: Bool { urls.contains { $0.pathExtension.lowercased() == "pdf" || Self.isDirectory($0) } }
    var hasVideo: Bool { urls.contains { Self.videoTypes.contains($0.pathExtension.lowercased()) || Self.isDirectory($0) } }
    var hasOther: Bool { urls.contains { !Self.videoTypes.contains($0.pathExtension.lowercased()) } }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let found = pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return found.filter { supported.contains($0.pathExtension.lowercased()) || isDirectory($0) }
    }

    /// Tombol mouse dan clipboard drag dibaca berkala, karena event mouse global
    /// tidak dijamin sampai ke app lain selama sesi drag berlangsung.
    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let pasteboard = NSPasteboard(name: .drag)
        defer { wasDown = down }

        guard enabled else {
            if case .offer = phase { hide() }
            return
        }
        if down && !wasDown {
            baseline = pasteboard.changeCount
            dragging = false
        }
        if down {
            let loc = NSEvent.mouseLocation
            if !dragging, pasteboard.changeCount != baseline {
                let found = Self.fileURLs(in: pasteboard)
                if !found.isEmpty {
                    if case .result = phase { hide() }
                    dragging = true
                    urls = found
                    anchor = loc
                    dwellStart = Date()
                    cancelHide()
                }
            }
            if dragging, case .hidden = phase {
                if hypot(loc.x - anchor.x, loc.y - anchor.y) > Self.holdRadius {
                    anchor = loc
                    dwellStart = Date()
                } else if Date().timeIntervalSince(dwellStart) >= holdSeconds {
                    show(near: loc)
                }
            }
        } else if wasDown, dragging {
            dragging = false
            if case .offer = phase { scheduleHide(after: 0.6) }
        }
    }

    private func show(near loc: NSPoint) {
        phase = .offer
        orderOutTask?.cancel()
        let panel = self.panel ?? makePanel()
        place(panel, near: loc)
        visible = false
        panel.orderFrontRegardless()
        DispatchQueue.main.async { self.visible = true }
    }

    private func makePanel() -> PopupPanel {
        let p = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: PopupView(quick: self))
        panel = p
        return p
    }

    /// Di kanan-bawah kursor, supaya melepas file tanpa sengaja tidak jatuh ke popup.
    private func place(_ panel: NSPanel, near loc: NSPoint) {
        let size = panel.frame.size
        let area = (NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = loc.x + 32, y = loc.y - size.height - 32
        if x + size.width > area.maxX { x = loc.x - size.width - 32 }
        if y < area.minY { y = loc.y + 32 }
        x = max(area.minX + 8, x)
        y = min(max(area.minY + 8, y), area.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func dismiss() { hide() }

    private func hide() {
        cancelHide()
        phase = .hidden
        visible = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .hidden = self.phase else { return }
            self.panel?.orderOut(nil)
        }
        orderOutTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func scheduleHide(after seconds: Double) {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                switch self.phase {
                case .offer, .result: self.hide()
                default: break
                }
            }
        }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func openFolders(_ dirs: [String]) {
        for dir in dirs { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
    }

    func drop(_ providers: [NSItemProvider], hemat: Bool) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var dropped: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); dropped.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let files = dropped
            Task { @MainActor in self.run(files, hemat: hemat) }
        }
        return true
    }

    /// "Lossless" menjaga isi file. "Hemat" mengecilkan gambar PDF ke 150 dpi dan ikut memproses video.
    private func run(_ files: [URL], hemat: Bool) {
        guard !files.isEmpty else { return hide() }
        cancelHide()
        phase = .running(done: 0, total: files.count)
        let mode: PDFMode = hemat ? .small : .lossless

        Task.detached {
            let rows = Engine.run(["--list"] + files.map(\.path))
            var saved: Int64 = 0, total: Int64 = 0
            var dirs: Set<String> = []
            for (i, row) in rows.enumerated() {
                await MainActor.run { self.phase = .running(done: i, total: rows.count) }
                guard let path = row["path"] as? String else { continue }
                let result = Engine.compress(path: path, base: row["base"] as? String, mode: mode, video: hemat, out: nil)
                saved += result.saved
                total += result.original
                if let dir = result.outDir { dirs.insert(dir) }
            }
            let text = rows.isEmpty ? "Tidak ada file yang didukung" : Engine.summary(saved: saved, total: total)
            let finalDirs = Array(dirs)
            await MainActor.run {
                self.phase = .result(text, finalDirs)
                self.scheduleHide(after: 8)
            }
        }
    }
}

struct PopupView: View {
    @ObservedObject var quick: QuickDrop

    var body: some View {
        VStack(spacing: 10) {
            content
                .id(phaseKey)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: phaseKey)
            .padding(14)
            .frame(width: 340, height: 160)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .scaleEffect(quick.visible ? 1 : 0.8, anchor: .topLeading)
            .opacity(quick.visible ? 1 : 0)
            .offset(y: quick.visible ? 0 : 10)
            .animation(.spring(response: 0.38, dampingFraction: 0.68), value: quick.visible)
    }

    private var phaseKey: String {
        switch quick.phase {
        case .hidden, .offer: return "offer"
        case .running: return "running"
        case .result: return "result"
        }
    }

    private var hematSubtitle: String {
        switch (quick.hasPDF, quick.hasVideo) {
        case (true, true): return "PDF 150 dpi, video HEVC"
        case (_, true): return "Video HEVC"
        default: return "PDF 150 dpi"
        }
    }

    @ViewBuilder private var content: some View {
        switch quick.phase {
        case .hidden:
            EmptyView()
        case .offer:
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                Text("\(quick.urls.count) file siap dikompres").font(.headline)
                Spacer()
            }
            HStack(spacing: 10) {
                if quick.hasOther {
                    DropTile(title: "Lossless", subtitle: "Isi tidak berubah") { quick.drop($0, hemat: false) }
                }
                if quick.hasPDF || quick.hasVideo {
                    DropTile(title: "Hemat", subtitle: hematSubtitle) { quick.drop($0, hemat: true) }
                }
            }
        case let .running(done, total):
            Spacer()
            ProgressView().controlSize(.large)
            Text("Mengompres \(min(done + 1, total)) dari \(total)…").font(.headline)
            Spacer()
        case let .result(text, dirs):
            Spacer()
            Text(text).font(.headline).multilineTextAlignment(.center)
            HStack {
                if !dirs.isEmpty { Button("Buka Folder") { quick.openFolders(dirs) } }
                Button("Tutup") { quick.dismiss() }
            }
            Spacer()
        }
    }
}

struct DropTile: View {
    let title: String
    let subtitle: String
    let onDrop: ([NSItemProvider]) -> Bool
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(targeted ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.25),
                          style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .scaleEffect(targeted ? 1.04 : 1)
        .onDrop(of: [.fileURL], isTargeted: $targeted, perform: onDrop)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: targeted)
    }
}

@MainActor let quick = QuickDrop()

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in quick.start() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in store.add(urls) }
    }

    /// App tetap berjalan di menu bar setelah jendela ditutup, supaya popup tetap bisa muncul.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { !($0 is NSPanel) }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("holdPopup") private var holdPopup = true
    @AppStorage("holdSeconds") private var holdSeconds = 0.8
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Button("Buka Jendela") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("Popup saat file ditahan", isOn: $holdPopup)
        Picker("Tahan selama", selection: $holdSeconds) {
            Text("0,5 detik").tag(0.5)
            Text("0,8 detik").tag(0.8)
            Text("1 detik").tag(1.0)
            Text("2 detik").tag(2.0)
        }
        Toggle("Buka saat login", isOn: Binding(
            get: { launchAtLogin },
            set: { on in
                try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }))
        Divider()
        Button("Keluar") { NSApp.terminate(nil) }
    }
}

@main
struct KompresApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Kompres Lossless", id: "main") {
            ContentView(store: store)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 700, height: 700)

        MenuBarExtra("Kompres Lossless", systemImage: "arrow.down.right.and.arrow.up.left") {
            MenuContent()
        }
    }
}
