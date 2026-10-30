import AVFoundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// 選んだ・撮った・録ったもの（アプリの一時フォルダの写し）
struct PickedMedia {
    var url: URL
    /// 元の名前（写真の IMG_0001.HEIC など）。添え書きに書くだけで、接続先の名前には使わない
    var originalName: String?
}

/// 写真・動画を選ぶ、撮る、録音する、ファイルを選ぶ（docs/design.md「メディアを送る」）。
/// iOS が勝手に縮めたり変換したりしないようにする:
/// - 写真の選択は `.current`（HEIC・HEVC・ProRAW をそのまま）。写真へのアクセスの許可も要らない
/// - カメラは高い画質（`.typeHigh`）、長さの上限を外す（既定は 10 分）
final class MediaPicker: NSObject {
    var onPicked: (([PickedMedia]) -> Void)?
    var onError: ((String) -> Void)?
    weak var presenter: UIViewController?

    /// 送るまでの一時の置き場所（送ったら消す）
    static let workDir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func newURL(ext: String) -> URL {
        workDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "bin" : ext)
    }

    // MARK: 写真・動画を選ぶ

    func pickLibrary() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        config.filter = .any(of: [.images, .videos, .livePhotos])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    // MARK: 撮る

    func capture() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            onError?("この端末ではカメラを使えません")
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 4 * 3600
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    // MARK: 録音

    func record() {
        let vc = AudioRecorderViewController { [weak self] url in
            if let url { self?.onPicked?([PickedMedia(url: url, originalName: nil)]) }
        }
        presenter?.present(vc, animated: true)
    }

    // MARK: ファイル

    func pickFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }
}

extension MediaPicker: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let group = DispatchGroup()
        let lock = NSLock()
        var picked: [(Int, PickedMedia)] = []
        var failed = 0
        for (i, r) in results.enumerated() {
            let provider = r.itemProvider
            // 動画を先に（Live Photo は静止画として送る）、次に画像。原本の形式を選ぶ
            let types = provider.registeredTypeIdentifiers
            guard let type = types.first(where: { UTType($0)?.conforms(to: .movie) == true && !provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) })
                    ?? types.first(where: { UTType($0)?.conforms(to: .image) == true })
                    ?? types.first else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                // この url は閉包を抜けると消えるので、ここで写す
                guard let url else {
                    lock.withLock { failed += 1 }
                    return
                }
                let dst = MediaPicker.newURL(ext: url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    lock.withLock { picked.append((i, PickedMedia(url: dst, originalName: url.lastPathComponent))) }
                } catch {
                    lock.withLock { failed += 1 }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            if failed > 0 { self?.onError?("\(failed) 件を読めませんでした（iCloud にだけある写真なら、写真アプリで一度開いてから）") }
            let ordered = picked.sorted { $0.0 < $1.0 }.map(\.1)
            if !ordered.isEmpty { self?.onPicked?(ordered) }
        }
    }
}

extension MediaPicker: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let movie = info[.mediaURL] as? URL {
            let dst = MediaPicker.newURL(ext: movie.pathExtension)
            do {
                try FileManager.default.moveItem(at: movie, to: dst)
                onPicked?([PickedMedia(url: dst, originalName: nil)])
            } catch {
                onError?("撮った動画を読めませんでした")
            }
            return
        }
        // 撮った写真は UIImage でしか受け取れない。エージェントが読める JPEG（高い品質）にする（位置情報は付かない）
        if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) {
            let dst = MediaPicker.newURL(ext: "jpg")
            do {
                try data.write(to: dst)
                onPicked?([PickedMedia(url: dst, originalName: nil)])
            } catch {
                onError?("撮った写真を書けませんでした")
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension MediaPicker: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var picked: [PickedMedia] = []
        for u in urls {
            let dst = MediaPicker.newURL(ext: u.pathExtension)
            if (try? FileManager.default.moveItem(at: u, to: dst)) != nil {
                picked.append(PickedMedia(url: dst, originalName: u.lastPathComponent))
            }
        }
        if !picked.isEmpty { onPicked?(picked) }
    }
}

/// 録音の画面（AAC 48kHz、時間の上限なし）
final class AudioRecorderViewController: UIViewController {
    private let completion: (URL?) -> Void
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private let button = UIButton(type: .system)
    private let time = UILabel()
    private var url: URL?

    init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        time.font = .monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        time.text = "0:00"
        time.textAlignment = .center
        button.configuration = .filled()
        button.configuration?.title = "録音する"
        button.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle("やめる", for: .normal)
        cancel.addAction(UIAction { [weak self] _ in self?.finish(send: false) }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [time, button, cancel])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    private func toggle() {
        if let r = recorder, r.isRecording {
            finish(send: true)
            return
        }
        AVAudioApplication.requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else {
                    self.time.text = "マイクが許可されていません"
                    return
                }
                self.start()
            }
        }
    }

    private func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let u = MediaPicker.newURL(ext: "m4a")
            let r = try AVAudioRecorder(url: u, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            guard r.record() else { throw NSError(domain: "record", code: 1) }
            recorder = r
            url = u
            button.configuration?.title = "止めて送る"
            let started = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                let s = Int(Date().timeIntervalSince(started))
                self?.time.text = String(format: "%d:%02d", s / 60, s % 60)
            }
        } catch {
            time.text = "録音できません"
        }
    }

    private func finish(send: Bool) {
        timer?.invalidate()
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let result = send ? url : nil
        if !send, let url { try? FileManager.default.removeItem(at: url) }
        dismiss(animated: true) { [completion] in completion(result) }
    }
}
