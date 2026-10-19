import SwiftUI
import QuickLook

struct DuplicatesView: View {
    @Environment(AppModel.self) var model
    @State private var preview: URL?
    @State private var initialized = false

    var selected: [(String, Int64)] {
        model.snap.duplicates.flatMap { g in g.files.dropFirst().filter { model.selection.contains("dup:" + $0) }.map { ($0, g.bytes) } }
    }

    var body: some View {
        let groups = model.snap.duplicates
        VStack(spacing: 0) {
            ScreenHeader(title: "Duplicates",
                         subtitle: groups.isEmpty ? "Identical files in your own folders, matched by SHA-256." : "\(groups.count) groups of identical files. The oldest copy is always kept.",
                         value: groups.isEmpty ? nil : Fmt.bytes(groups.reduce(0) { $0 + $1.wasted }), valueCaption: "in extra copies")
            if model.snap.scannedAt == nil { NotScannedYet(); Spacer() }
            else if groups.isEmpty { EmptyState(symbol: "checkmark.circle", title: "No duplicates", text: "Every file over 1 MB in your folders is unique."); Spacer() }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { g in
                            SectionLabel(title: "\(g.name) · \(g.files.count) copies of \(Fmt.bytes(g.bytes))")
                            ListCard {
                                ForEach(Array(g.files.enumerated()), id: \.element) { i, f in
                                    if i > 0 { RowDivider() }
                                    HStack(spacing: 12) {
                                        if i == 0 { Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.ok).frame(width: 20).help("Kept: the oldest copy") }
                                        else { Button { model.toggle("dup:" + f) } label: { CheckMark(on: model.selection.contains("dup:" + f)) }.buttonStyle(.plain).frame(width: 20) }
                                        Thumbnail(path: f, size: 34)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(i == 0 ? "Keeping this copy" : Paths.name(f)).font(.system(size: 13, weight: .medium))
                                            Text(Paths.short(f)).font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text(Fmt.ago(Paths.mtime(f))).font(.system(size: 12)).foregroundStyle(Palette.ink3)
                                        Button { preview = URL(fileURLWithPath: f) } label: { Image(systemName: "eye") }.buttonStyle(.borderless)
                                        Text(i == 0 ? "" : Fmt.bytes(g.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 8).rowHover()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
                FooterBar(bytes: selected.reduce(0) { $0 + $1.1 }, count: selected.count, label: "Move to Trash", note: "One copy of every file is always kept") {
                    let s = selected
                    Task {
                        await model.clean("Duplicates", targets: s.map { Actions.Target(path: $0.0, bytes: $0.1) }) {
                            let gone = Set(s.map(\.0))
                            for i in model.snap.duplicates.indices { model.snap.duplicates[i].files.removeAll { gone.contains($0) } }
                            model.snap.duplicates.removeAll { $0.files.count < 2 }
                        }
                    }
                }
            }
        }
        .quickLookPreview($preview)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            for g in model.snap.duplicates { for f in g.files.dropFirst() { model.selection.insert("dup:" + f) } }
        }
    }
}

struct PhotosView: View {
    @Environment(AppModel.self) var model
    @State private var preview: URL?
    var selected: [String] { model.snap.photos.flatMap(\.files).filter { model.selection.contains("photo:" + $0) } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Similar Photos", subtitle: "\(model.snap.photosChecked) photos in your folders compared. Pick the shots you don't need; nothing is selected for you.")
            if model.snap.scannedAt == nil { NotScannedYet(); Spacer() }
            else if model.snap.photos.isEmpty { EmptyState(symbol: "photo.stack", title: "No similar photos", text: "No near-identical shots were found."); Spacer() }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.snap.photos.enumerated()), id: \.offset) { gi, g in
                            SectionLabel(title: "Group \(gi + 1) · \(g.files.count) similar")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(g.files, id: \.self) { f in
                                        let on = model.selection.contains("photo:" + f)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Thumbnail(path: f, size: 150)
                                                .overlay(alignment: .topLeading) { CheckMark(on: on, tint: Palette.warn).padding(8) }
                                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Palette.warn : .clear, lineWidth: 2))
                                                .onTapGesture { model.toggle("photo:" + f) }
                                                .onTapGesture(count: 2) { preview = URL(fileURLWithPath: f) }
                                            Text(Paths.name(f)).font(.system(size: 11)).lineLimit(1).frame(width: 150, alignment: .leading)
                                            Text(Fmt.bytes(fileBytes(f)))
                                                .font(.system(size: 10)).foregroundStyle(Palette.ink3)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
                FooterBar(bytes: selected.reduce(0) { $0 + fileBytes($1) }, count: selected.count, label: "Move to Trash", note: "Double-click a photo to look at it full size") {
                    let s = selected
                    Task {
                        await model.clean("Similar Photos", targets: s.map { Actions.Target(path: $0, bytes: fileBytes($0)) }) {
                            let gone = Set(s)
                            for i in model.snap.photos.indices { model.snap.photos[i].files.removeAll { gone.contains($0) } }
                            model.snap.photos.removeAll { $0.files.count < 2 }
                            model.selection.subtract(s.map { "photo:" + $0 })
                        }
                    }
                }
            }
        }
        .quickLookPreview($preview)
    }
}

func fileBytes(_ p: String) -> Int64 { Int64((try? FileManager.default.attributesOfItem(atPath: Paths.expand(p))[.size] as? Int) ?? 0) }
