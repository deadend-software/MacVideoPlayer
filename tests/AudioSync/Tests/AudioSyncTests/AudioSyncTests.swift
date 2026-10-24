import Testing
import CSync

@Test func firstQueryDoesNotLoseAlreadyPlayedSamples() {
    var sync = VPAudioSync()
    VPAudioSyncReset(&sync, 10)
    VPAudioSyncAppend(&sync, 10, 2400, 2400, 48000)
    #expect(abs(VPAudioSyncClock(&sync, 1200, 48000) - 10.025) < 0.000001)
}

@Test func underrunHoldsClockAndRecoveryResumesFromSamePosition() {
    var sync = VPAudioSync()
    VPAudioSyncReset(&sync, 0)
    VPAudioSyncAppend(&sync, 0, 1200, 2400, 48000)
    VPAudioSyncAppend(&sync, 0.025, 0, 2400, 48000)
    VPAudioSyncAppend(&sync, 0.025, 2400, 2400, 48000)
    #expect(abs(VPAudioSyncClock(&sync, 1800, 48000) - 0.025) < 0.000001)
    #expect(abs(VPAudioSyncClock(&sync, 4000, 48000) - 0.025) < 0.000001)
    #expect(abs(VPAudioSyncClock(&sync, 6000, 48000) - 0.050) < 0.000001)
    #expect(abs(VPAudioSyncClock(&sync, 9000, 48000) - 0.075) < 0.000001)
}

@Test func seekResetsClockAndStaleTimestampCannotRegressIt() {
    var sync = VPAudioSync()
    VPAudioSyncReset(&sync, 100)
    VPAudioSyncAppend(&sync, 100, 4800, 4800, 48000)
    #expect(abs(VPAudioSyncClock(&sync, 2400, 48000) - 100.05) < 0.000001)
    #expect(abs(VPAudioSyncClock(&sync, 1200, 48000) - 100.05) < 0.000001)
    VPAudioSyncReset(&sync, 5)
    #expect(VPAudioSyncClock(&sync, 0, 48000) == 5)
}

@Test(arguments: [44100.0, 48000.0, 96000.0])
func longPlaybackWrapsHistoryWithoutDrift(rate: Double) {
    var sync = VPAudioSync()
    VPAudioSyncReset(&sync, 0)
    let frames = rate * 0.05
    for index in 0..<100_000 {
        VPAudioSyncAppend(&sync, Double(index) * 0.05, frames, frames, rate)
        let clock = VPAudioSyncClock(&sync, (Double(index) + 0.5) * frames, rate)
        #expect(abs(clock - (Double(index) + 0.5) * 0.05) < 0.000001)
    }
}
