//
//  opus_shim.h
//  allonet2
//
//  opus_encoder_ctl/opus_decoder_ctl are C variadics, which Swift cannot call. These are the
//  handful of settings the voice path actually uses, as ordinary functions.
//

#ifndef ALLO_OPUS_SHIM_H
#define ALLO_OPUS_SHIM_H

#include <stdint.h>
#include "opus.h"

int allo_opus_encoder_set_bitrate(OpusEncoder *encoder, int32_t bitrate);
int allo_opus_encoder_set_inband_fec(OpusEncoder *encoder, int32_t enabled);
int allo_opus_encoder_set_packet_loss(OpusEncoder *encoder, int32_t percent);
int allo_opus_encoder_set_dtx(OpusEncoder *encoder, int32_t enabled);
int allo_opus_encoder_set_vbr(OpusEncoder *encoder, int32_t enabled);
int allo_opus_encoder_set_complexity(OpusEncoder *encoder, int32_t complexity);
int allo_opus_encoder_set_signal_voice(OpusEncoder *encoder);

int allo_opus_decoder_get_last_packet_duration(OpusDecoder *decoder, int32_t *samples);

#endif
