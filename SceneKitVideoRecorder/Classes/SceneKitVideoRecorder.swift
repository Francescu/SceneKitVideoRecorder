//
//  SceneKitVideoRecorder.swift
//
//  Created by Omer Karisman on 2017/08/29.
//

import UIKit
import SceneKit
import ARKit
import AVFoundation
import CoreImage
import BrightFutures

public class SceneKitVideoRecorder: NSObject, AVAudioRecorderDelegate {
  private var writer: AVAssetWriter!
  private var videoInput: AVAssetWriterInput!

  var recordingSession: AVAudioSession!
  var audioRecorder: AVAudioRecorder!

  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
  private var options: Options

  private let frameQueue = DispatchQueue(label: "com.svtek.SceneKitVideoRecorder.frameQueue")
  private let bufferQueue = DispatchQueue(label: "com.svtek.SceneKitVideoRecorder.bufferQueue", attributes: .concurrent)
  private let audioQueue = DispatchQueue(label: "com.svtek.SceneKitVideoRecorder.audioQueue")

  private let errorDomain = "com.svtek.SceneKitVideoRecorder"

  private var displayLink: CADisplayLink? = nil

  private var initialTime: CMTime = kCMTimeInvalid
  private var currentTime: CMTime = kCMTimeInvalid

  private var sceneView: SCNView

  private var audioSettings: [String : Any]?

  public var isAudioSetup: Bool = false

  private var isPrepared: Bool = false
  private var isRecording: Bool = false

  private var useAudio: Bool {
    return options.useMicrophone && AVAudioSession.sharedInstance().recordPermission() == .granted && isAudioSetup
  }
  private var videoFramesWritten: Bool = false
  private var waitingForPermissions: Bool = false

  private var renderer: SCNRenderer!

  public var updateFrameHandler: ((_ image: UIImage) -> Void)? = nil
  private var finishedCompletionHandler: ((_ url: URL) -> Void)? = nil

  @available(iOS 11.0, *)
  public convenience init(withARSCNView view: ARSCNView, options: Options = .`default`) throws {
    try self.init(scene: view, options: options)
  }

  public init(scene: SCNView, options: Options = .`default`, setupAudio: Bool = true) throws {

    self.sceneView = scene

    self.options = options

    self.isRecording = false
    self.videoFramesWritten = false

    super.init()

    FileController.clearTemporaryDirectory()

    self.prepare()

    if setupAudio {
      self.setupAudio()
    }
  }

  private func prepare() {

    self.prepare(with: self.options)
    isPrepared = true

  }

  private func prepare(with options: Options) {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    self.renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = self.sceneView.scene

    initialTime = kCMTimeInvalid

    self.options.videoSize = options.videoSize

    writer = try! AVAssetWriter(outputURL: self.options.videoOnlyUrl, fileType: AVFileType(rawValue: self.options.fileType))

    self.setupVideo()
  }

  @discardableResult public func cleanUp() -> [URL] {

    var output: [URL] = options.exports.map { $0.outputUrl }

    if options.deleteFileIfExists {
        output = output.map { (initialOutputUrl: URL) -> URL in
            let nameOnly = (initialOutputUrl.lastPathComponent as NSString).deletingPathExtension
            let fileExt  = (initialOutputUrl.lastPathComponent as NSString).pathExtension
            let tempFileName = NSTemporaryDirectory() + nameOnly + "TMP." + fileExt
            let newOutputUrl = URL(fileURLWithPath: tempFileName)
            
            FileController.move(from: initialOutputUrl, to: newOutputUrl)
            return newOutputUrl
        }
      FileController.delete(file: self.options.audioOnlyUrl)
      FileController.delete(file: self.options.videoOnlyUrl)
    }

    return output
  }

  public func setupAudio() {
    guard self.options.useMicrophone, !self.isAudioSetup else { return }

    recordingSession = AVAudioSession.sharedInstance()

    do {
      try recordingSession.setCategory(AVAudioSessionCategoryPlayAndRecord, with: [.defaultToSpeaker])
      try recordingSession.setActive(true)
      recordingSession.requestRecordPermission() { allowed in
        DispatchQueue.main.async {
          if allowed {
            self.isAudioSetup = true
          } else {
            self.isAudioSetup = false
          }
        }
      }
    } catch {
      self.isAudioSetup = false
    }
  }

