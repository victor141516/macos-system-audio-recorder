# Parquet

A console-based speech-to-text application for macOS devices equipped with an NPU. It leverages the FluidAudio framework and the Parakeet-TDT-0.6B-v3 CoreML model, which must be downloaded locally and will occupy several megabytes of storage.

## Features

- Real-time streaming speech-to-text multilingual transcription
- Processes audio from standard input in 2-second segments with 0.3 seconds overlap
- Supports ffmpeg audio input and microphone capture

## Requirements

- macOS device with NPU
- Storage space for the Parakeet-TDT-0.6B-v3 model

## Installation

```bash
swift build -c release
```

The compiled binary will be at `.build/release/Parquet`.

## Usage

Audio data must be streamed to the application's standard input. Use tools like ffmpeg or system microphone with appropriate piping.

### Example (FFmpeg)

```bash
ffmpeg -i input_file.mp3 -f s16le -ac 1 -ar 16000 - | .build/release/Parquet
```

### Example (Microphone)

```bash
ffmpeg -f avfoundation -i ":1" -f s16le -ac 1 -ar 16000 - | .build/release/Parquet
```

## Input Format

- **Sample Rate**: 16,000 Hz
- **Bit Depth**: 16-bit signed integer
- **Channels**: Mono (1 channel)
- **Encoding**: PCM (raw, uncompressed)

## Output Format

JSON messages to stdout:

```json
{
  "type": "confirmed",
  "text": "transcribed text",
  "confidence": 0.95,
  "timestamp": 1729771040.456
}
```

Logs are sent to stderr.
