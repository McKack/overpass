import SwiftUI

/// A drawer at the bottom of a pane for a running log. Collapsed by default to a slim bar that shows a spinner
/// while something runs and a dot when there's text the person hasn't seen. Its whole top edge drags: let go
/// below `collapseBelow` and it closes, drag a closed drawer up past it and it opens. Follows new text.
struct LogDrawer: View {
    let title: String
    let text: String
    var busy = false
    /// Remembers the drawer's state per place it's used.
    let storageKey: String

    @AppStorage private var open: Bool
    @AppStorage private var height: Double
    @State private var dragStart: Double?
    @State private var unread = false

    private static let barHeight: Double = 28
    private static let collapseBelow: Double = 70
    private static let maxHeight: Double = 420

    init(title: String = "Details", text: String, busy: Bool = false, storageKey: String) {
        self.title = title
        self.text = text
        self.busy = busy
        self.storageKey = storageKey
        _open = AppStorage(wrappedValue: false, storageKey + ".open")
        _height = AppStorage(wrappedValue: 160, storageKey + ".height")
    }

    /// The text area's height while dragging, or the remembered one.
    @State private var liveHeight: Double?
    private var shownHeight: Double { liveHeight ?? (open ? height : 0) }

    var body: some View {
        VStack(spacing: 0) {
            bar
            if shownHeight > 0 {
                logText.frame(height: shownHeight)
            }
        }
        .background {
            VisualEffect(material: .sidebar)
                .overlay(Color.black.opacity(0.06))
        }
        .overlay(alignment: .top) { Divider() }
        .onChange(of: text) { if !open { unread = !text.isEmpty } }
        .onChange(of: open) { if open { unread = false } }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.up")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(open ? 180 : 0))
                .foregroundStyle(.secondary)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if busy && !open {
                ProgressView().controlSize(.mini)
            } else if unread {
                Circle().fill(.blue).frame(width: 6, height: 6)
                    .help("New output")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.barHeight)
        // The grab handle, like a sheet's on a phone.
        .overlay(alignment: .top) {
            Capsule().fill(.tertiary).frame(width: 36, height: 4).padding(.top, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { open.toggle() } }
        .gesture(resize)
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { drag in
                let start = dragStart ?? (open ? height : 0)
                dragStart = start
                liveHeight = min(Self.maxHeight, max(0, start - drag.translation.height))
            }
            .onEnded { _ in
                let ended = liveHeight ?? 0
                withAnimation(.snappy) {
                    if ended < Self.collapseBelow {
                        open = false
                    } else {
                        open = true
                        height = ended
                    }
                    liveHeight = nil
                }
                dragStart = nil
            }
    }

    private var logText: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Text(text.isEmpty ? "Nothing yet." : text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// An AppKit visual effect (vibrancy) behind SwiftUI content, as in the sidebar.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