  private func startRecordingAudio() {
    let audioUrl = self.options.audioOnlyUrl

    let settings = self.options.assetWriterAudioInputSettings

    do {
      audioRecorder = try AVAudioRecorder(url: audioUrl, settings: settings)
      audioRecorder.delegate = self
      audioRecorder.record()
      
    } catch {
      print("Recorder – Audio Failed")
      finishRecordingAudio(success: false)
    }
  }

  private func finishRecordingAudio(success: Bool) {
    audioRecorder.stop()
    audioRecorder = nil
  }

  private func setupVideo() {

    self.videoInput = AVAssetWriterInput(mediaType: AVMediaType.video,
                                         outputSettings: self.options.assetWriterVideoInputSettings)

    self.videoInput.mediaTimeScale = self.options.timeScale

    self.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,sourcePixelBufferAttributes: self.options.sourcePixelBufferAttributes)

    writer.add(videoInput)
  }

  public func startWriting() -> Future<Void, NSError> {
    let promise = Promise<Void, NSError>()
    guard !isRecording else {
      promise.failure(NSError(domain: errorDomain, code: ErrorCode.recorderBusy.rawValue, userInfo: nil))
      return promise.future
    }
    isRecording = true

    startDisplayLink()

    guard startInputPipeline() else {
      stopDisplayLink()
      cleanUp()
      promise.failure(NSError(domain: errorDomain, code: ErrorCode.unknown.rawValue, userInfo: nil))
      return promise.future
    }

    promise.success(())
    return promise.future
  }

  public func finishWriting() -> Future<[URL], NSError> {

    let promise = Promise<[URL], NSError>()
    guard isRecording, writer.status == .writing else {
      let error = NSError(domain: errorDomain, code: ErrorCode.notReady.rawValue, userInfo: nil)
      promise.failure(error)
      return promise.future
    }

    videoInput.markAsFinished()

    if audioRecorder != nil {
      finishRecordingAudio(success: true)
    }

    isRecording = false
    isPrepared = false
    videoFramesWritten = false

    currentTime = kCMTimeInvalid

    writer.finishWriting { [weak self] in

      guard let this = self else { return }

      this.stopDisplayLink()

        this.mergeVideoAndAudio(videoUrl: this.options.videoOnlyUrl, audioUrl: this.options.audioOnlyUrl).onSuccess { _ in
          let outputUrl = this.cleanUp()
          promise.success(outputUrl)
        }
        .onFailure { error in
          this.cleanUp()
          promise.failure(error)
        }


      this.prepare()
    }
    return promise.future
  }

  private func getCurrentCMTime() -> CMTime {
    return CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000);
  }

  private func getAppendTime() -> CMTime {
    currentTime = getCurrentCMTime() - initialTime
    return currentTime
  }

  private func startDisplayLink() {
    displayLink = CADisplayLink(target: self, selector: #selector(updateDisplayLink))
    displayLink?.preferredFramesPerSecond = options.fps
    displayLink?.add(to: .main, forMode: .commonModes)
  }

  @objc private func updateDisplayLink() {

    frameQueue.async { [weak self] in

      if self?.writer.status == .unknown { return }
      if self?.writer.status == .failed { return }
      guard let input = self?.videoInput, input.isReadyForMoreMediaData else { return }

      self?.renderSnapshot()
    }
  }

  private func startInputPipeline() -> Bool {
    guard writer.status == .unknown else { return false }
    guard writer.startWriting() else { return false }

    writer.startSession(atSourceTime: kCMTimeZero)

    videoInput.requestMediaDataWhenReady(on: frameQueue, using: {})

    return true
  }

  private func renderSnapshot() {

    autoreleasepool {

      let time = CACurrentMediaTime()
      let image = renderer.snapshot(atTime: time, with: self.options.videoSize, antialiasingMode: self.options.antialiasingMode)

      updateFrameHandler?(image)

      guard let pool = self.pixelBufferAdaptor.pixelBufferPool else { print("Recorder – No pool"); return }

      let pixelBufferTemp = PixelBufferFactory.make(with: image, usingBuffer: pool)

      guard let pixelBuffer = pixelBufferTemp else { print("Recorder – No buffer"); return }

      guard videoInput.isReadyForMoreMediaData else { print("Recorder – No ready for media data"); return }

      if videoFramesWritten == false {
        videoFramesWritten = true
        startRecordingAudio()
        initialTime = getCurrentCMTime()
      }

      let currentTime = getCurrentCMTime()

      guard CMTIME_IS_VALID(currentTime) else { print("Recorder – No current time"); return }

      let appendTime = getAppendTime()

      guard CMTIME_IS_VALID(appendTime) else { print("Recorder – No append time"); return }

      bufferQueue.async { [weak self] in
        self?.pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: appendTime)
      }
    }
  }

  private func stopDisplayLink() {

    displayLink?.invalidate()
    displayLink = nil

  }

  private func mergeVideoAndAudio(videoUrl:URL, audioUrl:URL) -> Future<[Void], NSError> {
    let promise = Promise<[Void], NSError>()

    let mixComposition : AVMutableComposition = AVMutableComposition()
    var mutableCompositionVideoTrack : [AVMutableCompositionTrack] = []
    let totalVideoCompositionInstruction : AVMutableVideoCompositionInstruction = AVMutableVideoCompositionInstruction()

    let aVideoAsset : AVAsset = AVAsset(url: videoUrl)

    mutableCompositionVideoTrack.append(mixComposition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)!)

    guard !aVideoAsset.tracks.isEmpty else {
        print("Recorder – aVideoAsset empty")
      let error = NSError(domain: errorDomain, code: ErrorCode.zeroFrames.rawValue, userInfo: nil)
      promise.failure(error)
      return promise.future
    }

    let aVideoAssetTrack : AVAssetTrack = aVideoAsset.tracks(withMediaType: AVMediaType.video)[0]

    do {
      try mutableCompositionVideoTrack[0].insertTimeRange(CMTimeRangeMake(kCMTimeZero, aVideoAssetTrack.timeRange.duration), of: aVideoAssetTrack, at: kCMTimeZero)
    } catch {

    }
    
    if self.useAudio == true {
      var mutableCompositionAudioTrack : [AVMutableCompositionTrack] = []
      let aAudioAsset : AVAsset = AVAsset(url: audioUrl)
      
      mutableCompositionAudioTrack.append(mixComposition.addMutableTrack(withMediaType: AVMediaType.audio, preferredTrackID: kCMPersistentTrackID_Invalid)!)
      
      if !aAudioAsset.tracks.isEmpty {
        
        let aAudioAssetTrack : AVAssetTrack = aAudioAsset.tracks(withMediaType: AVMediaType.audio)[0]
        
        do {
          try mutableCompositionAudioTrack[0].insertTimeRange(CMTimeRangeMake(kCMTimeZero, aVideoAssetTrack.timeRange.duration), of: aAudioAssetTrack, at: kCMTimeZero)
        } catch {
          
        }
      }
      else {
        print("Recorder – AudioAsset empty")
      }
        
    }
    totalVideoCompositionInstruction.timeRange = CMTimeRangeMake(kCMTimeZero,aVideoAssetTrack.timeRange.duration)

    
    return self.options.exports.map { self.export(composition: mixComposition, with: $0) }.sequence()
  }

    func export(composition: AVComposition, with settings: Options.Export) -> Future<Void, NSError> {
        let promise = Promise<Void, NSError>()
        let savePathUrl : URL = settings.outputUrl
        
        let assetExport: AVAssetExportSession = AVAssetExportSession(asset: composition, presetName: settings.presetName)!
        assetExport.outputFileType = AVFileType.mp4
        assetExport.outputURL = savePathUrl
        assetExport.shouldOptimizeForNetworkUse = true
        
        assetExport.exportAsynchronously { () -> Void in
            switch assetExport.status {
                
            case AVAssetExportSessionStatus.completed:
                promise.success(())
            case  AVAssetExportSessionStatus.failed:
                let assetExportErrorMessage = "failed \(String(describing: assetExport.error))"
                let error = NSError(domain: self.errorDomain, code: ErrorCode.assetExport.rawValue, userInfo: ["Reason": assetExportErrorMessage])
                promise.failure(error)
            case AVAssetExportSessionStatus.cancelled:
                let assetExportErrorMessage = "cancelled \(String(describing: assetExport.error))"
                let error = NSError(domain: self.errorDomain, code: ErrorCode.assetExport.rawValue, userInfo: ["Reason": assetExportErrorMessage])
                promise.failure(error)
            default:
                promise.success(())
            }
        }
        return promise.future
    }
}
