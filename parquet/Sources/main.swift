import Foundation
import FluidAudio
import AVFoundation

// MARK: - Deduplication Manager

class DeduplicationManager {
    private var lastRawText: String = "" // Store the raw text from the last segment
    private let minOverlapWords = 1 // Minimum words to consider for overlap detection
    
    /// Deduplicates a new transcription text against the last confirmed text
    /// Returns the deduplicated text (only the new portion)
    func deduplicate(_ newText: String) -> String {
        guard !lastRawText.isEmpty else {
            lastRawText = newText
            return newText
        }
        
        let newWords = newText.split(separator: " ").map(String.init)
        let lastWords = lastRawText.split(separator: " ").map(String.init)
        
        guard newWords.count >= minOverlapWords && lastWords.count >= minOverlapWords else {
            lastRawText = newText
            return newText
        }
        
        // Find the longest matching suffix of lastWords with prefix of newWords
        var bestOverlapLength = 0
        let maxOverlapCheck = min(lastWords.count, newWords.count, 10) // Check up to 10 words
        
        for overlapLength in minOverlapWords...maxOverlapCheck {
            let lastSuffix = lastWords.suffix(overlapLength)
            let newPrefix = newWords.prefix(overlapLength)
            
            // Use fuzzy matching - allow for small differences
            if areSimilar(Array(lastSuffix), Array(newPrefix)) {
                bestOverlapLength = overlapLength
            }
        }
        
        // Extract only the new portion
        let deduplicatedWords = newWords.dropFirst(bestOverlapLength)
        let deduplicatedText = deduplicatedWords.joined(separator: " ")
        
        // Update last raw text to the current raw text (not accumulated)
        lastRawText = newText
        
        return deduplicatedText
    }
    
    /// Fuzzy matching: checks if two word arrays are similar enough
    /// Allows for minor differences (case, punctuation)
    private func areSimilar(_ words1: [String], _ words2: [String]) -> Bool {
        guard words1.count == words2.count else { return false }
        
        var matchCount = 0
        for (w1, w2) in zip(words1, words2) {
            if normalizeWord(w1) == normalizeWord(w2) {
                matchCount += 1
            }
        }
        
        // Require at least 80% of words to match
        let matchRatio = Double(matchCount) / Double(words1.count)
        return matchRatio >= 0.8
    }
    
    /// Normalizes a word for comparison (lowercase, remove punctuation)
    private func normalizeWord(_ word: String) -> String {
        return word.lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
    }
    
    /// Resets the deduplication state
    func reset() {
        lastRawText = ""
    }
    
    /// Gets the last raw text
    func getLastRawText() -> String {
        return lastRawText
    }
}

// MARK: - Configuration

struct AppConfig {
    // Segment size in seconds for incremental processing
    static let segmentDuration: TimeInterval = 2.0
    
    // Overlap duration in seconds to handle word boundaries
    // Segments will overlap by this amount to prevent words from being cut
    static let overlapDuration: TimeInterval = 0.3 // 300ms overlap
    
    // Streaming configuration - optimized for more frequent updates
    static let streamingConfig = StreamingAsrConfig(
        chunkSeconds: 4.0,            // Smaller chunks for faster updates
        hypothesisChunkSeconds: 2.0,  // Quick hypothesis updates every 2 seconds
        leftContextSeconds: 4.0,      // Reduced left context
        rightContextSeconds: 2.0,     // Right context lookahead
        minContextForConfirmation: 4.0, // Lower threshold for confirmation
        confirmationThreshold: 0.80   // Slightly lower confidence threshold
    )
}

// MARK: - Main Application

@main
struct Parquet {
    // Deduplication manager for handling overlapping segments
    private let deduplicationManager = DeduplicationManager()
    
    static func main() async {
        // Send initialization messages to stderr to keep stdout clean for transcription output
        fputs("🎤 Speech-to-Text Console Application (Streaming Mode)\n", stderr)
        fputs("======================================================\n", stderr)
        fputs("Using FluidAudio with parakeet-tdt-0.6b-v3-coreml model\n", stderr)
        fputs("Segment duration: \(AppConfig.segmentDuration)s\n", stderr)
        fputs("Segment overlap: \(AppConfig.overlapDuration)s\n\n", stderr)
        
        let app = Parquet()
        await app.run()
    }
    
    func run() async {
        do {
            // Initialize the streaming ASR manager
            fputs("📦 Initializing streaming speech recognition...\n", stderr)
            let streamingManager = try await initializeStreamingManager()
            
            fputs("✅ Model loaded successfully!\n", stderr)
            fputs("🎙️  Ready for real-time audio streaming from stdin\n", stderr)
            fputs("💡 Audio will be processed in \(AppConfig.segmentDuration)s segments\n\n", stderr)
            
            // Start streaming transcription from stdin
            try await transcribeStreamingFromStdin(with: streamingManager)
            
        } catch {
            handleError(error)
        }
    }
    
