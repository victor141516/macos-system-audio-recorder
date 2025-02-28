import Foundation
import Speech
import AVFoundation

// Función para imprimir la ayuda
func printHelp() {
    fputs("""
    Uso: programa [opciones]
    
    Opciones:
      -l, --language CÓDIGO   Especifica el idioma para el reconocimiento de voz (ej: es-ES, en-US)
      -n, --newline          Añade saltos de línea después de cada segmento de texto
      -h, --help             Muestra esta ayuda
    
    Ejemplos de códigos de idioma:
      es-ES   Español (España)
      es-MX   Español (México)
      en-US   Inglés (Estados Unidos)
      en-GB   Inglés (Reino Unido)
      fr-FR   Francés (Francia)
      de-DE   Alemán (Alemania)
    
    """, stderr)
    exit(0)
}

// Función para analizar argumentos
func parseArguments() -> (locale: Locale, addNewlines: Bool) {
    // Valor predeterminado
    var languageCode = "en-US"
    var addNewlines = false
    
    // Obtener argumentos
    let args = CommandLine.arguments
    
    // Procesar argumentos
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
                fputs("Error: El argumento -l/--language requiere un valor\n", stderr)
                exit(1)
            }
        default:
            fputs("Argumento desconocido: \(args[i])\n", stderr)
            fputs("Use --help para ver las opciones disponibles\n", stderr)
            exit(1)
        }
        i += 1
    }
    
    // Crear objeto Locale con el código de idioma
    let locale = Locale(identifier: languageCode)
    
    // Validar que el idioma sea compatible
    if SFSpeechRecognizer(locale: locale) == nil {
        fputs("Error: El idioma '\(languageCode)' no es compatible con el reconocimiento de voz\n", stderr)
        fputs("Ejemplos de idiomas compatibles: es-ES, en-US, fr-FR, de-DE, it-IT...\n", stderr)
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
    
    // Control de salida de texto
    private var lastProcessedText = ""
    private var lastStableTime = Date()
    private var pendingText = ""
    
    init(locale: Locale, addNewlines: Bool = false) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            fatalError("No se pudo inicializar el reconocedor para el idioma \(locale.identifier)")
        }
        self.speechRecognizer = recognizer
        self.addNewlines = addNewlines
    }
    
    private func getNewText(from fullText: String) -> String? {
        // Si el texto es más corto que el anterior, es una corrección completa
        if fullText.count <= lastProcessedText.count && fullText != lastProcessedText {
            lastProcessedText = ""
            return fullText
        }
        
        // Si es el mismo texto, no hay nada nuevo
        if fullText == lastProcessedText {
            return nil
        }
        
        // Extraer solo el texto nuevo
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
            fputs("Error: No hay entrada de audio. Use el programa con pipe\n", stderr)
            exit(1)
        }

        fputs("Solicitando permisos de reconocimiento de voz...\n", stderr)
        
        var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
        let authSemaphore = DispatchSemaphore(value: 0)
        
        SFSpeechRecognizer.requestAuthorization { status in
            authStatus = status
            authSemaphore.signal()
        }
        
        if authSemaphore.wait(timeout: .now() + 5) == .timedOut {
            fputs("Error: Timeout esperando autorización\n", stderr)
            exit(1)
        }
        
        guard authStatus == .authorized else {
            fputs("Error: No hay autorización para reconocimiento de voz\n", stderr)
            exit(1)
        }
        
        fputs("Autorización concedida. Procesando audio...\n", stderr)
        
        // Configurar el formato de audio
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: true
        )!
        
        // Crear request de reconocimiento
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            fputs("Error: No se pudo crear el request de reconocimiento\n", stderr)
            exit(1)
        }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true
        // recognitionRequest.addsDependentContent = true
        
        // Crear tarea de reconocimiento
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                fputs("Error durante el reconocimiento: \(error.localizedDescription)\n", stderr)
                return
            }
            
            if let result = result {
                let transcription = result.bestTranscription.formattedString
                
                if result.isFinal {
                    // Resultado final - procesar y mostrar nuevas palabras
                    if let newText = self.getNewText(from: transcription) {
                        self.writeToStdout(newText)
                    }
                } else {
                    // Resultado parcial - actualizar pero esperar a que sea estable
                    let now = Date()
                    self.pendingText = transcription
                    
                    // Si ha pasado suficiente tiempo desde la última actualización estable
                    if now.timeIntervalSince(self.lastStableTime) >= 5.0 {
                        if let newText = self.getNewText(from: transcription) {
                            self.writeToStdout(newText)
                            self.lastStableTime = now
                        }
                    }
                }
            }
        }
        
        fputs("Leyendo PCM desde stdin en streaming...\n", stderr)
        
        // Configurar stdin para lectura sin bloqueo
        let fileDescriptor = FileHandle.standardInput.fileDescriptor
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        
        // Calcular tamaño de buffer para 0.1 segundos (100ms) de audio
        // 48000Hz * 2 canales * 4 bytes * 0.1s = 38400 bytes
        let bytesPerChunk = 38400
        let byteBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerChunk)
        defer { byteBuffer.deallocate() }
        
        // Mantener el programa activo para streaming continuo
        var lastReadTime = Date()
        
        // Crear un timer para verificar si debemos terminar
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            // Si no hemos recibido datos en 2 segundos, terminamos
            if Date().timeIntervalSince(lastReadTime) > 2.0 {
                fputs("\nNo se han recibido datos en 2 segundos. Finalizando reconocimiento...\n", stderr)
                self.isRunning = false
            }
        }
        
        // Bucle principal de procesamiento
        while isRunning {
            // Leer datos sin bloqueo
            let bytesRead = read(fileDescriptor, byteBuffer, bytesPerChunk)
            
            if bytesRead > 0 {
                lastReadTime = Date()
                
                // Calcular número de frames (muestras por canal)
                let framesRead = bytesRead / (MemoryLayout<Float32>.stride * Int(format.channelCount))
                
                // Crear buffer de audio
                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesRead)) else {
                    fputs("Error creando buffer de audio\n", stderr)
                    continue
                }
                
                pcmBuffer.frameLength = AVAudioFrameCount(framesRead)
                
                // Copiar datos al buffer de audio
                if let ptr = pcmBuffer.floatChannelData?[0] {
                    memcpy(ptr, byteBuffer, bytesRead)
                }
                
                // Enviar al motor de reconocimiento
                recognitionRequest.append(pcmBuffer)
            } else if bytesRead < 0 && errno != EAGAIN {
                // Error de lectura que no es por no-bloqueo
                fputs("Error leyendo desde stdin: \(String(cString: strerror(errno)))\n", stderr)
                break
            } else {
                // Sin datos disponibles por ahora o fin de archivo
                // Pequeña pausa para no consumir CPU
                usleep(10000) // 10ms
            }
            
            // Procesar eventos
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        
        timer.invalidate()
        
        // Finalizar reconocimiento
        recognitionRequest.endAudio()
        fputs("Reconocimiento finalizado\n", stderr)
        // Asegurar que el último resultado tiene un salto de línea
        writeToStdout("\n")
    }
}

// Manejar Ctrl+C
signal(SIGINT) { _ in
    print("\nCancelando reconocimiento...")
    exit(0)
}

// Ejecutar el reconocimiento
do {
    let args = parseArguments()
    fputs("Idioma seleccionado para reconocimiento: \(args.locale.identifier)\n", stderr)
    let recognizer = SpeechRecognizer(locale: args.locale, addNewlines: args.addNewlines)
    try recognizer.processStdin()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}