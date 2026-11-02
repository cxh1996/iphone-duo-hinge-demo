//
//  PoseProbeView.swift （可选文件，不需要可直接删除）
//
//  铰链有三档状态，但「书本式 / 三脚架式」系统不给现成的 pose 值：
//  两者都是 partiallyOpen，靠折痕区域（division region）的方向来区分。
//
//  API：GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)  （iOS 27.1+）
//    .division  —— 折痕/分割区域，只在折叠时存在
//    .occlusion —— 被遮挡区域（灵动岛、摄像头等）
//
//  若 Xcode 提示 reservedRegions 的枚举名或返回类型的属性名不同，按提示改一个词即可。
//

import SwiftUI

@available(iOS 27.1, *)
struct PoseProbeView: View {
    @State private var pose = "—"
    @State private var crease = "—"

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                Text("pose: \(pose)")
                    .font(.callout.weight(.semibold))
                Text("division: \(crease)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .onAppear { refresh(proxy) }
            .onChange(of: proxy.size) { _, _ in refresh(proxy) }
        }
    }

    private func refresh(_ proxy: GeometryProxy) {
        let divisions = proxy.reservedRegions(kind: .division)
        guard let fold = divisions.first else {
            pose = "无折痕（完全展开 / 闭合）"
            crease = "none"
            return
        }

        // 若这里编译不过，把 fold.frame 换成 fold.bounds
        let rect = fold.frame
        crease = String(format: "x=%.0f y=%.0f w=%.0f h=%.0f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
        pose = rect.size.height > rect.size.width ? "半开·书本式（竖向折痕）" : "半开·三脚架式（横向折痕）"
    }
}
