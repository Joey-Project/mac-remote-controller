import AppleCore
import SwiftUI
import WidgetKit

@main
struct SofaRemoteWidgetBundle: WidgetBundle {
    var body: some Widget {
        RemoteLauncherWidget()
        if #available(iOS 18.0, *) {
            TouchpadControl()
            KeyboardControl()
        }
    }
}

@available(iOS 18.0, *)
struct TouchpadControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.joeyteng.sofaremote.touchpad") {
            ControlWidgetButton(action: OpenTouchpadIntent()) {
                Label("Touchpad", systemImage: "cursorarrow.motionlines")
            }
        }
        .displayName("Sofa Remote Touchpad")
        .description("Open Sofa Remote's touchpad.")
    }
}

@available(iOS 18.0, *)
struct KeyboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.joeyteng.sofaremote.keyboard") {
            ControlWidgetButton(action: OpenKeyboardIntent()) {
                Label("Keyboard", systemImage: "keyboard")
            }
        }
        .displayName("Sofa Remote Keyboard")
        .description("Open Sofa Remote's keyboard.")
    }
}

private struct LauncherEntry: TimelineEntry {
    let date: Date
}

private struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry { LauncherEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

struct RemoteLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.joeyteng.sofaremote.launcher", provider: LauncherProvider()
        ) { _ in
            LauncherView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Sofa Remote")
        .description("Open your Mac's touchpad or keyboard.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}

private struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: "cursorarrow.motionlines")
                    .accessibilityLabel("Open Sofa Remote touchpad")
            case .accessoryInline:
                Label("Sofa Remote", systemImage: "cursorarrow.motionlines")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text("Sofa Remote").font(.headline)
                    Label("Open touchpad", systemImage: "cursorarrow.motionlines")
                }
            default:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sofa Remote").font(.headline)
                    if family == .systemMedium {
                        HStack(spacing: 16) { launcherLinks }
                    } else {
                        Label("Open touchpad", systemImage: "cursorarrow.motionlines")
                            .font(.title3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .widgetURL(RemoteEntryPoint.touchpad.url)
    }

    private var launcherLinks: some View {
        Group {
            Link(destination: RemoteEntryPoint.touchpad.url) {
                Label("Touchpad", systemImage: "cursorarrow.motionlines")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            Link(destination: RemoteEntryPoint.keyboard.url) {
                Label("Keyboard", systemImage: "keyboard")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
    }
}
