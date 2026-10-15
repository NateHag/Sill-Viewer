"""Sill's wire format (Sources/StreamProtocol/StreamMessage.swift).

Every message: a 14-byte big-endian header, kind(1) timestamp(8, f64) isKeyframe(1) length(4),
then the payload. JSON payloads follow Swift's JSONEncoder: a nil field is left out.
"""
import json
import struct
import time

HEADER = struct.Struct(">BdBI")
HEADER_LEN = HEADER.size  # 14

# Host -> device
PARAMETER_SETS = 0
FRAME = 1
WINDOW_LIST = 2
THUMBNAIL = 3
APP_ICON = 4
APP_LIST = 5
# Device -> host
SELECT_SOURCE = 6
LAUNCH_APP = 7
INPUT = 8
VIEWPORT = 9
PING = 10
PONG = 11
CLIENT_STATS = 12
TICK = 13
CURSOR_SHAPE = 14
WINDOW_COMMAND = 15
HOST_SETTINGS = 16
CHANGE_SETTINGS = 17
MAC_INFO = 18
PAIR_REQUEST = 19
PAIR_RESULT = 20
PAIRING_WANTED = 21
GOODBYE = 22
HELLO = 23
MAC_MENU = 24
PRESS_MENU_ITEM = 25
MAC_POINTER = 26
FETCH_MENU = 27
GESTURE = 28
# Not Sill's: sill-linux and Sill Viewer only. JSON {"text": "..."} both ways: the clipboard
# changed on this side. Sill's own apps skip kinds they do not know.
CLIPBOARD = 200
MAX_CLIPBOARD_TEXT = 900_000
# Not Sill's either: files both ways. FILE_START JSON {"id", "name" (relative path, "/"), "size"};
# FILE_DATA: 4-byte big-endian id, then bytes; FILE_END JSON {"id"}; FILE_CANCEL JSON {"id"};
# FILE_REQUEST (viewer to host) JSON {}: "send me the files copied on your side";
# FILE_STATUS JSON {"text"}: a short note for the person, such as "Saved 3 files to Downloads".
FILE_START = 201
FILE_DATA = 202
FILE_END = 203
FILE_REQUEST = 204
FILE_STATUS = 205
FILE_CANCEL = 206
FILE_CHUNK = 128 * 1024

MAX_CLIENT_PAYLOAD = 1 << 20
MAX_PAIRING_PAYLOAD = 4096

PROTOCOL = 1
SESSION_ALPN = b"sill/1"
PAIRING_ALPN = b"sill-pair/1"


def pack(kind, payload=b"", key=False, ts=None):
    if ts is None:
        ts = time.time()
    return HEADER.pack(kind, ts, 1 if key else 0, len(payload)) + payload


def jbytes(obj):
    """JSON as Swift writes it: no nulls (callers leave them out), compact."""
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()


def jmsg(kind, obj):
    return pack(kind, jbytes(obj))


def parameter_sets_payload(sets, nal_len=4):
    out = bytearray([nal_len, len(sets)])
    for s in sets:
        out += struct.pack(">H", len(s))
        out += s
    return bytes(out)


class Reader:
    """Incremental message parser. feed() bytes, iterate messages() for (kind, ts, key, payload)."""

    def __init__(self, max_payload):
        self.buf = bytearray()
        self.max_payload = max_payload

    def feed(self, data):
        self.buf += data

    def messages(self):
        while True:
            if len(self.buf) < HEADER_LEN:
                return
            kind, ts, key, ln = HEADER.unpack_from(self.buf, 0)
            if ln > self.max_payload:
                raise ValueError(f"payload of {ln} bytes announced (kind {kind})")
            if len(self.buf) < HEADER_LEN + ln:
                return
            payload = bytes(self.buf[HEADER_LEN:HEADER_LEN + ln])
            del self.buf[:HEADER_LEN + ln]
            yield kind, ts, key == 1, payload
