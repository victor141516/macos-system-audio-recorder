import Foundation
import Dispatch
import Darwin

// Initial message
Logger.log("System Audio Recorder (WAV output to stdout)", level: .info)
Logger.log("You may need to grant Screen Recording permission in System Settings > Privacy & Security", level: .info)


// Función para manejar los datos PCM capturados (en este caso, escribir a stdout)
func writeToStdout(_ data: Data) {
    // Escribe los datos directamente a la salida estándar
    FileHandle.standardOutput.write(data)
}

// Configure audio processor
let audioProcessor = PCMAudioProcessor(outputStream: writeToStdout)

// Create and initialize audio capture service
let captureService = SystemAudioCapture(audioProcessor: audioProcessor)


// Register signal handler
SignalHandler.register(captureService: captureService)

Logger.log("Starting system audio capture...", level: .info)
Logger.log("Press Ctrl+C to stop recording", level: .info)

// Start in an async task and keep main thread alive
Task {
    do {
        try await captureService.start()
    } catch {
        Logger.log("Error: \(error.localizedDescription)", level: .error)
        exit(1)
    }
}

// Keep main thread alive until signal handler stops the program
dispatchMain()