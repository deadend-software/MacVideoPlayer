import Testing
import CEffects

@Suite(.serialized)
struct AudioEffectsTests {
    @Test(arguments: ["mono", "stereo", "2.1", "quad", "4.1", "5.0", "5.1", "7.1"])
    func speakerOrder(layout: String) {
        #expect(VPCheckSpeakerOrder(layout))
    }

    @Test(arguments: ["mono", "stereo", "5.1", "7.1"])
    func surroundMethods(input: String) {
        for (method, layout, channels) in [
            ("apple_spatial", "auto", 2), ("apple_51", "5.1", 6),
            ("apple_71", "7.1", 8), ("ffmpeg_51", "5.1", 6),
            ("ffmpeg_71", "7.1", 8), ("stereo_wide", "auto", 2),
            ("subwoofer_21", "2.1", 3)
        ] {
            #expect(VPCheckAudioGraph(method, layout, input, Int32(channels)))
        }
    }

    @Test(arguments: ["mono", "stereo", "5.1", "7.1"])
    func matrixLayouts(input: String) {
        for (layout, channels) in [("mono", 1), ("stereo", 2), ("2.1", 3), ("4.0", 4), ("4.1", 5), ("5.0", 5), ("5.1", 6), ("7.1", 8)] {
            #expect(VPCheckAudioGraph("matrix_ai", layout, input, Int32(channels)))
        }
    }

    @Test func videoStartsOffAndResetClearsEveryControl() {
        #expect(VPCheckVideoReset())
    }

    @Test func audioPresets() {
        for (preset, channels) in [("cinema_restore", 8), ("clear_dialogue", 2), ("spatial_3d", 2), ("surround_51", 6), ("surround_71", 8), ("studio_master", 2), ("night_mode", 2), ("loudnorm", 2), ("bass_punch", 3)] {
            #expect(VPCheckAudioGraph("preset:" + preset, "auto", "stereo", Int32(channels)))
        }
    }

    @Test(arguments: ["5.1", "7.1"], [0, 1, 2, 3, 4, 5])
    func appleDirectionalContent(layout: String, scenario: Int32) {
        #expect(VPCheckAppleDirections(layout, scenario))
    }

    @Test(arguments: ["apple_51", "apple_71", "ffmpeg_51", "ffmpeg_71"])
    func authoredSpeakersRemainIsolated(method: String) {
        #expect(VPCheckAuthoredChannels(method, method.hasSuffix("71") ? "7.1" : "5.1"))
    }

    @Test func dvdDecoderChannelOrder() {
        #expect(VPCheckDVDOrder())
    }

    @Test(arguments: ["5.1", "7.1"])
    func convertedAppleSurround(layout: String) {
        #expect(VPCheckConvertedSurround(layout))
    }
    @Test(arguments: ["mono", "stereo", "5.1", "5.1(side)", "7.1"], ["5.1", "7.1"])
    func surroundFillFeedsQuietRears(input: String, output: String) {
        #expect(VPCheckSurroundFill(input, output))
    }

    @Test(arguments: ["ac3", "dts"])
    func encodedSurroundRoundTrip(codec: String) {
        #expect(VPCheckEncodedSurround(codec))
    }

    @Test func audioEnhancementReset() {
        #expect(VPCheckAudioEnhancementReset())
    }

}
