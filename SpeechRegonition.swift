import Foundation
import Speech
import AVFoundation

// Function to print help
func printHelp() {
    fputs("""
    Usage: program [options]
    
    Options:
      -l, --language CODE    Specifies the language for voice recognition (e.g., es-ES, en-US)
      -n, --newline         Adds line breaks after each text segment
      -h, --help           Shows this help
    
    Language code examples:
      es-ES   Spanish (Spain)
      es-MX   Spanish (Mexico)
      en-US   English (United States)
      en-GB   English (United Kingdom)
      fr-FR   French (France)
      de-DE   German (Germany)
    
    """, stderr)
    exit(0)
}

// Function to parse arguments
func parseArguments() -> (locale: Locale, addNewlines: Bool) {
    // Default value
    var languageCode = "en-US"
    var addNewlines = false
    
    // Get arguments
    let args = CommandLine.arguments
    
    // Process arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "-h", "--help":
            printHelp()
        case "-n", "--newline":
            addNewlines = true
        case "-l", "--language":
            if i + 1 < args.count {
                languageCode = args[i + 1]
                i += 1
            } else {
                fputs("Error: The -l/--language argument requires a value\n", stderr)
                exit(1)
            }
        default:
            fputs("Unknown argument: \(args[i])\n", stderr)
            fputs("Use --help to see available options\n", stderr)
            exit(1)
        }
        i += 1
    }
    
    // Create Locale object with language code
    let locale = Locale(identifier: languageCode)
    
    // Validate that the language is supported
    if SFSpeechRecognizer(locale: locale) == nil {
        fputs("Error: Language '\(languageCode)' is not supported for voice recognition\n", stderr)
        fputs("Examples of supported languages: es-ES, en-US, fr-FR, de-DE, it-IT...\n", stderr)
        exit(1)
    }
    
    return (locale, addNewlines)
}

class SpeechRecognizer {
    private let speechRecognizer: SFSpeechRecognizer
    private var isRunning = true
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let addNewlines: Bool
    
    // Text output control
    private var lastProcessedText = ""
    private var lastStableTime = Date()
    private var pendingText = ""
    
    init(locale: Locale, addNewlines: Bool = false) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            fatalError("Could not initialize recognizer for language \(locale.identifier)")
        }
        self.speechRecognizer = recognizer
        self.addNewlines = addNewlines
    }
    
    private func getNewText(from fullText: String) -> String? {
        // If text is shorter than previous, it's a complete correction
        if fullText.count <= lastProcessedText.count && fullText != lastProcessedText {
            lastProcessedText = ""
            return fullText
        }
        
        // If it's the same text, there's nothing new
        if fullText == lastProcessedText {
            return nil
        }
        
        // Extract only new text
        let newText = String(fullText.dropFirst(lastProcessedText.count))
        lastProcessedText = fullText
        
        return newText.isEmpty ? nil : newText
    }
    
    private func writeToStdout(_ text: String) {
        let outputText = addNewlines ? text + "\n" : text
        guard let data = outputText.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
        fflush(stdout)
    }
    
    func processStdin() throws {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else {
            fputs("Error: No audio input. Use the program with pipe\n", stderr)
            exit(1)
        }

        fputs("Requesting voice recognition permissions...\n", stderr)
        
        var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
        let authSemaphore = DispatchSemaphore(value: 0)
        
        SFSpeechRecognizer.requestAuthorization { status in
            authStatus = status
            authSemaphore.signal()
        }
        
        if authSemaphore.wait(timeout: .now() + 5) == .timedOut {
            fputs("Error: Timeout waiting for authorization\n", stderr)
            exit(1)
        }
        
        guard authStatus == .authorized else {
            fputs("Error: No authorization for voice recognition\n", stderr)
            exit(1)
        }
        
        fputs("Authorization granted. Processing audio...\n", stderr)
        
        // Configure audio format
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: true
        )!
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            fputs("Error: Could not create recognition request\n", stderr)
            exit(1)
        }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true
        // recognitionRequest.addsDependentContent = true
        
        // Create recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                fputs("Error during recognition: \(error.localizedDescription)\n", stderr)
                return
            }
            
            if let result = result {
                let transcription = result.bestTranscription.formattedString
                
                if result.isFinal {
                    // Final result - process and show new words
                    if let newText = self.getNewText(from: transcription) {
                        self.writeToStdout(newText)
                    }
                } else {
                    // Partial result - update but wait for stability
                    let now = Date()
                    self.pendingText = transcription
                    
                    // If enough time has passed since last stable update
                    if now.timeIntervalSince(self.lastStableTime) >= 5.0 {
                        if let newText = self.getNewText(from: transcription) {
                            self.writeToStdout(newText)
                            self.lastStableTime = now
                        }
                    }
                }
            }
        }
        
        fputs("Reading PCM from stdin in streaming...\n", stderr)
        
        // Set up stdin for non-blocking read
        let fileDescriptor = FileHandle.standardInput.fileDescriptor
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        
        // Calculate buffer size for 0.1 seconds (100ms) of audio
        // 48000Hz * 2 channels * 4 bytes * 0.1s = 38400 bytes
        let bytesPerChunk = 38400
        let byteBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerChunk)
        defer { byteBuffer.deallocate() }
        
        // Keep program active for continuous streaming
        var lastReadTime = Date()
        
        // Create timer to check if we should finish
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            // If we haven't received data in 2 seconds, we finish
            if Date().timeIntervalSince(lastReadTime) > 2.0 {
                fputs("\nNo data received in 2 seconds. Finishing recognition...\n", stderr)
                self.isRunning = false
            }
        }
        
        // Main processing loop
        while isRunning {
            // Read data without blocking
            let bytesRead = read(fileDescriptor, byteBuffer, bytesPerChunk)
            
            if bytesRead > 0 {
                lastReadTime = Date()
                
                // Calculate number of frames (samples per channel)
                let framesRead = bytesRead / (MemoryLayout<Float32>.stride * Int(format.channelCount))
                
                // Create audio buffer
                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesRead)) else {
                    fputs("Error creating audio buffer\n", stderr)
                    continue
                }
                
                pcmBuffer.frameLength = AVAudioFrameCount(framesRead)
                
                // Copy data to audio buffer
                if let ptr = pcmBuffer.floatChannelData?[0] {
                    memcpy(ptr, byteBuffer, bytesRead)
                }
                
                // Send to recognition engine
                recognitionRequest.append(pcmBuffer)
            } else if bytesRead < 0 && errno != EAGAIN {
                // Read error that's not due to non-blocking
                fputs("Error reading from stdin: \(String(cString: strerror(errno)))\n", stderr)
                break
            } else {
                // No data available now or end of file
                // Small pause to not consume CPU
                usleep(10000) // 10ms
            }
            
            // Process events
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        
        timer.invalidate()
        
        // Finish recognition
        recognitionRequest.endAudio()
        fputs("Recognition finished\n", stderr)
        // Ensure last result has a line break
        writeToStdout("\n")
    }
}

// Handle Ctrl+C
signal(SIGINT) { _ in
    fputs("\nCanceling recognition...\n", stderr)
    exit(0)
}

// Run recognition
do {
    let args = parseArguments()
    fputs("Selected language for recognition: \(args.locale.identifier)\n", stderr)
    let recognizer = SpeechRecognizer(locale: args.locale, addNewlines: args.addNewlines)
    try recognizer.processStdin()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}