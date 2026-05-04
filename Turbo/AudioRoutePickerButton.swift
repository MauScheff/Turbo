import SwiftUI
import MediaPlayer

struct AudioRoutePickerButton: UIViewRepresentable {
    enum Style {
        case text
        case icon
    }

    var style: Style = .text

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        configure(button)
        button.addTarget(context.coordinator, action: #selector(Coordinator.didTapRouteButton), for: .touchUpInside)
        context.coordinator.installHiddenRoutePickerIfNeeded(in: button)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        configure(uiView)
        context.coordinator.installHiddenRoutePickerIfNeeded(in: uiView)
    }

    private func configure(_ button: UIButton) {
        switch style {
        case .text:
            button.setTitle("Choose", for: .normal)
            button.setImage(nil, for: .normal)
            button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        case .icon:
            button.setTitle(nil, for: .normal)
            button.setImage(UIImage(systemName: "airplayaudio"), for: .normal)
            button.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold),
                forImageIn: .normal
            )
            button.tintColor = .label
            button.accessibilityLabel = "Choose audio output"
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        private weak var hiddenRouteButton: UIButton?
        private weak var hostView: UIView?

        func installHiddenRoutePickerIfNeeded(in hostView: UIView) {
            guard self.hostView !== hostView || hiddenRouteButton == nil else { return }
            self.hostView = hostView

            let picker = MPVolumeView(frame: .zero)
            picker.showsVolumeSlider = false
            picker.alpha = 0.01
            picker.isUserInteractionEnabled = false
            picker.translatesAutoresizingMaskIntoConstraints = false
            hostView.addSubview(picker)
            NSLayoutConstraint.activate([
                picker.widthAnchor.constraint(equalToConstant: 1),
                picker.heightAnchor.constraint(equalToConstant: 1),
                picker.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
                picker.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            ])
            hiddenRouteButton = picker.subviews.compactMap { $0 as? UIButton }.first
        }

        @objc func didTapRouteButton() {
            hiddenRouteButton?.sendActions(for: .touchUpInside)
        }
    }
}
