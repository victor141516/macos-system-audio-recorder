# macOS System Audio Recorder

A tool for recording and transcribing system audio on macOS using ScreenCaptureKit and Apple's speech recognition framework.

## 📋 Description

macOS System Audio Recorder is a command-line utility that allows you to:

1. **Capture system audio** - Record any audio playing on your Mac
2. **Transcribe audio to text** - Convert captured audio to text using speech recognition
3. **Manipulate audio streams** - Process raw PCM for use with other tools

## ✨ Features

### System Audio Recorder

- Direct system audio capture using modern macOS APIs
- Raw PCM output format (32-bit float, stereo, 48kHz)
- Low resource consumption
- Simple command-line interface

### Speech Recognition

- Real-time audio-to-text transcription
- Support for multiple languages (Spanish, English, French, German, etc.)
- Text output formatting options
- Automatic punctuation support

## 🛠️ Installation

### Prerequisites

- macOS 12 (Monterey) or higher
- Screen Recording permissions (required for system audio capture)

### Building

```bash
# Clone the repository
git clone https://github.com/user/macos-system-audio-recorder.git
cd macos-system-audio-recorder

# Build the tools
chmod +x build.sh
./build.sh
```

The compiled executables will be available in the `build/` directory.

## 📝 Usage

### System Audio Recording

```bash
# Record system audio and save as PCM file
./build/SystemAudioRecorder > recorded_audio.pcm

# Record and convert to WAV (requires SoX)
./build/SystemAudioRecorder | sox -t raw -r 48k -e float -b 32 -c 2 - output.wav
```

### Speech Recognition

```bash
# Transcribe audio from a source (e.g., system audio recorder)
./build/SystemAudioRecorder | ./build/SpeechRegonition -l en-US

# Transcribe with line breaks after each segment
./build/SystemAudioRecorder | ./build/SpeechRegonition -l en-US -n

# View help options
./build/SpeechRegonition --help
```

## 🔧 Speech Recognition Options

- `-l, --language CODE`: Specifies the language for voice recognition (e.g., en-US, es-ES)
- `-n, --newline`: Adds line breaks after each text segment
- `-h, --help`: Shows help

### Supported Language Codes

- `en-US`: English (United States)
- `en-GB`: English (United Kingdom)
- `es-ES`: Spanish (Spain)
- `es-MX`: Spanish (Mexico)
- `fr-FR`: French (France)
- `de-DE`: German (Germany)
- And many more...

## ⚠️ Required Permissions

To use this tool, you'll need to grant **Screen Recording** permissions to your Terminal or application:

1. The first time you run the application, macOS will request the necessary permissions
2. You can also enable them manually in **System Settings > Privacy & Security > Screen Recording**

## 📚 Use Case Examples

- Real-time transcription of meetings or conferences
- Creating subtitles for videos
- Recording music or streaming content
- Audio processing for analysis

## 📄 License

This project is distributed under MIT License.

## 👥 Contributions

Contributions are welcome. Please feel free to submit pull requests or create issues if you find any problems.

---

⭐ If you find this tool useful, consider giving it a star on GitHub!
