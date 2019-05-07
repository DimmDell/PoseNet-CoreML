import AVFoundation
import CSV.Swift
import Foundation
import SwiftyJSON
import TensorSwift
import UIKit
import Vision

let posenet = PoseNet()
var isXcode: Bool = true // true: localfile , false: device camera

// controlling the pace of the machine vision analysis
var lastAnalysis: TimeInterval = 0
var pace: TimeInterval = 0.08 // in seconds, classification will not repeat faster than this value
// performance tracking
let trackPerformance = false // use "true" for performance logging
var frameCount = 0
let framesPerSample = 10
var startDate = NSDate.timeIntervalSinceReferenceDate
let semaphore = DispatchSemaphore(value: 1)

func isImage(filename: String) -> Bool {
    if filename.hasSuffix(".png") || filename.hasSuffix(".jpeg") || filename.hasSuffix(".jpg") {
        return true
    } else {
        return false
    }
}

func initposearr() -> [UIImage] {
    var res: [UIImage] = []
    if let path = Bundle.main.resourcePath {
        let imagePath = path
        let url = NSURL(fileURLWithPath: imagePath)
        let fileManager = FileManager.default
        
        let properties = [URLResourceKey.localizedNameKey,
                          URLResourceKey.creationDateKey, URLResourceKey.localizedTypeDescriptionKey]
        
        do {
            let imageURLs = try fileManager.contentsOfDirectory(at: url as URL, includingPropertiesForKeys: properties, options: FileManager.DirectoryEnumerationOptions.skipsHiddenFiles)
            
            //    print("image URLs: \(imageURLs)")
            
            // Create image from URL
            for pic in imageURLs {
                if isImage(filename: pic.absoluteString) {
                    // var res =  UIImage(data: NSData(contentsOf: imageURLs[0])! as Data)
                    res.append(UIImage(data: NSData(contentsOf: pic)! as Data)!)
                }
            }
            
        } catch let error1 as NSError {
            print(error1.description)
        }
    }
//    print(res)
    return res
}

let imgarr = initposearr()

class ViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    @IBOutlet var previewView: UIImageView!
    @IBOutlet var lineView: UIImageView!
    
    @IBOutlet var reportView: UITextView!
    let model = posenet513_v1_075()
    let targetImageSize = CGSize(width: 513, height: 513)
    var previewLayer: AVCaptureVideoPreviewLayer!
    
    @IBOutlet var reportButton: UIBarButtonItem!
    
    let videoQueue = DispatchQueue(label: "videoQueue")
    let drawQueue = DispatchQueue(label: "drawQueue")
    var captureSession = AVCaptureSession()
    var captureDevice: AVCaptureDevice?
    let videoOutput = AVCaptureVideoDataOutput()
    var isWriting: Bool = false
    let imgarr: [UIImage] = initposearr()
    var ind = 1
    
    let imgpicker = UIImagePickerController()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        imgpicker.delegate = self
        
        previewView.frame = UIScreen.main.bounds
        previewView.contentMode = .scaleAspectFit
        
        imgarr.forEach { image in
            if isXcode {
                let fname = String(ind) + ".png"
                ind += 1
                // if let image = UIImage(named: fname)?.resize(to: targetImageSize) {
                previewView.image = image.resize(to: targetImageSize)
                let result = measure(
                    runCoreML(
                        image.pixelBuffer(width: Int(targetImageSize.width),
                                          height: Int(targetImageSize.height))!
                    )
                )
                print(result.duration)
                drawResults(result.result, name: fname)
                // let result = runOffline()
                // drawResults(result)
                //   }
            } else {
                previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
                previewView.layer.addSublayer(previewLayer)
            }
        }
        print(imgarr)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        if !isXcode {
            setupCamera()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isXcode {
            previewLayer.frame = previewView.bounds
            lineView.frame = previewView.bounds
        }
    }
    
    func writeJson(json: JSON) {
        let fileName = "Test"
        let DocumentDirURL = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        
        let fileURL = DocumentDirURL.appendingPathComponent(fileName).appendingPathExtension("json")
        print("FilePath: \(fileURL.path)")
        
        do {
            // Write to the file
            try json.rawData(options: .prettyPrinted).write(to: fileURL)
        } catch let error as NSError {
            print("Failed writing to URL: \(fileURL), Error: " + error.localizedDescription)
        }
        
        var readString = "" // Used to store the file contents
        do {
            // Read the file contents
            readString = try String(contentsOf: fileURL)
        } catch let error as NSError {
            print("Failed reading from URL: \(fileURL), Error: " + error.localizedDescription)
        }
        print("File Text: \(readString)")
        reportView.text = readString
    }
    
    func createJson(data: [Keypoint], name: String) -> JSON {
        var poseDict: [String: [Double]] = [:]
        var resJson: JSON
        data.forEach {
            elem in
            let point = [Double(elem.position.x), Double(elem.position.y)]
            poseDict.updateValue(point, forKey: elem.part)
        }
        
        resJson = JSON(poseDict)
        
        return (resJson)
    }
    
    @IBAction func showReport(_ sender: UIBarButtonItem) {
        reportView.isHidden = !reportView.isHidden
    }
    
    @objc func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String: Any]) {
        if let pickedImage = info[UIImagePickerControllerOriginalImage] as? UIImage {
            previewView.contentMode = .scaleAspectFit
            previewView.image = pickedImage
            
            let result = measure(
                runCoreML(
                    previewView.image!.pixelBuffer(width: Int(targetImageSize.width),
                                                   height: Int(targetImageSize.height))!
                )
            )
            print(result.duration)
            var fname = String(ind) + ".png"
            drawResults(result.result, name: fname)
            // let result = runOffline()
            // drawResults(result)
            //   }
        } else {
            previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewView.layer.addSublayer(previewLayer)
        }
        
        dismiss(animated: true, completion: nil)
    }
    
    @IBAction func loadImage(_ sender: UIBarButtonItem) {
        imgpicker.allowsEditing = false
        imgpicker.sourceType = .photoLibrary
        
        present(imgpicker, animated: true, completion: nil)
    }
    
    func setupCamera() {
        let deviceDiscovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back)
        
        if let device = deviceDiscovery.devices.last {
            captureDevice = device
            beginSession()
        }
    }
    
    func beginSession() {
        do {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as NSString as String: NSNumber(value: kCVPixelFormatType_32BGRA) as! UInt32]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            
            if UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiom.phone {
//                captureSession.sessionPreset = .hd1920x1080
                captureSession.sessionPreset = .photo
            } else if UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiom.pad {
                captureSession.sessionPreset = .photo
            }
            
            captureSession.addOutput(videoOutput)
            
            let input = try AVCaptureDeviceInput(device: captureDevice!)
            captureSession.addInput(input)
            
            captureSession.startRunning()
        } catch {
            print("error connecting to capture device")
        }
    }
    
    func drawResults(_ poses: [Pose], name: String) {
        let minPoseConfidence: Float = 0.05
        
        let screen = UIScreen.main.bounds
        let scale = screen.width / targetImageSize.width
        let size = AVMakeRect(aspectRatio: targetImageSize,
                              insideRect: previewView.frame)
        
        var linePath = UIBezierPath()
        var arcPath = UIBezierPath()
        poses.forEach { pose in
            if pose.score >= minPoseConfidence {
                self.drawKeypoints(arcPath: &arcPath, keypoints: pose.keypoints, minConfidence: minPoseConfidence,
                                   size: size.origin, scale: scale, name: name)
                self.drawSkeleton(linePath: &linePath, keypoints: pose.keypoints,
                                  minConfidence: minPoseConfidence,
                                  size: size.origin, scale: scale)
            }
        }
        
        // Draw
        let arcLine = CAShapeLayer()
        arcLine.path = arcPath.cgPath
        arcLine.strokeColor = UIColor.green.cgColor
        
        let line = CAShapeLayer()
        line.path = linePath.cgPath
        line.strokeColor = UIColor.red.cgColor
        line.lineWidth = 2
        line.lineJoin = kCALineJoinRound
        
        lineView.layer.sublayers = nil
        lineView.layer.addSublayer(arcLine)
        lineView.layer.addSublayer(line)
        linePath.removeAllPoints()
        arcPath.removeAllPoints()
        semaphore.wait()
        isWriting = false
        semaphore.signal()
    }
    
    func drawKeypoints(arcPath: inout UIBezierPath, keypoints: [Keypoint], minConfidence: Float,
                       size: CGPoint, scale: CGFloat = 1, name: String) {
        keypoints.forEach { keypoint in
            if keypoint.score < minConfidence {
                return
            }
            let center = CGPoint(x: CGFloat(keypoint.position.x) * scale + size.x,
                                 y: CGFloat(keypoint.position.y) * scale + size.y)
            let trackPath = UIBezierPath(arcCenter: center,
                                         radius: 3, startAngle: 0,
                                         endAngle: 2.0 * .pi, clockwise: true)
            
            arcPath.append(trackPath)
        }
        
        let json = createJson(data: keypoints, name: name)
        
        print(json.rawString(options: .prettyPrinted) as Any)
        
        writeJson(json: json)
    }
    
    func drawSegment(linePath: inout UIBezierPath, fromPoint start: CGPoint, toPoint end: CGPoint,
                     size: CGPoint, scale: CGFloat = 1) {
        let newlinePath = UIBezierPath()
        newlinePath.move(to:
            CGPoint(x: start.x * scale + size.x, y: start.y * scale + size.y))
        newlinePath.addLine(to:
            CGPoint(x: end.x * scale + size.x, y: end.y * scale + size.y))
        linePath.append(newlinePath)
    }
    
    func drawSkeleton(linePath: inout UIBezierPath, keypoints: [Keypoint], minConfidence: Float,
                      size: CGPoint, scale: CGFloat = 1) {
        let adjacentKeyPoints = getAdjacentKeyPoints(
            keypoints: keypoints, minConfidence: minConfidence)
        
        adjacentKeyPoints.forEach { keypoint in
            drawSegment(linePath: &linePath,
                        fromPoint:
                        CGPoint(x: CGFloat(keypoint[0].position.x), y: CGFloat(keypoint[0].position.y)),
                        toPoint:
                        CGPoint(x: CGFloat(keypoint[1].position.x), y: CGFloat(keypoint[1].position.y)),
                        size: size,
                        scale: scale)
        }
    }
    
    func eitherPointDoesntMeetConfidence(
        _ a: Float, _ b: Float, _ minConfidence: Float) -> Bool {
        return (a < minConfidence || b < minConfidence)
    }
    
    func getAdjacentKeyPoints(
        keypoints: [Keypoint], minConfidence: Float) -> [[Keypoint]] {
        return connectedPartIndices.filter {
            !eitherPointDoesntMeetConfidence(
                keypoints[$0.0].score,
                keypoints[$0.1].score,
                minConfidence)
        }.map { [keypoints[$0.0], keypoints[$0.1]] }
    }
    
    func runOffline() -> [Pose] {
        let scores = getTensorTranspose("heatmapScores", [33, 33, 17])
        let offsets = getTensorTranspose("offsets", [33, 33, 34])
        let displacementsFwd = getTensorTranspose("displacementsFwd", [33, 33, 32])
        let displacementsBwd = getTensorTranspose("displacementsBwd", [33, 33, 32])
        
        let sum = scores.reduce(0, +) / (17 * 33 * 33)
        print(sum)
        
        let poses = posenet.decodeMultiplePoses(
            scores: scores,
            offsets: offsets,
            displacementsFwd: displacementsFwd,
            displacementsBwd: displacementsBwd,
            outputStride: 16, maxPoseDetections: 5,
            scoreThreshold: 0.5, nmsRadius: 20)
        
        return poses
    }
    
    func runCoreML(_ img: CVPixelBuffer) -> [Pose] {
        let result = try? model.prediction(image__0: img)
        
        let tensors = result?.featureNames.reduce(into: [String: Tensor]()) {
            $0[$1] = getTensor(
                result?.featureValue(for: $1)?.multiArrayValue)
        }
        let sum = tensors!["heatmap__0"]!.reduce(0, +) / (17 * 33 * 33)
        print(sum)
        
        let poses = posenet.decodeMultiplePoses(
            scores: tensors!["heatmap__0"]!,
            offsets: tensors!["offset_2__0"]!,
            displacementsFwd: tensors!["displacement_fwd_2__0"]!,
            displacementsBwd: tensors!["displacement_bwd_2__0"]!,
            outputStride: 16, maxPoseDetections: 15,
            scoreThreshold: 0.5, nmsRadius: 20)
        
        return poses
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    // called for each frame of video
    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let currentDate = NSDate.timeIntervalSinceReferenceDate
        
        // control the pace of the machine vision to protect battery life
        if currentDate - lastAnalysis >= pace {
            lastAnalysis = currentDate
        } else {
            return // don't run the classifier more often than we need
        }
        
        // keep track of performance and log the frame rate
        if trackPerformance {
            frameCount = frameCount + 1
            if frameCount % framesPerSample == 0 {
                let diff = currentDate - startDate
                if diff > 0 {
                    if pace > 0.0 {
                        print("WARNING: Frame rate of image classification is being limited by \"pace\" setting. Set to 0.0 for fastest possible rate.")
                    }
                    print("\(String.localizedStringWithFormat("%0.2f", diff / Double(framesPerSample)))s per frame (average)")
                }
                startDate = currentDate
            }
        }
        
//        DispatchQueue.global(qos: .default).async {
        drawQueue.async {
            semaphore.wait()
            if self.isWriting == false {
                self.isWriting = true
                semaphore.signal()
                let startTime = CFAbsoluteTimeGetCurrent()
                guard let croppedBuffer = croppedSampleBuffer(sampleBuffer, targetSize: self.targetImageSize) else {
                    return
                }
                let poses = self.runCoreML(croppedBuffer)
                DispatchQueue.main.sync {
                    self.drawResults(poses, name: "")
                }
                let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
                print("Elapsed time is \(timeElapsed) seconds.")
            } else {
                semaphore.signal()
            }
        }
    }
}

