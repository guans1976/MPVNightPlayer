import UIKit
import AVFoundation
import UniformTypeIdentifiers
import Metal
import Libmpv

// MoltenVK can temporarily request a 1x1 drawable during presentation.
// Ignore that size so a paused frame remains visible after rotation.
final class VideoLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1 && newValue.height > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

final class VideoView: UIView {
    override class var layerClass: AnyClass { VideoLayer.self }
    var videoLayer: VideoLayer { layer as! VideoLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        videoLayer.contentsScale = scale
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

final class PlayerViewController: UIViewController, UIDocumentPickerDelegate {
    private let video = VideoView()
    private let panel = UIScrollView()
    private let controls = UIStackView()
    private let openButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let status = UILabel()
    private let filename = UILabel()
    private var sliders: [UISlider] = []
    private var values: [UILabel] = []
    private let properties = ["brightness", "gamma", "contrast", "saturation"]
    private let names = ["Brightness / 亮度", "Gamma / 伽马", "Contrast / 对比度", "Saturation / 饱和度"]
    private var portrait: [NSLayoutConstraint] = []
    private var landscape: [NSLayoutConstraint] = []
    private var isWide: Bool?
    private var mpv: OpaquePointer?
    private var timer: Timer?
    private var hasFile = false
    private var isPaused = true
    private var reachedEnd = false
    private var backgrounded = false
    private var resumeAfterInterruption = false
    private var pendingName = ""
    // Keep access while libmpv may still be reading a replaced file.
    // All scopes are balanced when the player shuts down.
    private var scopedURLs: [URL] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildInterface()
        configureAudio()
        setupPlayer()
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    private func configureAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            showError("音频初始化失败：\(error.localizedDescription)")
        }
    }

