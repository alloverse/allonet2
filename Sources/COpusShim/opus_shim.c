#include "include/opus_shim.h"

int allo_opus_encoder_set_bitrate(OpusEncoder *encoder, int32_t bitrate) {
    return opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}

int allo_opus_encoder_set_inband_fec(OpusEncoder *encoder, int32_t enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(enabled));
}

int allo_opus_encoder_set_packet_loss(OpusEncoder *encoder, int32_t percent) {
    return opus_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(percent));
}

int allo_opus_encoder_set_dtx(OpusEncoder *encoder, int32_t enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_DTX(enabled));
}

int allo_opus_encoder_set_vbr(OpusEncoder *encoder, int32_t enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_VBR(enabled));
}

int allo_opus_encoder_set_complexity(OpusEncoder *encoder, int32_t complexity) {
    return opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(complexity));
}

int allo_opus_encoder_set_signal_voice(OpusEncoder *encoder) {
    return opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}

int allo_opus_decoder_get_last_packet_duration(OpusDecoder *decoder, int32_t *samples) {
    return opus_decoder_ctl(decoder, OPUS_GET_LAST_PACKET_DURATION(samples));
}
