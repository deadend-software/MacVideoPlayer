Run `swift test --package-path tests/AudioEffects --scratch-path /tmp/macvideoplayer-audio-effects-tests` using the same Xcode toolchain as the app.

The Swift Testing suite runs the production enhancer and Apple Accelerate processor against bundled FFmpeg libraries. It checks surround methods with mono, stereo, 5.1, and 7.1 inputs; matrix layouts from mono through 7.1; presets; Core Audio speaker order; DVD WG4 channel reordering; and every video AI reset control.

Individual speaker tones verify that authored center, LFE, rear, and side channels remain isolated. Full-scale stereo and mono tests check hard-left/right preservation, a front-dominant center balance, quiet synthesized ambience for correlated material, rear/side ambience separation, silence, and low-frequency-only subwoofer output.

These checks do not open audio hardware or verify physical speaker wiring.

Surround Fill tests cover mono, stereo, center-only 5.1/5.1(side)/7.1, silence after reset, and full-scale multichannel downmix headroom. AC-3 and DTS tests encode enhanced mono to 5.1, decode it back to PCM, and measure both surround channels.

In the app, choose AI Audio → Cinema Clarity + Surround (DSP), or enable Gentle Noise Reduction + Clarity, Bass Extension (DSP), and Surround Fill with an Apple upmixer individually. These are signal-processing effects, not trained AI restoration or generated musical performances. Export Enhanced Audio creates a 48 kHz 5.1 AC-3 or DTS file; live playback remains PCM. Audio Output → Test Speakers plays quiet sequential tones on the selected device. Physical surround requires six/eight exposed PCM channels and correct speaker assignments in Audio MIDI Setup.