    private func buildInterface() {
        video.backgroundColor = .black
        video.videoLayer.device = MTLCreateSystemDefaultDevice()
        video.videoLayer.framebufferOnly = true
        video.videoLayer.isOpaque = true
        panel.backgroundColor = UIColor(white: 0.08, alpha: 1)
        panel.layer.cornerRadius = 16
        controls.axis = .vertical
        controls.spacing = 12
        for child in [video, panel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        controls.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: panel.contentLayoutGuide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: panel.contentLayoutGuide.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: panel.contentLayoutGuide.topAnchor, constant: 16),
            controls.bottomAnchor.constraint(equalTo: panel.contentLayoutGuide.bottomAnchor, constant: -16),
            controls.widthAnchor.constraint(equalTo: panel.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        let title = UILabel()
        title.text = "MPV Night Player"
        title.font = .systemFont(ofSize: 22, weight: .bold)
        controls.addArrangedSubview(title)
        filename.text = "打开本地视频，调整暗部与色彩"
        filename.font = .systemFont(ofSize: 13)
        filename.textColor = .secondaryLabel
        filename.numberOfLines = 2
        controls.addArrangedSubview(filename)
        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        openButton.setTitle("Open Video / 打开", for: .normal)
        openButton.addTarget(self, action: #selector(openVideo), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        for button in [openButton, playButton] {
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            buttons.addArrangedSubview(button)
        }
        controls.addArrangedSubview(buttons)
        for index in properties.indices {
            let row = UIStackView()
            row.axis = .horizontal
            let label = UILabel()
            label.text = names[index]
            label.font = .systemFont(ofSize: 14)
            let value = UILabel()
            value.text = "0"
            value.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
            value.textAlignment = .right
            row.addArrangedSubview(label)
            row.addArrangedSubview(value)
            controls.addArrangedSubview(row)
            let slider = UISlider()
            slider.minimumValue = -100
            slider.maximumValue = 100
            slider.value = 0
            slider.tag = index
            slider.isContinuous = true
            slider.accessibilityLabel = names[index]
            slider.addTarget(self, action: #selector(adjust(_:)), for: .valueChanged)
            controls.addArrangedSubview(slider)
            sliders.append(slider)
            values.append(value)
        }
        let reset = UIButton(type: .system)
        reset.setTitle("Reset / 恢复原始画面", for: .normal)
        reset.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        reset.addTarget(self, action: #selector(resetImage), for: .touchUpInside)
        controls.addArrangedSubview(reset)
        status.text = "请选择 MP4、MOV、MKV 等视频"
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        status.accessibilityTraits = .updatesFrequently
        controls.addArrangedSubview(status)
        let safe = view.safeAreaLayoutGuide
        portrait = [
            video.topAnchor.constraint(equalTo: safe.topAnchor),
            video.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            video.heightAnchor.constraint(equalTo: safe.heightAnchor, multiplier: 0.36),
            panel.topAnchor.constraint(equalTo: video.bottomAnchor, constant: 8),
            panel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            panel.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        ]
        landscape = [
            video.topAnchor.constraint(equalTo: safe.topAnchor),
            video.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            video.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: video.trailingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            panel.topAnchor.constraint(equalTo: safe.topAnchor),
            panel.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            panel.widthAnchor.constraint(equalTo: safe.widthAnchor, multiplier: 0.38)
        ]
        updateLayout(for: view.bounds.size)
        updatePlayButton()
    }

    private func updateLayout(for size: CGSize) {
        let wide = size.width > size.height
        guard wide != isWide else { return }
        NSLayoutConstraint.deactivate(portrait + landscape)
        NSLayoutConstraint.activate(wide ? landscape : portrait)
        isWide = wide
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        updateLayout(for: size)
        coordinator.animate(alongsideTransition: { _ in self.view.layoutIfNeeded() })
    }

    private func setupPlayer() {
        guard video.videoLayer.device != nil, let handle = mpv_create() else {
            showError("无法初始化 Metal / libmpv 播放器")
            openButton.isEnabled = false
            return
        }
        mpv = handle
        // MPVKit's moltenvk context accepts the CAMetalLayer object address as wid.
        var windowID = Int64(Int(bitPattern: Unmanaged.passUnretained(video.videoLayer).toOpaque()))
        var result = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &windowID)
        let options = [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"), ("keep-open", "yes"), ("idle", "yes"),
            ("target-colorspace-hint", "no"), ("input-default-bindings", "no")
        ]
        for (name, value) in options where result >= 0 {
            result = mpv_set_option_string(handle, name, value)
        }
        if result >= 0 { result = mpv_initialize(handle) }
        guard result >= 0 else {
            showMPVError(result, operation: "播放器初始化")
            mpv_terminate_destroy(handle)
            mpv = nil
            openButton.isEnabled = false
            return
        }
        mpv_observe_property(handle, 1, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 2, "eof-reached", MPV_FORMAT_FLAG)
        // Drain on the main run loop: no C callbacks can outlive this controller.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.readEvents() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func openVideo() {
        // .data intentionally includes MKV/AVI and files whose provider has no movie UTI.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .video, .data], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, mpv != nil else { return }
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        configureAudio()
        pendingName = url.lastPathComponent
        status.text = "正在打开 \(pendingName)…"
        status.textColor = .secondaryLabel
        hasFile = false
        reachedEnd = false
        updatePlayButton()
        if command(["loadfile", url.path, "replace"]) {
            setString("pause", "no")
        }
    }

    @discardableResult private func command(_ arguments: [String]) -> Bool {
        guard let mpv else { return false }
        let allocated = arguments.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = allocated.map { $0.map { UnsafePointer<CChar>($0) } }
        pointers.append(nil)
        let result = mpv_command_async(mpv, 0, &pointers)
        if result < 0 { showMPVError(result, operation: "播放命令") }
        return result >= 0
    }

    private func setString(_ name: String, _ value: String) {
        guard let mpv else { return }
        let result = value.withCString { bytes -> Int32 in
            // MPV_FORMAT_STRING takes char **, not the character buffer itself.
            // libmpv copies the value before this closure returns.
            var pointer: UnsafePointer<CChar>? = bytes
            return mpv_set_property_async(mpv, 0, name, MPV_FORMAT_STRING, &pointer)
        }
        if result < 0 { showMPVError(result, operation: name) }
    }

    @objc private func togglePlay() {
        guard hasFile else { return }
        if reachedEnd {
            command(["seek", "0", "absolute"])
            setString("pause", "no")
        } else {
            setString("pause", isPaused ? "no" : "yes")
        }
    }

    @objc private func adjust(_ slider: UISlider) {
        let value = Int(slider.value.rounded())
        values[slider.tag].text = "\(value)"
        slider.accessibilityValue = "\(value)"
        setString(properties[slider.tag], "\(value)")
    }

    @objc private func resetImage() {
        for slider in sliders {
            slider.value = 0
            adjust(slider)
        }
    }

    private func updatePlayButton() {
        playButton.isEnabled = hasFile
        playButton.setTitle(reachedEnd ? "Replay / 重播" : (isPaused ? "Play / 播放" : "Pause / 暂停"), for: .normal)
        UIApplication.shared.isIdleTimerDisabled = hasFile && !isPaused && !reachedEnd && !backgrounded
    }

    private func readEvents() {
        guard let mpv else { return }
        // Cap each pass to avoid starving touch events.
        for _ in 0..<100 {
            guard let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                hasFile = true
                filename.text = pendingName
                status.text = "已打开 · 实时调节画面，Reset 恢复为 0"
                status.textColor = .secondaryLabel
                for slider in sliders { adjust(slider) }
                updatePlayButton()
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.data else { continue }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard property.format == MPV_FORMAT_FLAG, let value = property.data else { continue }
                let flag = value.assumingMemoryBound(to: CInt.self).pointee != 0
                switch String(cString: property.name) {
                case "pause": isPaused = flag
                case "eof-reached": reachedEnd = flag
                default: break
                }
                updatePlayButton()
            case MPV_EVENT_END_FILE:
                guard let data = event.data else { continue }
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    hasFile = false
                    showMPVError(end.error, operation: "无法播放此文件")
                    updatePlayButton()
                }
            case MPV_EVENT_COMMAND_REPLY, MPV_EVENT_SET_PROPERTY_REPLY:
                if event.error < 0 { showMPVError(event.error, operation: "播放/画面设置") }
            default: break
            }
        }
    }

    @objc private func enterBackground() {
        backgrounded = true
        setString("pause", "yes")
        setString("vid", "no")
        updatePlayButton()
    }

    @objc private func enterForeground() {
        backgrounded = false
        configureAudio()
        setString("vid", "auto")
        // Remain paused until the user presses Play.
        updatePlayButton()
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            resumeAfterInterruption = hasFile && !isPaused
            setString("pause", "yes")
        } else {
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if resumeAfterInterruption && options.contains(.shouldResume) && !backgrounded {
                configureAudio()
                setString("pause", "no")
            }
            resumeAfterInterruption = false
        }
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            setString("pause", "yes")
        }
    }

    private func showMPVError(_ code: Int32, operation: String) {
        showError("\(operation)：\(String(cString: mpv_error_string(code)))")
    }

    private func showError(_ message: String) {
        status.text = message
        status.textColor = .systemOrange
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let mpv { mpv_terminate_destroy(mpv) }
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
