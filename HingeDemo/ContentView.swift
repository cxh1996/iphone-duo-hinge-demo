//
//  ContentView.swift
//  SwiftUI 版铰链角度探针
//
//  API：View.onHingeChange(isEnabled:_:)  （iOS 27.1+）
//  回调给的是「上一帧上下文 / 当前上下文」，current.hinge 为 nil 表示该设备没有铰链。
//  hinge.status 只有三档：closed / partiallyOpen / fullyOpen
//  hinge.angle 是 SwiftUI 的 Angle 类型，用 .degrees / .radians 取数值
//
//  注意：系统只保证「持续更新」，更新频率与精度属于系统策略，可能随系统状态变化。
//

import SwiftUI

struct ContentView: View {
    @State private var statusText = "等待首次回调"
    @State private var degrees: Double = 0
    @State private var radians: Double = 0
    @State private var updateCount = 0
    @State private var rows: [Row] = []

    struct Row: Identifiable {
        let id = UUID()
        let time: Date
        let status: String
        let deg: Double
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 大号读数
            VStack(alignment: .leading, spacing: 4) {
                Text("hinge.angle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", degrees))
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("°")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
                Text(String(format: "%.4f rad", radians))
                    .font(.footnote)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }

            // 0° ~ 180° 刻度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.18))
                    Capsule()
                        .fill(statusColor)
                        .frame(width: max(6, geo.size.width * min(1, max(0, degrees / 180))))
                }
            }
            .frame(height: 10)

            // 状态 + 回调计数
            HStack(spacing: 10) {
                Label(statusText, systemImage: "rectangle.split.2x1")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(statusColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor)
                Spacer()
                Text("\(updateCount) 次回调")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("最近角度变化（变化 ≥1° 记一条）")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        HStack {
                            Text(Self.timeFormatter.string(from: row.time))
                                .monospaced()
                                .foregroundStyle(.secondary)
                            Text(row.status)
                                .foregroundStyle(statusColor(for: row.status))
                            Spacer()
                            Text(String(format: "%.1f°", row.deg))
                                .monospacedDigit()
                                .fontWeight(.medium)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .padding(24)
        // ===== 核心：注册铰链回调 =====
        .onHingeChange { _, current in
            // Swift 6 严格并发下若报“捕获状态”相关错误，把整段包进 MainActor.assumeIsolated { ... }
            guard let hinge = current.hinge else {
                statusText = "此设备没有铰链"
                return
            }

            let name: String
            switch hinge.status {
            case .closed:        name = "closed"
            case .partiallyOpen: name = "partiallyOpen"
            case .fullyOpen:     name = "fullyOpen"
            default:             name = String(describing: hinge.status)
            }

            updateCount += 1
            degrees = hinge.angle.degrees
            radians = hinge.angle.radians
            statusText = name

            // 只在角度或状态明显变化时记一条，避免刷屏
            if let last = rows.first, last.status == name, abs(last.deg - degrees) < 1.0 {
                return
            }
            rows.insert(Row(time: Date(), status: name, deg: degrees), at: 0)
            if rows.count > 60 { rows.removeLast(rows.count - 60) }

            // 同时打到控制台，方便用 Console.app 过滤 [HINGE]
            print("[HINGE] status=\(name) deg=\(String(format: "%.2f", degrees)) rad=\(String(format: "%.4f", radians))")
        }
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "closed":        return .red
        case "partiallyOpen": return .orange
        case "fullyOpen":     return .green
        default:              return .gray
        }
    }

    private var statusColor: Color { statusColor(for: statusText) }
}
