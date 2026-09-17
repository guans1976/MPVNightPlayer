import UIKit
import AVFoundation
import UniformTypeIdentifiers
import PhotosUI
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

final class PlayerViewController: UIViewController, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    private let video = VideoView()
    private let panel = UIScrollView()
    private let controls = UIStackView()
    private let openButton = UIButton(type: .system)
    private let photosButton = UIButton(type: .system)
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
    private var fullscreenConstraints: [NSLayoutConstraint] = []
    private var isFullscreen = false
    private let fullscreenHUD = UIStackView()
    private let fullscreenPlayButton = UIButton(type: .system)
    private var hideHUDTimer: Timer?
    private var mpv: OpaquePointer?
    private var timer: Timer?
    private var hasFile = false
    private var isPaused = true
    private var reachedEnd = false
    private var backgrounded = false
    private var resumeAfterInterruption = false
    private var pendingName = ""
    private var importInProgress = false
    private var importProgress: Progress?
    private var recentErrors: [String] = []
    private var importDirectory: URL?
    private var playbackError: String?

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
    override var prefersStatusBarHidden: Bool { isFullscreen }
    override var prefersHomeIndicatorAutoHidden: Bool { isFullscreen && fullscreenHUD.isHidden }

    override func accessibilityPerformEscape() -> Bool {
        guard isFullscreen else { return false }
        toggleFullscreen()
        return true
    }

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
        title.text = "MPV Night Player 1.0.3"
        title.font = .systemFont(ofSize: 22, weight: .bold)
        controls.addArrangedSubview(title)
        filename.text = "打开本地视频，调整暗部与色彩"
        filename.font = .systemFont(ofSize: 13)
        filename.textColor = .secondaryLabel
        filename.numberOfLines = 2
        controls.addArrangedSubview(filename)
        let fullscreenButton = UIButton(type: .system)
        fullscreenButton.setTitle("⛶ 全屏播放 / 隐藏菜单", for: .normal)
        fullscreenButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        fullscreenButton.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
        controls.addArrangedSubview(fullscreenButton)
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
        photosButton.setTitle("Photos / 从相册选择视频", for: .normal)
        photosButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        photosButton.addTarget(self, action: #selector(openPhotos), for: .touchUpInside)
        controls.addArrangedSubview(photosButton)
        let diagnostics = UIButton(type: .system)
        diagnostics.setTitle("查看播放错误", for: .normal)
        diagnostics.addTarget(self, action: #selector(showDiagnostics), for: .touchUpInside)
        controls.addArrangedSubview(diagnostics)
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
        fullscreenConstraints = [
            video.topAnchor.constraint(equalTo: view.topAnchor),
            video.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            video.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.topAnchor.constraint(equalTo: view.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            panel.heightAnchor.constraint(equalTo: safe.heightAnchor)
        ]
        buildFullscreenHUD()
        updateLayout(for: view.bounds.size)
        updatePlayButton()
    }

    private func buildFullscreenHUD() {
        fullscreenHUD.axis = .horizontal
        fullscreenHUD.spacing = 12
        fullscreenHUD.distribution = .fillEqually
        fullscreenHUD.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        fullscreenHUD.layer.cornerRadius = 12
        fullscreenHUD.isLayoutMarginsRelativeArrangement = true
        fullscreenHUD.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        fullscreenHUD.translatesAutoresizingMaskIntoConstraints = false
        let exitButton = UIButton(type: .system)
        exitButton.setTitle("退出全屏 / 菜单", for: .normal)
        exitButton.accessibilityLabel = "退出全屏并显示画面调节菜单"
        exitButton.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
        fullscreenPlayButton.addTarget(self, action: #selector(fullscreenTogglePlay), for: .touchUpInside)
        for button in [exitButton, fullscreenPlayButton] {
            button.tintColor = .white
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            fullscreenHUD.addArrangedSubview(button)
        }
        view.addSubview(fullscreenHUD)
        NSLayoutConstraint.activate([
            fullscreenHUD.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            fullscreenHUD.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            fullscreenHUD.widthAnchor.constraint(equalToConstant: 280)
        ])
        fullscreenHUD.isHidden = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(videoTapped))
        video.addGestureRecognizer(tap)
        video.accessibilityLabel = "视频画面"
        video.accessibilityHint = "轻点切换全屏操作按钮；退出全屏可显示调节菜单"
    }

    @objc private func toggleFullscreen() {
        isFullscreen.toggle()
        panel.isHidden = isFullscreen
        updateLayout(for: view.bounds.size, force: true)
        setNeedsStatusBarAppearanceUpdate()
        setFullscreenHUDVisible(isFullscreen)
        view.layoutIfNeeded()
        // Resize the existing Metal surface without reloading or restarting playback.
        video.setNeedsLayout()
        video.layoutIfNeeded()
    }

    @objc private func videoTapped() {
        if isFullscreen {
            setFullscreenHUDVisible(fullscreenHUD.isHidden)
        } else {
            toggleFullscreen()
        }
    }

    @objc private func fullscreenTogglePlay() {
        togglePlay()
        setFullscreenHUDVisible(true)
    }

    private func setFullscreenHUDVisible(_ visible: Bool) {
        hideHUDTimer?.invalidate()
        hideHUDTimer = nil
        fullscreenHUD.isHidden = !isFullscreen || !visible
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        // Keep controls available to VoiceOver users.
        guard isFullscreen, visible, !UIAccessibility.isVoiceOverRunning else { return }
        hideHUDTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.setFullscreenHUDVisible(false)
        }
    }

    private func updateLayout(for size: CGSize, force: Bool = false) {
        let wide = size.width > size.height
        guard force || wide != isWide else { return }
        NSLayoutConstraint.deactivate(portrait + landscape + fullscreenConstraints)
        NSLayoutConstraint.activate(isFullscreen ? fullscreenConstraints : (wide ? landscape : portrait))
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
            photosButton.isEnabled = false
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
            photosButton.isEnabled = false
            return
        }
        mpv_request_log_messages(handle, "warn")
        mpv_observe_property(handle, 1, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 2, "eof-reached", MPV_FORMAT_FLAG)
        // Drain on the main run loop: no C callbacks can outlive this controller.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.readEvents() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func openVideo() {
        guard !importInProgress, mpv != nil else { return }
        // Import mode lets the provider finish downloading/copying before calling us.
        // .data includes MOV/MKV even when the provider reports only generic data.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        status.text = "等待文件选择器交付视频；云端文件请先下载完成"
        status.textColor = .secondaryLabel
        present(picker, animated: true)
    }

    @objc private func openPhotos() {
        guard !importInProgress else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            showError("所选项目未提供视频文件")
            return
        }
        beginImport("正在从相册导入；iCloud 视频可能需要下载…")
        importProgress = provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
            guard let self else { return }
            do {
                if let error { throw error }
                guard let url else { throw CocoaError(.fileReadUnknown) }
                // Copy before the provider deletes its temporary URL on callback return.
                let imported = try Self.copyForPlayback(url)
                DispatchQueue.main.async { self.finishImport(imported, name: provider.suggestedName ?? url.lastPathComponent) }
            } catch {
                DispatchQueue.main.async { self.importFailed(error) }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        status.text = "已取消文件选择"
        status.textColor = .secondaryLabel
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true)
        guard let url = urls.first else {
            showError("文件选择器未返回文件，请尝试在“文件”App 中分享给 MPV Night Player")
            return
        }
        // asCopy:true gives us a local copy; do not ask the provider to coordinate it again.
        importFile(url, coordinate: false)
    }

    func openExternalVideo(_ url: URL) -> Bool {
        loadViewIfNeeded()
        guard url.isFileURL, mpv != nil, !importInProgress else { return false }
        if presentedViewController != nil { dismiss(animated: true) }
        importFile(url, coordinate: true)
        return true
    }

    private func importFile(_ url: URL, coordinate: Bool) {
        guard mpv != nil, !importInProgress else { return }
        beginImport("已收到文件：\(url.lastPathComponent)，正在导入…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result: Result<URL, Error>
            if coordinate {
                var coordinationError: NSError?
                var imported: Result<URL, Error>?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                    imported = Result { try Self.copyForPlayback(readableURL) }
                }
                result = imported ?? .failure(coordinationError ?? NSError(domain: NSCocoaErrorDomain,
                    code: CocoaError.fileReadUnknown.rawValue))
            } else {
                result = Result { try Self.copyForPlayback(url) }
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let local): self.finishImport(local, name: url.lastPathComponent)
                case .failure(let error): self.importFailed(error)
                }
            }
        }
    }

    nonisolated private static func copyForPlayback(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("MPVImport-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: destination)
            let attributes = try fm.attributesOfItem(atPath: destination.path)
            guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
                throw NSError(domain: "MPVNightPlayer", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "视频文件为空，请先完成云端下载"])
            }
            return destination
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    private func beginImport(_ message: String) {
        importInProgress = true
        openButton.isEnabled = false
        photosButton.isEnabled = false
        status.text = message
        status.textColor = .secondaryLabel
    }

    private func importFailed(_ error: Error) {
        importInProgress = false
        importProgress = nil
        openButton.isEnabled = mpv != nil
        photosButton.isEnabled = mpv != nil
        showError("导入失败：\(error.localizedDescription)")
    }

    private func finishImport(_ url: URL, name: String) {
        importInProgress = false
        importProgress = nil
        // Stop the old reader before deleting its imported file.
        timer?.invalidate()
        timer = nil
        if let handle = mpv { mpv_terminate_destroy(handle) }
        mpv = nil
        if let directory = importDirectory { try? FileManager.default.removeItem(at: directory) }
        importDirectory = url.deletingLastPathComponent()
        hasFile = false
        isPaused = true
        reachedEnd = false
        playbackError = nil
        recentErrors.removeAll()
        view.layoutIfNeeded()
        video.layoutIfNeeded()
        setupPlayer()
        openButton.isEnabled = mpv != nil
        photosButton.isEnabled = mpv != nil
        guard mpv != nil else { return }
        configureAudio()
        pendingName = name
        status.text = "正在打开 \(name)…"
        status.textColor = .secondaryLabel
        updatePlayButton()
        command(["loadfile", url.path, "replace"])
    }

    @objc private func showDiagnostics() {
        let details = ([playbackError].compactMap { $0 } + recentErrors).joined(separator: "\n")
        let message = details.isEmpty ? (status.text ?? "尚未记录错误") : details
        let alert = UIAlertController(title: "播放诊断 · 1.0.3", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "复制", style: .default) { _ in UIPasteboard.general.string = message })
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(alert, animated: true)
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
        fullscreenPlayButton.isEnabled = hasFile
        playButton.setTitle(reachedEnd ? "Replay / 重播" : (isPaused ? "Play / 播放" : "Pause / 暂停"), for: .normal)
        fullscreenPlayButton.setTitle(playButton.title(for: .normal), for: .normal)
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
                setString("pause", backgrounded ? "yes" : "no")
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
            case MPV_EVENT_LOG_MESSAGE:
                guard let data = event.data else { continue }
                let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                let text = String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines)
                recentErrors.append(String(cString: message.prefix) + ": " + text)
                if recentErrors.count > 12 { recentErrors.removeFirst() }
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
        if isFullscreen { toggleFullscreen() }
        playbackError = message
        status.text = message + "（可点“查看播放错误”复制详情）"
        status.textColor = .systemOrange
    }

    deinit {
        hideHUDTimer?.invalidate()
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let mpv { mpv_terminate_destroy(mpv) }
        importProgress?.cancel()
        if let directory = importDirectory { try? FileManager.default.removeItem(at: directory) }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
