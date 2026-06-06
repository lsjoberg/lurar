#!/usr/bin/env bash
set -e

# Copy scratch EQEngine to Lurar
cp ~/.gemini/antigravity/brain/5e2257ec-6a53-4657-9674-45e0c7ddbaee/scratch/EQEngine.swift /Users/anmol/Documents/lurar/Lurar/AudioEngine/EQEngine.swift

# Patch EQEngine
sed -i '' 's/nonisolated(unsafe) private var rtCrossfeed: Crossfeed?/nonisolated(unsafe) private var rtCrossfeed: Crossfeed?\nnonisolated(unsafe) private var rtCrossfeedEnabled: Bool = true/g' /Users/anmol/Documents/lurar/Lurar/AudioEngine/EQEngine.swift

sed -i '' 's/rtCrossfeed?.process(left: outL, right: outR, frames: frames)/if rtCrossfeedEnabled {\n            rtCrossfeed?.process(left: outL, right: outR, frames: frames)\n        }/g' /Users/anmol/Documents/lurar/Lurar/AudioEngine/EQEngine.swift

sed -i '' 's/@Published private(set) var activeOutput: AudioDevice?/@Published private(set) var activeOutput: AudioDevice?\n    @Published private(set) var crossfeedEnabled: Bool = true/g' /Users/anmol/Documents/lurar/Lurar/AudioEngine/EQEngine.swift

sed -i '' 's/static let muteOnDeviceRateChangeKey = "muteOnDeviceRateChange"/static let muteOnDeviceRateChangeKey = "muteOnDeviceRateChange"\n    static let crossfeedEnabledDefaultsKey = "lurar.crossfeedEnabled"/g' /Users/anmol/Documents/lurar/Lurar/AudioEngine/EQEngine.swift

sed -i '' 's/rtCrossfeed = crossfeed/let crossfeedStored = UserDefaults.standard.object(forKey: Self.crossfeedEnabledDefaultsKey) as? Bool\n        self.crossfeedEnabled = crossfeedStored ?? true\n        rtCrossfeedEnabled = self.crossfeedEnabled\n        rtCrossfeed = crossfeed/g' /Users/anmol/Documents/lurar/Lurar/AudioEngine/EQEngine.swift

# Add setCrossfeedEnabled after setCrossfeedCutoff
sed -i '' '/func setCrossfeedCutoff(_ hz: Float) {/,/}/a\
\
    func setCrossfeedEnabled(_ enabled: Bool) {\
        crossfeedEnabled = enabled\
        rtCrossfeedEnabled = enabled\
        UserDefaults.standard.set(enabled, forKey: Self.crossfeedEnabledDefaultsKey)\
    }
' /Users/anmol/Documents/lurar/Lurar/AudioEngine/EQEngine.swift