let context = CIContext()
var rotateTransform: CGAffineTransform?
var scaleTransform: CGAffineTransform?
var cropTransform: CGAffineTransform?
var resultBuffer: CVPixelBuffer?

func croppedSampleBuffer(_ sampleBuffer: CMSampleBuffer, targetSize: CGSize) -> CVPixelBuffer? {
    guard let imageBuffer: CVImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        fatalError("Can't convert to CVImageBuffer.")
    }
    
    // Only doing these calculations once for efficiency.
    // If the incoming images could change orientation or size during a session, this would need to be reset when that happens.
    if rotateTransform == nil {
        let imageSize = CVImageBufferGetEncodedSize(imageBuffer)
        let rotatedSize = CGSize(width: imageSize.height, height: imageSize.width)
        
        guard targetSize.width < rotatedSize.width, targetSize.height < rotatedSize.height else {
            fatalError("Captured image is smaller than image size for model.")
        }
        
        let shorterSize = (rotatedSize.width < rotatedSize.height) ? rotatedSize.width : rotatedSize.height
        rotateTransform = CGAffineTransform(translationX: imageSize.width / 2.0, y: imageSize.height / 2.0).rotated(by: -CGFloat.pi / 2.0).translatedBy(x: -imageSize.height / 2.0, y: -imageSize.width / 2.0)
        
        let scale = targetSize.width / shorterSize
        scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
        
        // Crop input image to output size
        let xDiff = rotatedSize.width * scale - targetSize.width
        let yDiff = rotatedSize.height * scale - targetSize.height
        cropTransform = CGAffineTransform(translationX: xDiff / 2.0, y: yDiff / 2.0)
    }
    
    // Convert to CIImage because it is easier to manipulate
    let ciImage = CIImage(cvImageBuffer: imageBuffer)
    let rotated = ciImage.transformed(by: rotateTransform!)
    let scaled = rotated.transformed(by: scaleTransform!)
    let cropped = scaled.transformed(by: cropTransform!)
    
    // Note that the above pipeline could be easily appended with other image manipulations.
    // For example, to change the image contrast. It would be most efficient to handle all of
    // the image manipulation in a single Core Image pipeline because it can be hardware optimized.
    
    // Only need to create this buffer one time and then we can reuse it for every frame
    if resultBuffer == nil {
        let result = CVPixelBufferCreate(kCFAllocatorDefault, Int(targetSize.width), Int(targetSize.height), kCVPixelFormatType_32BGRA, nil, &resultBuffer)
        
        guard result == kCVReturnSuccess else {
            fatalError("Can't allocate pixel buffer.")
        }
    }
    
    // Render the Core Image pipeline to the buffer
    context.render(cropped, to: resultBuffer!)
    
    //  For debugging
    //  let image = imageBufferToUIImage(resultBuffer!)
    //  print(image.size) // set breakpoint to see image being provided to CoreML
    
    return resultBuffer
}
