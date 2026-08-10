// macOS セッションの動作確認用サンプルアプリ。
// WebDriverAgentMac からの操作を機械判定できるよう、クリック・キー入力の結果を
// accessibilityIdentifier 付きの要素に反映する。
import SwiftUI

@main
struct MacSampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var clicked = false
    @State private var input = ""

    var body: some View {
        VStack(spacing: 24) {
            Text("simtunnel macOS sample")
                .font(.largeTitle)
            Text(clicked ? "Clicked!" : "Not clicked")
                .font(.title)
                .accessibilityIdentifier("statusLabel")
            Button("Click Me") {
                clicked = true
            }
            .accessibilityIdentifier("clickButton")
            TextField("Type here", text: $input)
                .frame(width: 240)
                .accessibilityIdentifier("inputField")
            Text("input: \(input)")
                .accessibilityIdentifier("inputEcho")
        }
        .padding(48)
        .frame(minWidth: 560, minHeight: 400)
    }
}
