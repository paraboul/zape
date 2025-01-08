/*
   Copyright 2016 Nidium Inc. All rights reserved.
   Use of this source code is governed by a MIT license
   that can be found in the LICENSE file.
*/

#ifndef __APE_WEBSOCKET_H
#define __APE_WEBSOCKET_H

#include "ape_common.h"
#include "ape_socket.h"

typedef enum {
    WS_STEP_KEY,
    WS_STEP_START,
    WS_STEP_LENGTH,
    WS_STEP_SHORT_LENGTH,
    WS_STEP_EXTENDED_LENGTH,
    WS_STEP_DATA,
    WS_STEP_END
} ws_payload_step;

typedef enum {
    WS_FRAME_START,
    WS_FRAME_CONTINUE,
    WS_FRAME_FINISH
} ws_frame_state;

typedef void (*ape_ws_on_frame_t)(struct _websocket_state *state, const unsigned char *data,
                           ssize_t len, int binary, ws_frame_state framestate);

typedef struct _websocket_state {
    ape_socket *socket;

    unsigned char *data;
    ape_ws_on_frame_t on_frame;

    unsigned short int error;
    // ws_version version;

    struct {
        /* cypher key */
        unsigned char val[4];
        int pos;
    } key;

#pragma pack(2)
    struct {
        unsigned char start;
        union {
            unsigned short short_length;            /* 16 bit length */
            unsigned long long int extended_length; /* 64 bit length */
        };
    } frame_payload;
#pragma pack()

    ws_payload_step step;

    int data_inkey;
    int frame_pos;
    int mask;
    int close_sent : 4;
    int is_client : 4;
    unsigned char prevstate;
} websocket_state;

#ifdef __cplusplus
extern "C" {
#endif

websocket_state *ape_ws_create(int isclient, ape_socket *socket, ape_ws_on_frame_t on_frame_cb);

ape_socket *ape_ws_get_socket(websocket_state *state);

void ape_ws_free(websocket_state *state);

void ape_ws_init(websocket_state *state, int isclient);
void ape_ws_process_frame(websocket_state *websocket, const char *buf,
                          size_t len);
char *ape_ws_compute_key(const char *key, unsigned int key_len);
void ape_ws_compute_sha1_key(const char *key, unsigned int key_len, unsigned char *digest);
void ape_ws_write(websocket_state *state, unsigned char *data, size_t len,
                  int binary, ape_socket_data_autorelease data_type);

void ape_ws_close(websocket_state *state);
void ape_ws_ping(websocket_state *state);

#ifdef __cplusplus
}
#endif

#define WEBSOCKET_HARDCODED_HEADERS                                            \
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: "   \
    "Upgrade\r\n"

#endif
