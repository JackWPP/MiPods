import SwiftUI
import MiPodsCore

/// 点击菜单栏图标弹出的主面板。
///
/// 布局从上到下：设备头 → 三路电量（大环）→ 模式切换 → 录音 → 底部操作栏。
/// **所有可选区域都按 `capabilities` 决定是否渲染**，不做「灰按钮」这种误导性 UI。
struct PanelView: View {

    @ObservedObject var controller: MiPodsController

    /// 由 App 注入：触发 HUD 重播（用户点「刷新」后给个视觉反馈）。
    var onShowHUD: () -> Void

    /// 打开系统「声音」设置面板的回调。
    var onOpenSoundSettings: () -> Void

    private var state: MiPodsState { controller.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            header
                .padding(.horizontal, 18)
                .padding(.top, 16)

            Divider().padding(.horizontal, 18).padding(.top, 14)

            // 三路大电量环
            BatteryTriplet(state: state, ringSize: 72, ringLineWidth: 6, spacing: 22)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

            // 模式切换（按能力渲染）
            noiseModeSection
                .padding(.horizontal, 18)

            // 录音入口
            recordingSection
                .padding(.horizontal, 18)
                .padding(.top, 14)

            infoSection
                .padding(.horizontal, 18)
                .padding(.top, 14)

            Divider().padding(.horizontal, 18).padding(.top, 14)

            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "earbuds")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(state.isConnected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(state.isConnected ? L10n.statusConnected : L10n.statusDisconnected)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if !state.modelName.isEmpty {
                        Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Text(state.modelName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - 降噪模式

    @ViewBuilder
    private var noiseModeSection: some View {
        let modes = state.availableNoiseModes

        if modes.isEmpty {
            // 不支持任何模式时：如实说明，而不是画三个灰按钮
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.noModeSupport)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L10n.noModeSupportDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.modeTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Picker("", selection: Binding(
                    get: { state.noiseMode },
                    set: { controller.setNoiseMode($0) }
                )) {
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - 录音

    @ViewBuilder
    private var recordingSection: some View {
        // 这付耳机的录音是**存在耳机/充电盒里**的，不是把耳机当麦克风。
        // 官方 MMA 协议只定义了「能否本地录音」的状态位（0x0E ATTR 0x02），
        // 没有定义录音文件的列表/下载命令，充电盒也不向第三方暴露 GATT。
        // 所以这里如实告诉用户当前状态，并给出唯一可行的操作路径。
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.recordingTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                Image(systemName: recordSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(recordTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recordStateTitle)
                        .font(.system(size: 11, weight: .medium))
                    Text(L10n.recordingLocalHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// 录音能力未知（还没收到 0x0E 上报）时不要瞎猜。
    private var recordStateTitle: String {
        guard let allowed = state.canRecordLocally else { return L10n.recordingUnknown }
        return allowed ? L10n.recordingAvailable : L10n.recordingUnavailable
    }

    private var recordSymbol: String {
        guard let allowed = state.canRecordLocally else { return "questionmark.circle" }
        return allowed ? "record.circle" : "record.circle.fill"
    }

    private var recordTint: Color {
        guard let allowed = state.canRecordLocally else { return .secondary }
        return allowed ? .red : .secondary
    }

    // MARK: - 设备信息

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(L10n.infoUpdated)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(L10n.relativeTime(from: state.lastUpdate))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 底部操作栏

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                controller.refresh()
                onShowHUD()
            } label: {
                Label(L10n.actionRefresh, systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text(L10n.actionQuit)
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
