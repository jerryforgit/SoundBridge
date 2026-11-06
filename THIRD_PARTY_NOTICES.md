# Third-party notices

## libASPL

`driver/third_party/libASPL` is vendored from
[gavv/libASPL](https://github.com/gavv/libASPL) and is licensed under the MIT
License. Its original license text is kept in
`driver/third_party/libASPL/LICENSE`.

libASPL is used as the AudioServerPlugIn boilerplate for the SoundBridge HAL
driver. The SoundBridge-specific device, loopback, volume/mute properties and
shared-memory writer are implemented in `driver/SoundBridge`.

## Apple Audio Units

SoundBridge uses Apple's `AUMatrixReverb` system Audio Unit
(`kAudioUnitSubType_MatrixReverb`) through the AudioToolbox framework. No Apple
framework code is redistributed in this repository.

`AUMatrixReverb` is a system component provided by macOS.

## SpeakerAmp

SpeakerAmp is a separate commercial application. This project is not
affiliated with it. SpeakerAmp was used only as an A/B reference while tuning
the spatial effect. No SpeakerAmp code or assets are included.

## BlackHole

BlackHole was referenced conceptually for HAL virtual-device behavior. No
BlackHole source code is included in this repository.
