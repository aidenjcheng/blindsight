# BlindNav - Indoor Navigation for Blind Users

An iOS app that guides blind users through indoor environments using on-device ML models, ARKit SLAM, Gemini 3 Flash scene reasoning, and spatial audio.

## How It Works

1. **User speaks a destination** (e.g., "bathroom", "elevator", "exit")
2. **Gemini 3 Flash** analyzes the camera feed and SLAM map to pick an intermediate landmark/object as a waypoint
3. **YOLOE** detects and tracks that object in real-time using open-vocabulary text prompts
4. **Spatial audio** guides the user toward the waypoint via 3D-positioned sound in AirPods
5. **Depth estimation** (MiDaS v2.1 Small) and **ground segmentation** (MobileNetV4-Small) run continuously for obstacle avoidance
6. **ARKit** provides 6DOF SLAM tracking — maintains phantom coordinates when objects leave the frame and detects circular movement
7. Steps 2–6 loop: when a waypoint is reached, Gemini picks the next one until the destination is found

## Architecture

```
Camera (30fps) ──┬──> MiDaS Depth ──────> Obstacle Avoidance ──┐
                 ├──> Ground Segmentation -> Ground Safety ─────┤
                 ├──> YOLOE (goal tracking) ────────────────────┼──> Navigation Engine ──> Spatial Audio + TTS + Haptics
                 ├──> YOLOE (destination scan) ─────────────────┤
                 └──> ARKit SLAM ───────────────────────────────┘
                                                                        │
                 Camera Snapshot + SLAM Summary ──> Gemini 3 Flash ─────┘
```

## Requirements

- iPhone 11 or newer
- iOS 16.0+
- Xcode 16.0+ / Swift 5.10+
- AirPods (recommended for spatial audio; falls back to device speaker)
- Gemini API key (from [Google AI Studio](https://aistudio.google.com/))

## Setup

### 1. Install XcodeGen (if not installed)

```bash
brew install xcodegen
```

### 2. Prepare ML Models

```bash
cd ModelConversion
pip install -r requirements.txt

# Export YOLOE-11S to CoreML
python export_yoloe_coreml.py

# Export ground segmentation model to CoreML
python export_ground_seg_coreml.py

# Download and convert MiDaS v2.1 Small to CoreML
python download_midas_coreml.py
```

The exported `.mlpackage` files will be placed in `BlindNav/Resources/CoreMLModels/`.

### 3. Generate Xcode Project

```bash
cd ..  # back to BlindNav root
xcodegen generate
```

### 4. Open in Xcode

```bash
open BlindNav.xcodeproj
```

### 5. Configure

- Add your Gemini API key in the app's Settings screen
- Set your development team in Xcode's Signing & Capabilities
- The app requires Camera, Microphone, Speech Recognition, and Motion permissions (prompts appear on first launch)

### 6. Build & Run

Build and run on a physical iPhone (ARKit requires a real device).

## Project Structure

```
BlindNav/
├── BlindNav/
│   ├── App/                    App entry point and global state
│   ├── Models/                 Data models (navigation state, goals, maps)
│   ├── Services/
│   │   ├── CameraService       AVCaptureSession frame distribution
│   │   ├── DepthEstimation     MiDaS v2.1 Small CoreML inference
│   │   ├── GroundSegmentation  MobileNetV4-Small binary ground mask
│   │   ├── YOLOEService        Open-vocab detection with instance locking
│   │   ├── GeminiService       Gemini 3 Flash API for scene reasoning
│   │   ├── SLAMService         ARKit 6DOF tracking and visited-area map
│   │   ├── SpatialAudio        3D positional audio via AVAudioEngine
│   │   ├── SpeechService       Speech recognition + TTS
│   │   ├── HapticService       Core Haptics for safety feedback
│   │   └── NavigationEngine    Core orchestrator / state machine
│   ├── Views/                  SwiftUI views (Home, Navigation, Settings)
│   ├── Utilities/              Logging and constants
│   └── Resources/              Info.plist, entitlements, audio, CoreML models
├── ModelConversion/            Python scripts for model export
├── project.yml                 XcodeGen project specification
└── README.md
```

## Safety Design

1. **Obstacle collision prevention** — highest priority, overrides all navigation
2. **Ground safety** — prevents walking off ledges, stairs, or non-walkable surfaces
3. **Navigation accuracy** — third priority; safe > fast
4. **Emergency stop** — triple-tap screen or say "Stop"
5. **Redundant feedback** — all warnings use audio + haptics + TTS
6. **Cautious mode** — if ML models fail, system warns and pauses guidance
7. **Anti-circling** — SLAM detects loops and injects context into Gemini

## ML Models

| Model | Purpose | Size | Speed |
|-------|---------|------|-------|
| MiDaS v2.1 Small | Monocular depth estimation | ~20 MB | ~15ms/frame |
| MobileNetV4-Small + ASPP | Binary ground segmentation | ~15 MB | ~10ms/frame |
| YOLOE-11S | Open-vocabulary object detection | ~30 MB | ~20ms/frame |

All models run on the Neural Engine via CoreML for maximum efficiency.

## License

This project is for research and accessibility purposes.