    // MARK: - Streaming Manager Initialization
    
    private func initializeStreamingManager() async throws -> StreamingAsrManager {
        do {
            // Initialize StreamingAsrManager with custom config
            let streamingManager = StreamingAsrManager(config: AppConfig.streamingConfig)
            
            // Load the parakeet-tdt-0.6b-v3-coreml models
            let models = try await AsrModels.load(
                from: URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
                    .appendingPathComponent("FluidInference")
                    .appendingPathComponent("parakeet")
                    .appendingPathComponent("models"),
                version: .v3
            )
            
            // Start the streaming engine with pre-loaded models
            try await streamingManager.start(models: models, source: .system)
            
            return streamingManager
            
        } catch {
            throw SpeechToTextError.modelInitializationFailed(
                "Failed to initialize streaming parakeet model: \(error.localizedDescription)"
            )
        }
    }
    
    // MARK: - Streaming Audio Capture and Transcription from Stdin
    
    private func transcribeStreamingFromStdin(with streamingManager: StreamingAsrManager) async throws {
        do {
            fputs("📡 Starting real-time audio streaming from stdin...\n", stderr)
            
            // Start listening for transcription updates in a separate task
            let transcriptionTask = Task {
                await handleStreamingTranscriptions(from: streamingManager)
            }
            
            // Stream audio from stdin in chunks
            try await streamAudioFromStdin(to: streamingManager)
            
            // Get final transcription
            fputs("\n🔄 Finalizing transcription...\n", stderr)
            let finalText = try await streamingManager.finish()
            
            // Output final result
            outputFinalTranscription(finalText)
            
            // Cancel the transcription task since we're done
            transcriptionTask.cancel()
            
            // Give it a moment to clean up
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            fputs("\n✅ Streaming transcription complete\n", stderr)
            
        } catch {
            throw SpeechToTextError.audioCaptureFailed(
                "Failed during streaming transcription: \(error.localizedDescription)"
            )
        }
    }
    
    private func streamAudioFromStdin(to streamingManager: StreamingAsrManager) async throws {
        let stdinHandle = FileHandle.standardInput
        
        // Calculate samples per segment (16kHz * segment duration)
        let samplesPerSegment = Int(16000 * AppConfig.segmentDuration)
        let bytesPerSegment = samplesPerSegment * 2 // 16-bit = 2 bytes per sample
        
        // Calculate overlap in bytes
        let overlapSamples = Int(16000 * AppConfig.overlapDuration)
        let overlapBytes = overlapSamples * 2
        
        // Calculate step size (how much to advance between segments)
        let stepBytes = bytesPerSegment - overlapBytes
        
        var segmentCount = 0
        var buffer = Data()
        
        fputs("📊 Processing audio in \(AppConfig.segmentDuration)s segments with \(AppConfig.overlapDuration)s overlap\n", stderr)
        fputs("   Segment size: \(bytesPerSegment) bytes, Step size: \(stepBytes) bytes, Overlap: \(overlapBytes) bytes\n", stderr)
        
        // Read and process audio in overlapping segments
        while true {
            // Try to read a chunk of data
            let chunk = stdinHandle.availableData
            
            if chunk.isEmpty {
                // End of stream - process any remaining data
                if !buffer.isEmpty && buffer.count >= bytesPerSegment / 2 {
                    // Process final segment if it's at least half the normal size
                    processAudioSegment(buffer, segmentIndex: segmentCount, streamingManager: streamingManager)
                }
                break
            }
            
            buffer.append(chunk)
            
            // Process complete segments with overlap
            while buffer.count >= bytesPerSegment {
                let segmentData = buffer.prefix(bytesPerSegment)
                
                processAudioSegment(Data(segmentData), segmentIndex: segmentCount, streamingManager: streamingManager)
                segmentCount += 1
                
                // Advance by step size (segment size - overlap)
                // This keeps the overlap portion in the buffer for the next segment
                buffer.removeFirst(stepBytes)
                
                // Small delay to allow transcription updates to be processed
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }
    }
    
    private func processAudioSegment(_ data: Data, segmentIndex: Int, streamingManager: StreamingAsrManager) {
        do {
            // Convert PCM data to audio buffer
            let audioBuffer = try createAudioBuffer(from: data)
            
            // Stream to the manager asynchronously (don't block)
            Task {
                await streamingManager.streamAudio(audioBuffer)
            }
            
            fputs("📦 Segment \(segmentIndex): Streamed \(data.count) bytes\n", stderr)
            
        } catch {
            fputs("⚠️  Warning: Failed to process segment \(segmentIndex): \(error.localizedDescription)\n", stderr)
        }
    }
    
    private func handleStreamingTranscriptions(from streamingManager: StreamingAsrManager) async {
        for await update in await streamingManager.transcriptionUpdates {
            handleStreamingUpdate(update, deduplicationManager: deduplicationManager)
        }
    }
    
    // MARK: - Audio Conversion
    
    private func createAudioBuffer(from data: Data) throws -> AVAudioPCMBuffer {
        // Create audio format (16kHz, mono, 16-bit PCM)
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechToTextError.audioCaptureFailed("Failed to create audio format")
        }
        
        let frameCount = UInt32(data.count / 2) // 2 bytes per sample (16-bit)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            throw SpeechToTextError.audioCaptureFailed("Failed to create audio buffer")
        }
        
