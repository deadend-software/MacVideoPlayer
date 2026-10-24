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
        _delaySize = (size_t)ceil(_sampleRate * 0.04) + 1;
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
    if (fillAuthored) {
        for (int c = 0; c < _output->ch_layout.nb_channels; c++)
            memcpy(_output->data[c], _stereo->data[c], count * sizeof(float));
        // A low-level front bed keeps surrounds audible even during center-only dialogue.
        // Convex mixing reserves headroom and keeps existing surround content dominant.
        for (int i = 0; i < count; i++) {
            float l = ((float *)_output->data[0])[i], r = ((float *)_output->data[1])[i];
            float c = ((float *)_output->data[2])[i];
            _delayLeft[_delayIndex] = 0.6f * l + 0.25f * r + 0.15f * c;
            _delayRight[_delayIndex] = 0.6f * r + 0.25f * l + 0.15f * c;
            for (int channel = 4; channel < _output->ch_layout.nb_channels; channel++) {
                double seconds = channel < 6 ? 0.023 : 0.011;
                if (channel % 2) seconds += 0.004;
                size_t tap = (_delayIndex + _delaySize - (size_t)(_sampleRate * seconds)) % _delaySize;
                float bed = channel % 2 ? _delayRight[tap] : _delayLeft[tap];
                float *out = (float *)_output->data[channel];
                out[i] = 0.78f * out[i] + 0.22f * bed;
            }
            _delayIndex = (_delayIndex + 1) % _delaySize;
        }
        return _output;
    }
    if (expandSurround) {
        // Retain fronts, dialogue and bass. A 5.x surround pair becomes the sides;
        // delayed, attenuated copies provide the additional back field in 7.1.
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
        size_t delay = (size_t)(_sampleRate * 0.023);
        for (int i = 0; i < count; i++) {
            _delayLeft[_delayIndex] = ((float *)_output->data[6])[i];
            _delayRight[_delayIndex] = ((float *)_output->data[7])[i];
            size_t back = (_delayIndex + _delaySize - delay) % _delaySize;
            ((float *)_output->data[4])[i] = 0.6f * _delayLeft[back];
            ((float *)_output->data[5])[i] = 0.6f * _delayRight[back];
            _delayIndex = (_delayIndex + 1) % _delaySize;
        }
        return _output;
    }
    float *left = (float *)_stereo->data[0], *right = (float *)_stereo->data[1];
    float *frontLeft = (float *)_output->data[0], *frontRight = (float *)_output->data[1];
    float *center = (float *)_output->data[2], *lfe = (float *)_output->data[3];
    float *rearLeft = (float *)_output->data[4], *rearRight = (float *)_output->data[5];
    // Keep the front image dominant. Smooth stereo correlation rather than rectifying
    // individual samples, which adds harmonics to center content. Uncorrelated and
    // hard-panned material stays out of center; a quiet common bed fills mono surrounds.
    float frontGain = 0.85f;
    vDSP_vsmul(left, 1, &frontGain, frontLeft, 1, count);
    vDSP_vsmul(right, 1, &frontGain, frontRight, 1, count);
    vDSP_vsub(right, 1, left, 1, rearLeft, 1, count);
    float steeringCoefficient = 1.0f - expf(-1.0f / (0.020f * _sampleRate));
    // Split ambience energy across two pairs in 7.1 instead of making it louder.
    float surroundGain = seven ? 0.70710678f : 1.0f;
    float bassCoefficient = 1.0f - expf(-2.0f * (float)M_PI * 120.0f / _sampleRate);
    size_t sideDelay = (size_t)(_sampleRate * 0.011);
    size_t rearDelay = (size_t)(_sampleRate * 0.023);
    for (int i = 0; i < count; i++) {
        _leftPower += steeringCoefficient * (left[i] * left[i] - _leftPower);
        _rightPower += steeringCoefficient * (right[i] * right[i] - _rightPower);
        _crossPower += steeringCoefficient * (left[i] * right[i] - _crossPower);
        float power = _leftPower + _rightPower;
        float coherence = power > 1e-12f ? fminf(1.0f, fmaxf(0.0f, 2.0f * _crossPower / power)) : 0;
        float common = coherence * 0.5f * (left[i] + right[i]);
        center[i] = 0.55f * common;
        frontLeft[i] -= 0.15f * common;
        frontRight[i] -= 0.15f * common;
        float difference = 0.5f * rearLeft[i];
        // This is synthesized ambience, not recovered discrete source information.
        // The common bed is about 20 dB below the fronts for a mono source.
        float bedGain = self.surroundFill ? 0.35f : 0.12f;
        _delayLeft[_delayIndex] = difference + bedGain * common;
        _delayRight[_delayIndex] = -difference + bedGain * common;
        size_t back = (_delayIndex + _delaySize - rearDelay) % _delaySize;
        size_t side = (_delayIndex + _delaySize - sideDelay) % _delaySize;
        rearLeft[i] = surroundGain * 0.55f * _delayLeft[back];
        rearRight[i] = surroundGain * 0.55f * _delayRight[(back + _delaySize - (size_t)(_sampleRate * 0.004)) % _delaySize];
        if (seven) {
            ((float *)_output->data[6])[i] = surroundGain * 0.55f * _delayLeft[side];
            ((float *)_output->data[7])[i] = surroundGain * 0.55f * _delayRight[(side + _delaySize - (size_t)(_sampleRate * 0.003)) % _delaySize];
        }
        _delayIndex = (_delayIndex + 1) % _delaySize;
        float sum = 0.5f * (left[i] + right[i]);
        _bass1 += bassCoefficient * (sum - _bass1);
        _bass2 += bassCoefficient * (_bass1 - _bass2);
        lfe[i] = 0.5f * _bass2;
    }
    return _output;
}
@end
