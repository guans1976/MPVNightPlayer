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
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.contentsScale = scale
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

final class PlayerViewController: UIViewController, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    private let denoiseControl = UISegmentedControl(items: ["关", "低", "中", "高"])
    private let shadowSlider = UISlider()
    private let detailSlider = UISlider()
    private let enhancementSummary = UILabel()
    private var comparingOriginal = false
    private var compareButtons: [UIButton] = []
    private var enhancementReady = false
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
    private let scaleButton = UIButton(type: .system)
    private var fillScreen = true
    private var progressSliders: [UISlider] = []
    private var timeLabels: [UILabel] = []
    private var duration: Double = 0
    private var position: Double = 0
    private var seekable = false
    private var scrubbing = false
    private var waitingForSeek = false
    private var resizeWork: DispatchWorkItem?
    private var resizingVideo = false
    private var renderedSize = CGSize.zero
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
        title.text = "MPV Night Player 1.0.5"
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
        controls.addArrangedSubview(makeTimeline())
        photosButton.setTitle("Photos / 从相册选择视频", for: .normal)
        photosButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        photosButton.addTarget(self, action: #selector(openPhotos), for: .touchUpInside)
        controls.addArrangedSubview(photosButton)
        let diagnostics = UIButton(type: .system)
        diagnostics.setTitle("查看播放错误", for: .normal)
        diagnostics.addTarget(self, action: #selector(showDiagnostics), for: .touchUpInside)
        controls.addArrangedSubview(diagnostics)
        buildEnhancementControls()
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
        fullscreenHUD.axis = .vertical
        fullscreenHUD.spacing = 12
        fullscreenHUD.distribution = .fill
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
        let buttonRow = UIStackView()
        buttonRow.axis = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually
        scaleButton.setTitle("铺满 · 切换", for: .normal)
        scaleButton.addTarget(self, action: #selector(toggleScaleMode), for: .touchUpInside)
        for button in [exitButton, fullscreenPlayButton, scaleButton] {
            button.tintColor = .white
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            buttonRow.addArrangedSubview(button)
        }
        fullscreenHUD.addArrangedSubview(buttonRow)
        fullscreenHUD.addArrangedSubview(makeTimeline())
        fullscreenHUD.addArrangedSubview(makeCompareButton())
        view.addSubview(fullscreenHUD)
        NSLayoutConstraint.activate([
            fullscreenHUD.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            fullscreenHUD.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            fullscreenHUD.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12)
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
        applyScaleMode()
        // Refresh the MPVKit output after the new Metal surface size is committed.
        video.setNeedsLayout()
        video.layoutIfNeeded()
        scheduleVideoResize()
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
        guard isFullscreen, visible, !scrubbing, !comparingOriginal, !isPaused, !UIAccessibility.isVoiceOverRunning else { return }
        hideHUDTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.setFullscreenHUDVisible(false)
        }
    }

    private func makeTimeline() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2
        let label = UILabel()
        label.text = "00:00 / --:--"
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.isEnabled = false
        slider.accessibilityLabel = "播放进度"
        slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        slider.addTarget(self, action: #selector(seekBegan(_:)), for: .touchDown)
        slider.addTarget(self, action: #selector(seekChanged(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(seekEnded(_:)), for: [.touchUpInside, .touchUpOutside])
        slider.addTarget(self, action: #selector(seekCancelled(_:)), for: .touchCancel)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(slider)
        progressSliders.append(slider)
        timeLabels.append(label)
        return stack
    }

    private func clockText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let value = Int(min(seconds, Double(Int32.max)))
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func updateTimeline(preview: Double? = nil) {
        let current = preview ?? position
        let text = clockText(current) + " / " + (duration > 0 ? clockText(duration) : "--:--")
        for label in timeLabels { label.text = text }
        for slider in progressSliders {
            slider.isEnabled = hasFile && seekable && duration > 0
            if !scrubbing && !waitingForSeek {
                slider.value = duration > 0 ? Float(min(max(position / duration, 0), 1)) : 0
            }
            slider.accessibilityValue = text
        }
    }

    @objc private func seekBegan(_ slider: UISlider) {
        scrubbing = true
        hideHUDTimer?.invalidate()
        hideHUDTimer = nil
    }

    @objc private func seekChanged(_ slider: UISlider) {
        // VoiceOver changes slider values without touch-down/up events.
        if !slider.isTracking && !scrubbing { seekEnded(slider); return }
        updateTimeline(preview: Double(slider.value) * duration)
    }

    @objc private func seekEnded(_ slider: UISlider) {
        scrubbing = false
        guard hasFile, seekable, duration > 0 else { updateTimeline(); return }
        let target = min(max(Double(slider.value) * duration, 0), duration)
        waitingForSeek = true
        if !command(["seek", String(target), "absolute+exact"], replyID: 2001) {
            waitingForSeek = false
        }
        position = target
        for other in progressSliders { other.value = slider.value }
        updateTimeline(preview: target)
        if isFullscreen { setFullscreenHUDVisible(true) }
    }

    @objc private func seekCancelled(_ slider: UISlider) {
        scrubbing = false
        updateTimeline()
        if isFullscreen { setFullscreenHUDVisible(true) }
    }

    @objc private func toggleScaleMode() {
        fillScreen.toggle()
        applyScaleMode()
        setFullscreenHUDVisible(true)
    }

    private func applyScaleMode() {
        scaleButton.setTitle(fillScreen ? "铺满 · 切换" : "完整 · 切换", for: .normal)
        setString("keepaspect", "yes")
        setString("video-unscaled", "no")
        setString("panscan", isFullscreen && fillScreen ? "1" : "0")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        video.layoutIfNeeded()
        scheduleVideoResize()
    }

    private func scheduleVideoResize() {
        guard hasFile, !backgrounded, !resizingVideo else { return }
        let size = video.videoLayer.drawableSize
        guard size.width > 1, size.height > 1, size != renderedSize else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hasFile, !self.backgrounded, !self.resizingVideo else { return }
            self.renderedSize = self.video.videoLayer.drawableSize
            self.resizingVideo = true
            // MPVKit 1.0.0's moltenvk context only reads drawableSize at reconfiguration.
            // Re-select video after the disable reply, preserving the current audio,
            // playback position and pause state instead of reloading the file.
            if !self.setString("vid", "no", replyID: 1001) { self.resizingVideo = false }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
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
            ("target-colorspace-hint", "no"), ("input-default-bindings", "no"),
            ("keepaspect", "yes"), ("video-unscaled", "no"),
            ("panscan", isFullscreen && fillScreen ? "1" : "0")
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
        installEnhancementShader()
        mpv_observe_property(handle, 1, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 2, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 3, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 4, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 5, "seekable", MPV_FORMAT_FLAG)
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
        resizeWork?.cancel()
        resizingVideo = false
        renderedSize = .zero
        duration = 0
        position = 0
        seekable = false
        scrubbing = false
        waitingForSeek = false
        updateTimeline()
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
        let alert = UIAlertController(title: "播放诊断 · 1.0.4", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "复制", style: .default) { _ in UIPasteboard.general.string = message })
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(alert, animated: true)
    }

    @discardableResult private func command(_ arguments: [String], replyID: UInt64 = 0) -> Bool {
        guard let mpv else { return false }
        let allocated = arguments.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = allocated.map { $0.map { UnsafePointer<CChar>($0) } }
        pointers.append(nil)
        let result = mpv_command_async(mpv, replyID, &pointers)
        if result < 0 { showMPVError(result, operation: "播放命令") }
        return result >= 0
    }

    @discardableResult private func setString(_ name: String, _ value: String, replyID: UInt64 = 0) -> Bool {
        guard let mpv else { return false }
        let result = value.withCString { bytes -> Int32 in
            // MPV_FORMAT_STRING takes char **, not the character buffer itself.
            // libmpv copies the value before this closure returns.
            var pointer: UnsafePointer<CChar>? = bytes
            return mpv_set_property_async(mpv, replyID, name, MPV_FORMAT_STRING, &pointer)
        }
        if result < 0 { showMPVError(result, operation: name) }
        return result >= 0
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
        setString(properties[slider.tag], comparingOriginal ? "0" : "\(value)")
    }

    @objc private func resetImage() {
        comparingOriginal = false
        denoiseControl.selectedSegmentIndex = 0
        shadowSlider.value = 0
        detailSlider.value = 0
        applyEnhancement()
        for slider in sliders {
            slider.value = 0
            adjust(slider)
        }
    }


    private func buildEnhancementControls() {
        let heading = UILabel()
        heading.text = "夜景画质 · 试用版"
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        controls.addArrangedSubview(heading)
        let noiseLabel = UILabel()
        noiseLabel.text = "降噪（建议先试低档）"
        noiseLabel.font = .systemFont(ofSize: 14)
        controls.addArrangedSubview(noiseLabel)
        denoiseControl.selectedSegmentIndex = 1
        denoiseControl.accessibilityLabel = "降噪强度"
        denoiseControl.addTarget(self, action: #selector(enhancementChanged), for: .valueChanged)
        controls.addArrangedSubview(denoiseControl)
        for (labelText, slider) in [("暗部增强", shadowSlider), ("清晰度", detailSlider)] {
            let label = UILabel()
            label.text = labelText
            label.font = .systemFont(ofSize: 14)
            controls.addArrangedSubview(label)
            slider.minimumValue = 0
            slider.maximumValue = 100
            slider.value = 0
            slider.accessibilityLabel = labelText
            slider.addTarget(self, action: #selector(enhancementChanged), for: .valueChanged)
            controls.addArrangedSubview(slider)
        }
        enhancementSummary.font = .systemFont(ofSize: 12)
        enhancementSummary.textColor = .secondaryLabel
        enhancementSummary.numberOfLines = 0
        controls.addArrangedSubview(enhancementSummary)
        let preset = UIButton(type: .system)
        preset.setTitle("一键夜景：低降噪 + 适度暗部增强", for: .normal)
        preset.titleLabel?.font = .systemFont(ofSize: 14)
        preset.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        preset.addTarget(self, action: #selector(nightPreset), for: .touchUpInside)
        controls.addArrangedSubview(preset)
        controls.addArrangedSubview(makeCompareButton())
    }

    private func makeCompareButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("按住看原图", for: .normal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: #selector(compareBegan), for: .touchDown)
        button.addTarget(self, action: #selector(compareReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        button.accessibilityHint = "按住暂时关闭全部画面调节，松手恢复；VoiceOver 双击切换"
        button.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "切换原图对比", target: self, selector: #selector(accessibleCompare))
        ]
        // VoiceOver activation sends touchUpInside without touchDown.
        button.addTarget(self, action: #selector(compareActivated), for: .primaryActionTriggered)
        compareButtons.append(button)
        return button
    }

    @objc private func compareReleased() {
        if !UIAccessibility.isVoiceOverRunning { compareEnded() }
    }

    @objc private func compareActivated() {
        if UIAccessibility.isVoiceOverRunning { _ = accessibleCompare() }
    }

    @objc private func accessibleCompare() -> Bool {
        if comparingOriginal { compareEnded() } else { compareBegan() }
        return true
    }

    @objc private func compareBegan() {
        comparingOriginal = true
        hideHUDTimer?.invalidate()
        for property in properties { setString(property, "0") }
        applyEnhancement()
    }

    @objc private func compareEnded() {
        guard comparingOriginal else { return }
        comparingOriginal = false
        for slider in sliders { adjust(slider) }
        applyEnhancement()
        if isFullscreen { setFullscreenHUDVisible(true) }
    }

    @objc private func enhancementChanged() { applyEnhancement() }

    @objc private func nightPreset() {
        comparingOriginal = false
        for slider in sliders { slider.value = 0; adjust(slider) }
        denoiseControl.selectedSegmentIndex = 1
        shadowSlider.value = 35
        detailSlider.value = 0
        applyEnhancement()
    }

    private func applyEnhancement() {
        let level = max(0, min(3, denoiseControl.selectedSegmentIndex))
        let strengths: [Float] = [0, 0.3, 0.6, 1]
        let noise: Float = comparingOriginal ? 0 : strengths[level]
        let shadow: Float = comparingOriginal ? 0 : shadowSlider.value / 100
        let detail: Float = comparingOriginal ? 0 : detailSlider.value / 100
        if enhancementReady {
            setString("glsl-shader-opts", "night_noise=\(noise),night_shadow=\(shadow),night_detail=\(detail)")
        }
        let label = ["关", "低", "中", "高"][level]
        enhancementSummary.text = comparingOriginal ? "正在看原图 · 松手恢复" :
            "降噪：\(label) · 暗部：\(Int(shadowSlider.value)) · 清晰度：\(Int(detailSlider.value))\n强降噪可能损失细节；4K 卡顿或发热时请降低档位。"
        shadowSlider.accessibilityValue = "\(Int(shadowSlider.value))"
        detailSlider.accessibilityValue = "\(Int(detailSlider.value))"
        for button in compareButtons {
            button.setTitle(comparingOriginal ? "原图对比中 · 松手恢复" : "按住看原图", for: .normal)
        }
    }

    private func installEnhancementShader() {
        enhancementReady = false
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let url = directory.appendingPathComponent("night-v1.glsl")
            try Self.nightShader.write(to: url, atomically: true, encoding: .utf8)
            guard let mpv else { return }
            let result = mpv_set_property_string(mpv, "glsl-shaders", url.path)
            guard result >= 0 else {
                showMPVError(result, operation: "画质滤镜初始化")
                return
            }
            enhancementReady = true
            applyEnhancement()
        } catch {
            showError("无法准备画质滤镜：\(error.localizedDescription)")
        }
    }

    // Original spatial bilateral filter: stronger chroma smoothing, conservative
    // luma smoothing. No temporal history, CPU frame copies or external model.
    // MAIN runs on source-sized RGB; OUTPUT adjusts shadows after color management.
    private static let nightShader = """
    //!PARAM night_noise
    //!TYPE DYNAMIC float
    //!MINIMUM 0
    //!MAXIMUM 1
    0.0

    //!PARAM night_shadow
    //!TYPE DYNAMIC float
    //!MINIMUM 0
    //!MAXIMUM 1
    0.0

    //!PARAM night_detail
    //!TYPE DYNAMIC float
    //!MINIMUM 0
    //!MAXIMUM 1
    0.0

    //!HOOK MAIN
    //!BIND HOOKED
    //!DESC Night spatial denoise
    //!WHEN night_noise 0 >
    vec4 hook() {
        vec4 c = HOOKED_tex(HOOKED_pos);
        vec3 luma = vec3(0.2126, 0.7152, 0.0722);
        float y = dot(c.rgb, luma);
        float sigma = mix(0.025, 0.09, night_noise);
        vec3 total = vec3(0.0);
        float weights = 0.0;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                vec3 p = HOOKED_tex(HOOKED_pos + vec2(float(i), float(j)) * HOOKED_pt).rgb;
                float delta = dot(p, luma) - y;
                float spatial = (i == 0 ? 2.0 : 1.0) * (j == 0 ? 2.0 : 1.0);
                float w = spatial * exp(-delta * delta / (2.0 * sigma * sigma));
                total += p * w;
                weights += w;
            }
        }
        vec3 avg = total / max(weights, 0.0001);
        float ay = dot(avg, luma);
        float outY = mix(y, ay, 0.55 * night_noise);
        vec3 chroma = mix(c.rgb - vec3(y), avg - vec3(ay), 0.85 * night_noise);
        return vec4(max(vec3(outY) + chroma, vec3(0.0)), c.a);
    }

    //!HOOK MAIN
    //!BIND HOOKED
    //!DESC Night gentle detail
    //!WHEN night_detail 0 >
    vec4 hook() {
        vec4 c = HOOKED_tex(HOOKED_pos);
        vec3 n = HOOKED_tex(HOOKED_pos + vec2(0.0, HOOKED_pt.y)).rgb;
        vec3 s = HOOKED_tex(HOOKED_pos - vec2(0.0, HOOKED_pt.y)).rgb;
        vec3 e = HOOKED_tex(HOOKED_pos + vec2(HOOKED_pt.x, 0.0)).rgb;
        vec3 w = HOOKED_tex(HOOKED_pos - vec2(HOOKED_pt.x, 0.0)).rgb;
        vec3 low = min(c.rgb, min(min(n, s), min(e, w)));
        vec3 high = max(c.rgb, max(max(n, s), max(e, w)));
        vec3 sharpened = c.rgb + (c.rgb - (n + s + e + w) * 0.25) * night_detail * 0.5;
        return vec4(clamp(sharpened, low, high), c.a);
    }

    //!HOOK OUTPUT
    //!BIND HOOKED
    //!DESC Night protected shadow lift
    //!WHEN night_shadow 0 >
    vec4 hook() {
        vec4 c = HOOKED_tex(HOOKED_pos);
        float y = max(dot(c.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0);
        float mask = 1.0 - smoothstep(0.05, 0.65, y);
        float gain = 1.0 + 1.0 * night_shadow * mask;
        return vec4(c.rgb * gain, c.a);
    }
    """


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
                renderedSize = video.videoLayer.drawableSize
                updateTimeline()
                setString("pause", backgrounded ? "yes" : "no")
                filename.text = pendingName
                status.text = "已打开 · 实时调节画面，Reset 恢复为 0"
                status.textColor = .secondaryLabel
                for slider in sliders { adjust(slider) }
                applyEnhancement()
                updatePlayButton()
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.data else { continue }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                let name = String(cString: property.name)
                if property.format == MPV_FORMAT_DOUBLE, let value = property.data {
                    let number = value.assumingMemoryBound(to: Double.self).pointee
                    if number.isFinite {
                        if name == "duration" { duration = max(0, number) }
                        if name == "time-pos" && !waitingForSeek { position = max(0, number) }
                    }
                    if !scrubbing && !waitingForSeek { updateTimeline() }
                } else if property.format == MPV_FORMAT_FLAG, let value = property.data {
                    let flag = value.assumingMemoryBound(to: CInt.self).pointee != 0
                    switch name {
                    case "pause":
                        isPaused = flag
                        if isFullscreen && flag { setFullscreenHUDVisible(true) }
                    case "eof-reached": reachedEnd = flag
                    case "seekable": seekable = flag
                    default: break
                    }
                    updatePlayButton()
                    if !scrubbing { updateTimeline() }
                }
            case MPV_EVENT_PLAYBACK_RESTART:
                waitingForSeek = false
                updateTimeline()
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
                    updateTimeline()
                    showMPVError(end.error, operation: "无法播放此文件")
                    updatePlayButton()
                }
            case MPV_EVENT_SET_PROPERTY_REPLY:
                if event.reply_userdata == 1001 {
                    if !backgrounded {
                        if !setString("vid", "auto", replyID: 1002) { resizingVideo = false }
                    }
                    else { resizingVideo = false }
                } else if event.reply_userdata == 1002 {
                    resizingVideo = false
                    scheduleVideoResize()
                }
                if event.error < 0 { showMPVError(event.error, operation: "画面设置") }
            case MPV_EVENT_COMMAND_REPLY:
                if event.reply_userdata == 2001 && event.error < 0 {
                    waitingForSeek = false
                    updateTimeline()
                }
                if event.error < 0 { showMPVError(event.error, operation: "播放命令") }
            default: break
            }
        }
    }

    @objc private func enterBackground() {
        compareEnded()
        backgrounded = true
        resizeWork?.cancel()
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
        resizeWork?.cancel()
        hideHUDTimer?.invalidate()
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let mpv { mpv_terminate_destroy(mpv) }
        importProgress?.cancel()
        if let directory = importDirectory { try? FileManager.default.removeItem(at: directory) }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