        buffer.frameLength = frameCount
        
        // Copy PCM data to buffer
        data.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) in
            let int16Pointer = rawBufferPointer.bindMemory(to: Int16.self)
            let channelData = buffer.int16ChannelData![0]
            channelData.update(from: int16Pointer.baseAddress!, count: Int(frameCount))
        }
        
        return buffer
    }
    
    // MARK: - Result Handling
    
    private func handleStreamingUpdate(_ update: StreamingTranscriptionUpdate, deduplicationManager: DeduplicationManager) {
        var outputText = update.text
        
        // Apply deduplication only to confirmed transcriptions
        if update.isConfirmed {
            let deduplicatedText = deduplicationManager.deduplicate(update.text)
            outputText = deduplicatedText
            
            // Skip output if deduplicated text is empty (completely duplicate)
            if deduplicatedText.trimmingCharacters(in: .whitespaces).isEmpty {
                fputs("🔄 Skipped duplicate confirmed text\n", stderr)
                return
            }
        }
        
        // Output streaming update as JSON to stdout
        let output: [String: Any] = [
            "type": update.isConfirmed ? "confirmed" : "partial",
            "text": outputText,
            "confidence": update.confidence,
            "timestamp": update.timestamp.timeIntervalSince1970
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
            fflush(stdout)
        }
        
        // Also send human-readable version to stderr
        let emoji = update.isConfirmed ? "✅" : "💬"
        let dedupeNote = update.isConfirmed && outputText != update.text ? " [deduplicated]" : ""
        fputs("\(emoji) \(update.isConfirmed ? "Confirmed" : "Partial"): \(outputText) (confidence: \(String(format: "%.2f", update.confidence)))\(dedupeNote)\n", stderr)
    }
    
    private func outputFinalTranscription(_ text: String) {
        // Output final complete transcription
        let output: [String: Any] = [
            "type": "final",
            "text": text,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
            fflush(stdout)
        }
        
        fputs("📝 Final: \(text)\n", stderr)
    }
    
    // MARK: - Error Handling
    
    private func handleError(_ error: Error) {
        // Send all error messages to stderr
        fputs("\n❌ Error occurred:\n", stderr)
        
        if let speechError = error as? SpeechToTextError {
            switch speechError {
            case .modelInitializationFailed(let message):
                fputs("   Model Initialization Error: \(message)\n", stderr)
                fputs("\n💡 Suggestions:\n", stderr)
                fputs("   - Check your internet connection (model may need to be downloaded)\n", stderr)
                fputs("   - Verify the model ID: FluidInference/parakeet-tdt-0.6b-v3-coreml\n", stderr)
                fputs("   - Ensure you have sufficient disk space for the model\n", stderr)
                
            case .microphonePermissionDenied:
                fputs("   Microphone Permission Denied\n", stderr)
                fputs("\n💡 This error should not occur when using stdin input\n", stderr)
                
            case .audioCaptureFailed(let message):
                fputs("   Audio Capture Error: \(message)\n", stderr)
                fputs("\n💡 Suggestions:\n", stderr)
                fputs("   - Verify audio data is being piped to stdin correctly\n", stderr)
                fputs("   - Check audio format (expected: 16kHz, 16-bit PCM, mono)\n", stderr)
                fputs("   - Ensure the input stream is not empty or corrupted\n", stderr)
                fputs("   - Example: cat audio.wav | ./Parquet\n", stderr)
                
            case .transcriptionFailed(let message):
                fputs("   Transcription Error: \(message)\n", stderr)
                fputs("\n💡 Suggestions:\n", stderr)
                fputs("   - Ensure the audio format matches expected format\n", stderr)
                fputs("   - Check if the model supports your language\n", stderr)
                fputs("   - Verify the model is properly loaded\n", stderr)
            }
        } else {
            fputs("   \(error.localizedDescription)\n", stderr)
        }
        
        fputs("\n", stderr)
        exit(1)
    }
}

// MARK: - Custom Error Types

enum SpeechToTextError: Error, CustomStringConvertible {
    case modelInitializationFailed(String)
    case microphonePermissionDenied
    case audioCaptureFailed(String)
    case transcriptionFailed(String)
    
    var description: String {
        switch self {
        case .modelInitializationFailed(let message):
            return "Model initialization failed: \(message)"
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        case .audioCaptureFailed(let message):
            return "Audio capture failed: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}
