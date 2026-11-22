import SwiftUI
import TaugeKit

/// Inline "test this proxy" control, shared by the proxy editor, the host editor
/// and settings.
///
/// It opens a real tunnel to a target (no SSH involved) so the two very
/// different failures become distinguishable: "the proxy is unreachable from
/// this Mac" versus "the proxy reached, but refused the tunnel".
struct ProxyTestView: View {
    @EnvironmentObject private var app: AppState
    private let proxy: ProxyConfig
    private let password: String?

    @ViewState private var target: String
    @ViewState private var testing = false
    @ViewState private var result: ProxyProbeResult?
    @ViewState private var inputError: String?

    init(proxy: ProxyConfig,
         password: String? = nil,
         defaultTarget: String = "example.com:443") {
        self.proxy = proxy
        self.password = password
        _target = ViewState(wrappedValue: defaultTarget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField(L("测试目标（主机:端口）"), text: $target)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 186)
                Button(testing ? L("测试中…") : L("测试连通性")) { runTest() }
                    .font(.system(size: 11))
                    .disabled(testing || proxy.host.trimmingCharacters(in: .whitespaces).isEmpty)
                if testing {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            if let inputError {
                statusLine("exclamationmark.triangle.fill", inputError, Theme.warning)
            }
            if let result {
                statusLine(result.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill",
                           result.summary + "（" + String(result.elapsedMilliseconds) + " ms）",
                           result.isSuccess ? Theme.success : Theme.danger)
                if let advice = result.recommendation {
                    Text(advice)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Editing the endpoint invalidates an earlier verdict.
        .onChange(of: proxy.endpointDescription) { _ in
            result = nil
            inputError = nil
        }
    }

    private func statusLine(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runTest() {
        guard proxy.port > 0, proxy.port < 65536 else {
            inputError = L("代理端口需要是 1–65535 之间的整数")
            result = nil
            return
        }
        guard let parsed = ProxyProbe.parseTarget(target) else {
            inputError = L("测试目标格式应为 主机:端口，例如 example.com:443")
            result = nil
            return
        }
        inputError = nil
        result = nil
        testing = true
        // Run off the main thread: the probe blocks on the network for up to
        // its timeout, and the sheet must stay responsive.
        Task {
            let outcome = await app.testProxy(proxy,
                                              password: password,
                                              targetHost: parsed.host,
                                              targetPort: parsed.port)
            await MainActor.run {
                result = outcome
                testing = false
            }
        }
    }
}
