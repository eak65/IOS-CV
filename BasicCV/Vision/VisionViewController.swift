

import Foundation
import UIKit
import AVFoundation
import Vision


struct Message: Comparable, Equatable {
  let text: String
  let priority: Int
    
    static func < (lhs: Message, rhs: Message) -> Bool {
        return lhs.priority < rhs.priority
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.text == rhs.text
    }

    
}


class VisionViewController: ViewController {
	var request: VNRecognizeTextRequest!
	// Temporal string tracker
	let stringTracker = StringTracker()
    
    var queue = PriorityQueue<Message>(sort: >)
    var timer = Timer()

	override func viewDidLoad() {
		// Set up vision request before letting ViewController set up the camera
		// so that it exists when the first buffer is received.
		request = VNRecognizeTextRequest(completionHandler: recognizeTextHandler)

		super.viewDidLoad()
        
        scheduledTimerWithTimeInterval()

	}
    
    func scheduledTimerWithTimeInterval(){
        timer = Timer.scheduledTimer(timeInterval: 20, target: self, selector: #selector(self.updateCounting), userInfo: nil, repeats: true)
    }
    
    @objc func updateCounting(){

        DispatchQueue.global(qos: .background).async { [self] in
            print("This is run on the background queue")
            if let text = self.queue.dequeue()?.text {
                print("Posting: \(text)")
                self.queue = PriorityQueue<Message>(sort: >)
                post(rawText: text)
            }
            DispatchQueue.main.async {
                print("This is run on the main queue, after the previous code in outer block")
            }
        }
    }
	
	// MARK: - Text recognition
	
	// Vision recognition handler.
	func recognizeTextHandler(request: VNRequest, error: Error?) {
		var rawStrings = [String]()
		var redBoxes = [CGRect]() // Shows all recognized text lines
		var greenBoxes = [CGRect]() // Shows words that might be serials
		
		guard let results = request.results as? [VNRecognizedTextObservation] else {
			return
		}
		
		let maximumCandidates = 1
		
		for visionResult in results {
			guard let candidate = visionResult.topCandidates(maximumCandidates).first else { continue }
			
			// Draw red boxes around any detected text, and green boxes around
			// any detected phone numbers. The phone number may be a substring
			// of the visionResult. If a substring, draw a green box around the
			// number and a red box around the full string. If the number covers
			// the full result only draw the green box.
			var numberIsSubstring = true
            //print(candidate.string.removeNonAscii())
            
            if candidate.string.contains("?") {
                let message = Message(text: candidate.string, priority: 1)
                if let index = queue.index(of: message) {
                    
                    queue.changePriority(index: index, value: Message(text: candidate.string,priority:queue.get(index: index).priority + 1))
                } else {
                    queue.enqueue(message)
                }
            }
            //post(rawText: candidate.string.removeNonAscii()
           
			if let result = candidate.string.extractCleanString() {
				let (range, number) = result
				// Number may not cover full visionResult. Extract bounding box
				// of substring.
				if let box = try? candidate.boundingBox(for: range)?.boundingBox {
					rawStrings.append(number)
                    greenBoxes.append(box)
					numberIsSubstring = !(range.lowerBound == candidate.string.startIndex && range.upperBound == candidate.string.endIndex)
				}
			}
			if numberIsSubstring {
				redBoxes.append(visionResult.boundingBox)
			}
		}
		
		// Log any found numbers.
		stringTracker.logFrame(strings: rawStrings)
		show(boxGroups: [(color: UIColor.green.cgColor, boxes: redBoxes), (color: UIColor.green.cgColor, boxes: greenBoxes)])
		
		// Check if we have any temporally stable numbers.
		if let sureString = stringTracker.getStableString() {
			//showString(string: sureNumber)
			stringTracker.reset(string: sureString)
		}
	}
    func post(rawText : String) {
        let json: [String: Any] = ["rawText": rawText]

        let jsonData = try? JSONSerialization.data(withJSONObject: json)

        // create post request
        let url = URL(string: "http://192.168.1.175:5000/api/rawtext")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // insert json data to the request
        request.httpBody = jsonData

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                print(error?.localizedDescription ?? "No data")
                return
            }
            let responseJSON = try? JSONSerialization.jsonObject(with: data, options: [])
            if let responseJSON = responseJSON as? [String: Any] {
                print(responseJSON)
            }
        }

        task.resume()
    }
	
	override func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
			// Configure for running in real-time.
			request.recognitionLevel = .fast
			// Language correction won't help recognizing phone numbers. It also
			// makes recognition slower.
			request.usesLanguageCorrection = false
			// Only run on the region of interest for maximum speed.
			request.regionOfInterest = regionOfInterest
			
			let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: textOrientation, options: [:])
			do {
				try requestHandler.perform([request])
			} catch {
				print(error)
			}
		}
	}
	
	// MARK: - Bounding box drawing
	
	// Draw a box on screen. Must be called from main queue.
	var boxLayer = [CAShapeLayer]()
	func draw(rect: CGRect, color: CGColor) {
		let layer = CAShapeLayer()
		layer.opacity = 0.5
		layer.borderColor = color
		layer.borderWidth = 1
		layer.frame = rect
		boxLayer.append(layer)
		previewView.videoPreviewLayer.insertSublayer(layer, at: 1)
	}
	
	// Remove all drawn boxes. Must be called on main queue.
	func removeBoxes() {
		for layer in boxLayer {
			layer.removeFromSuperlayer()
		}
		boxLayer.removeAll()
	}
	
	typealias ColoredBoxGroup = (color: CGColor, boxes: [CGRect])
	
	// Draws groups of colored boxes.
	func show(boxGroups: [ColoredBoxGroup]) {
		DispatchQueue.main.async {
			let layer = self.previewView.videoPreviewLayer
			self.removeBoxes()
			for boxGroup in boxGroups {
				let color = boxGroup.color
				for box in boxGroup.boxes {
					let rect = layer.layerRectConverted(fromMetadataOutputRect: box.applying(self.visionToAVFTransform))
					self.draw(rect: rect, color: color)
				}
			}
		}
	}
}
