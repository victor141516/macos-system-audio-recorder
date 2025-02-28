#!/bin/sh

mkdir -p build
swiftc SpeechRegonition.swift -o build/SpeechRegonition
swiftc SystemAudioRecorder.swift -o build/SystemAudioRecorder