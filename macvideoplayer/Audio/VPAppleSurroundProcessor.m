#import "VPAppleSurroundProcessor.h"
#import <Accelerate/Accelerate.h>

@implementation VPAppleSurroundProcessor {
    SwrContext *_converter;
    AVChannelLayout _inputLayout;
    AVChannelLayout _conversionLayout;
    enum AVSampleFormat _inputFormat;
    int _sampleRate;
    AVFrame *_stereo;
    AVFrame *_output;
    float _bass1, _bass2;
    float _leftPower, _rightPower, _crossPower;
    float _bedLeft, _bedRight;                  // low-pass state of the quiet ambience bed
    float *_delayLeft, *_delayRight;
    size_t _delaySize, _delayIndex;
}

- (void)dealloc { [self reset]; }

- (void)reset {
    swr_free(&_converter);
    av_channel_layout_uninit(&_inputLayout);
    av_channel_layout_uninit(&_conversionLayout);
    av_frame_free(&_stereo);
    av_frame_free(&_output);
    free(_delayLeft); free(_delayRight);
    _delayLeft = _delayRight = NULL;
    _delaySize = _delayIndex = 0;
    _sampleRate = 0;
    _bass1 = _bass2 = 0;
    _leftPower = _rightPower = _crossPower = 0;
    _bedLeft = _bedRight = 0;
}

