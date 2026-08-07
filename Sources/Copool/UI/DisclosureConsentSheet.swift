import SwiftUI

/// 披露与同意面板（CMP-05 / SEC-08）。
///
/// 用在两类不可逆或涉及第三方资产的操作前：复用别家 CLI 的登录态、导入订阅
/// 客户端的登录态。设计上的三条硬约束：
///
///   1. **确认按钮默认禁用**，必须先勾选复选框。一个默认可点的"我同意"等于
///      没有同意——用户会连读都不读就回车过去。
///   2. 披露正文由调用方以完整文本传入并**原样落审计**，不是一个文案 key。
///      文案日后会改，而审计要回答的是"当时用户看到的是什么"。
///   3. 面板只收集意图，**不执行任何读取**。真正的读取在 `onConfirm` 之后由
///      `CredentialCoordinator` 完成，且它会先写审计再读文件。
struct DisclosureConsentSheet: View {
    let title: String
    /// 这次要动的对象（CLI 名 / 客户端名），显示在标题下。
    let subject: String
    /// 完整披露正文。逐条说明"读什么、存不存、能不能撤销"。
    let disclosure: String
    /// 逐条列出的具体影响面，例如"会复制一份到钥匙串"。
    var bulletPoints: [String] = []
    let confirmTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var agreed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(disclosure)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !bulletPoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bulletPoints, id: \.self) { point in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                            Text(point)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frostedRoundedSurface(cornerRadius: 10, prominent: false)
            }

            Toggle(isOn: $agreed) {
                Text(L10n.tr("consent.agree_checkbox"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(ConsentCheckboxStyle())

            Text(L10n.tr("consent.revocable_note"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer(minLength: 0)
                Button(L10n.tr("common.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .copoolActionButtonStyle(prominent: true, tint: .indigo, density: .compact, iOSStyle: .liquidGlass)
                    .disabled(!agreed)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}

/// macOS 有原生复选框，iOS 没有——`.checkbox` 在 iOS 上直接编译不过。
private struct ConsentCheckboxStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.toggleStyle(.checkbox)
        #else
        content.toggleStyle(.switch)
        #endif
    }
}
