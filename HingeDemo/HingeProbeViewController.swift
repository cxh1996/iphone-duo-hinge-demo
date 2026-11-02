//
//  HingeProbeViewController.swift
//  UIKit 版铰链角度探针
//
//  API：UIHingeInteraction  （iOS 27.1+）
//  加到某个 view 上后，每次变化回调 update.hinge；hinge.angle 单位是「弧度」。
//  hinge.status：.closed / .partiallyOpen / .fullyOpen
//

import UIKit

final class HingeProbeViewController: UIViewController {

    private let angleLabel = UILabel()
    private let radLabel = UILabel()
    private let statusLabel = UILabel()
    private let logView = UITextView()

    private var interaction: UIHingeInteraction?
    private var count = 0
    private var lastLoggedAngle = -999.0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()

        let interaction = UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            guard let hinge = update.hinge else {
                self.statusLabel.text = "此设备没有铰链"
                return
            }

            let radians = Double(hinge.angle)
            let degrees = radians * 180.0 / .pi
            self.count += 1

            let statusName: String
            switch hinge.status {
            case .closed:        statusName = "closed"
            case .partiallyOpen: statusName = "partiallyOpen"
            case .fullyOpen:     statusName = "fullyOpen"
            default:             statusName = String(describing: hinge.status)
            }

            self.angleLabel.text = String(format: "%.1f°", degrees)
            self.radLabel.text = String(format: "%.4f rad", radians)
            self.statusLabel.text = "\(statusName)   ·   回调 \(self.count) 次"

            // 每变化 ≥1° 记一条，避免刷屏
            if abs(degrees - self.lastLoggedAngle) >= 1.0 {
                self.lastLoggedAngle = degrees
                self.appendLog(String(format: "%.1f°  %.3f rad  %@", degrees, radians, statusName))
            }
        }

        view.addInteraction(interaction)
        self.interaction = interaction
    }

    private func buildUI() {
        angleLabel.font = .systemFont(ofSize: 64, weight: .semibold)
        angleLabel.adjustsFontSizeToFitWidth = true

        radLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        radLabel.textColor = .secondaryLabel

        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.numberOfLines = 0

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.backgroundColor = .secondarySystemBackground
        logView.layer.cornerRadius = 10

        let stack = UIStackView(arrangedSubviews: [angleLabel, radLabel, statusLabel, logView])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    private func appendLog(_ line: String) {
        print("[HINGE-UIKit] \(line)")
        logView.text = line + "\n" + logView.text
    }
}