- (AVFrame *)processFrame:(AVFrame *)frame layout:(NSString *)layout {
    if (!frame || frame->nb_samples <= 0 || frame->sample_rate <= 0) return frame;
    BOOL expandSurround = [layout isEqual:@"7.1"] &&
        (frame->ch_layout.nb_channels == 5 || frame->ch_layout.nb_channels == 6);
    BOOL fillAuthored = self.surroundFill && frame->ch_layout.nb_channels > 2;
    // Preserve authored channels unless the listener explicitly enables surround fill.
    if (frame->ch_layout.nb_channels > 2 && !expandSurround && !fillAuthored) return frame;
    BOOL seven = [layout isEqual:@"7.1"];
    if (!seven && ![layout isEqual:@"5.1"]) return frame;
    AVChannelLayout targetLayout = seven ? (AVChannelLayout)AV_CHANNEL_LAYOUT_7POINT1 : (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1;
    AVChannelLayout stereoLayout = AV_CHANNEL_LAYOUT_STEREO;
    const AVChannelLayout *conversionLayout = fillAuthored ? &targetLayout : expandSurround ? &frame->ch_layout : &stereoLayout;
    if (!_converter || av_channel_layout_compare(&_conversionLayout, conversionLayout) != 0 || _sampleRate != frame->sample_rate || _inputFormat != frame->format ||
        av_channel_layout_compare(&_inputLayout, &frame->ch_layout) != 0) {
        [self reset];
        _sampleRate = frame->sample_rate;
        _inputFormat = frame->format;
        av_channel_layout_copy(&_inputLayout, &frame->ch_layout);
        av_channel_layout_copy(&_conversionLayout, conversionLayout);
        if (swr_alloc_set_opts2(&_converter, conversionLayout, AV_SAMPLE_FMT_FLTP, _sampleRate,
                               &_inputLayout, _inputFormat, _sampleRate, 0, NULL) < 0) { [self reset]; return frame; }
        // Reserve headroom when folding an authored 7.1 stream into 5.1.
        av_opt_set_double(_converter, "rematrix_maxval", 1.0, 0);
        if (swr_init(_converter) < 0) { [self reset]; return frame; }
        _stereo = av_frame_alloc();
        _output = av_frame_alloc();
        _delaySize = (size_t)ceil(_sampleRate * 0.04) + 1;   // longest tap is 13 ms
        _delayLeft = calloc(_delaySize, sizeof(float));
        _delayRight = calloc(_delaySize, sizeof(float));
        if (!_stereo || !_output || !_delayLeft || !_delayRight) { [self reset]; return frame; }
    }
    av_frame_unref(_stereo);
    _stereo->format = AV_SAMPLE_FMT_FLTP;
    _stereo->sample_rate = _sampleRate;
    _stereo->nb_samples = frame->nb_samples;
    av_channel_layout_copy(&_stereo->ch_layout, &_conversionLayout);
    if (av_frame_get_buffer(_stereo, 0) < 0) return frame;
    int count = swr_convert(_converter, _stereo->data, frame->nb_samples,
                            (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (count <= 0) return frame;
    av_frame_unref(_output);
    _output->format = AV_SAMPLE_FMT_FLTP;
    _output->sample_rate = _sampleRate;
    _output->nb_samples = count;
    _output->pts = frame->pts;
    av_channel_layout_from_string(&_output->ch_layout, seven ? "7.1" : "5.1");
    if (av_frame_get_buffer(_output, 0) < 0) return frame;
    // Design notes for everything below: speakers that play the same signal at different delays comb-filter each
    // other whenever a device folds the channels back down (stereo speakers, headphones, an AVR in 2.0), which is
    // heard as a phasey, wavy tone. Gains that follow a fast correlation estimate pump in the same way. So the
    // surrounds carry either their own authored content, the stereo *difference* (which is decorrelated from the
    // fronts by nature), or a quiet low-passed bed, and no gain below moves faster than about a second.
    float bedCoefficient = 1.0f - expf(-2.0f * (float)M_PI * 4000.0f / _sampleRate);
    if (fillAuthored) {
        for (int c = 0; c < _output->ch_layout.nb_channels; c++)
            memcpy(_output->data[c], _stereo->data[c], count * sizeof(float));
        // A very quiet, low-passed front bed keeps surrounds from sitting silent during center-only dialogue.
        size_t bedDelay = (size_t)(_sampleRate * 0.013);
        for (int i = 0; i < count; i++) {
            float l = ((float *)_output->data[0])[i], r = ((float *)_output->data[1])[i];
            float c = ((float *)_output->data[2])[i];
            _bedLeft += bedCoefficient * ((0.6f * l + 0.25f * r + 0.15f * c) - _bedLeft);
            _bedRight += bedCoefficient * ((0.6f * r + 0.25f * l + 0.15f * c) - _bedRight);
            _delayLeft[_delayIndex] = _bedLeft;
            _delayRight[_delayIndex] = _bedRight;
            size_t tap = (_delayIndex + _delaySize - bedDelay) % _delaySize;
            for (int channel = 4; channel < _output->ch_layout.nb_channels; channel++) {
                float *out = (float *)_output->data[channel];
                out[i] += 0.08f * (channel % 2 ? _delayRight[tap] : _delayLeft[tap]);
            }
            _delayIndex = (_delayIndex + 1) % _delaySize;
        }
        return _output;
    }
    if (expandSurround) {
        // Retain fronts, dialogue and bass. The authored surround pair is shared between the sides and the backs
        // at equal level and in phase, so folding them back down returns the original surround level.
        enum AVChannel speakers[] = {AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY,
                                     AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT, AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT};
        for (int c = 0; c < 8; c++) {
            float *out = (float *)_output->data[c];
            memset(out, 0, count * sizeof(float));
            if (c == 4 || c == 5) continue;
            int index = av_channel_layout_index_from_channel(&_inputLayout, speakers[c]);
            if (index < 0 && c >= 6) index = av_channel_layout_index_from_channel(&_inputLayout, c == 6 ? AV_CHAN_BACK_LEFT : AV_CHAN_BACK_RIGHT);
            if (index >= 0) memcpy(out, _stereo->data[index], count * sizeof(float));
        }
        for (int i = 0; i < count; i++) {
            ((float *)_output->data[4])[i] = 0.5f * ((float *)_output->data[6])[i];
            ((float *)_output->data[5])[i] = 0.5f * ((float *)_output->data[7])[i];
            ((float *)_output->data[6])[i] *= 0.5f;
            ((float *)_output->data[7])[i] *= 0.5f;
        }
        return _output;
    }
    float *left = (float *)_stereo->data[0], *right = (float *)_stereo->data[1];
    float *frontLeft = (float *)_output->data[0], *frontRight = (float *)_output->data[1];
    float *center = (float *)_output->data[2], *lfe = (float *)_output->data[3];
    float *rearLeft = (float *)_output->data[4], *rearRight = (float *)_output->data[5];
    // Fronts keep their stereo image at a fixed level; the center only adds the common part on top.
    float frontGain = 0.8f;
    vDSP_vsmul(left, 1, &frontGain, frontLeft, 1, count);
    vDSP_vsmul(right, 1, &frontGain, frontRight, 1, count);
    // Stereo correlation is only a slow hint (about 0.6 s) for how much the center adds, so it never pumps.
    float steeringCoefficient = 1.0f - expf(-1.0f / (0.6f * _sampleRate));
    // Split ambience energy across two pairs in 7.1 instead of making it louder.
    float surroundGain = seven ? 0.70710678f : 1.0f;
    float bassCoefficient = 1.0f - expf(-2.0f * (float)M_PI * 120.0f / _sampleRate);
    size_t sideDelay = (size_t)(_sampleRate * 0.007);
    size_t rearDelay = (size_t)(_sampleRate * 0.013);
    // The quiet bed is only for listeners who enable surround fill; it is low-passed, so any residual comb stays below 4 kHz.
    float bedGain = self.surroundFill ? 0.18f : 0.0f;
    for (int i = 0; i < count; i++) {
        _leftPower += steeringCoefficient * (left[i] * left[i] - _leftPower);
        _rightPower += steeringCoefficient * (right[i] * right[i] - _rightPower);
        _crossPower += steeringCoefficient * (left[i] * right[i] - _crossPower);
        float power = _leftPower + _rightPower;
        float coherence = power > 1e-12f ? fminf(1.0f, fmaxf(0.0f, 2.0f * _crossPower / power)) : 0;
        float mid = 0.5f * (left[i] + right[i]);
        center[i] = (0.34f + 0.12f * coherence) * mid;
        // The stereo difference is decorrelated from the fronts, so the rears can play it undelayed and without
        // combing; it is synthesized ambience, not recovered discrete surround information.
        float difference = 0.5f * (left[i] - right[i]);
        _bedLeft += bedCoefficient * (mid - _bedLeft);
        _delayLeft[_delayIndex] = bedGain * _bedLeft;
        size_t back = (_delayIndex + _delaySize - rearDelay) % _delaySize;
        size_t side = (_delayIndex + _delaySize - sideDelay) % _delaySize;
        rearLeft[i] = surroundGain * (0.7f * difference + _delayLeft[back]);
        rearRight[i] = surroundGain * (-0.7f * difference + _delayLeft[back]);
        if (seven) {
            ((float *)_output->data[6])[i] = surroundGain * (0.7f * difference + _delayLeft[side]);
            ((float *)_output->data[7])[i] = surroundGain * (-0.7f * difference + _delayLeft[side]);
        }
        _delayIndex = (_delayIndex + 1) % _delaySize;
        _bass1 += bassCoefficient * (mid - _bass1);
        _bass2 += bassCoefficient * (_bass1 - _bass2);
        lfe[i] = 0.5f * _bass2;
    }
    return _output;
}
@end
