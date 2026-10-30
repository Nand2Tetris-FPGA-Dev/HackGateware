"""Serial link frames for the testbenches.

The frame format and its reference code live in hacktools.link, so the PC
tools and the testbenches share one copy.
"""

from hacktools.link import (  # noqa: F401
    STATUS_FIELDS,
    STATUS_LEN,
    cobs_decode,
    cobs_encode,
    crc8,
    decode_frames,
    encode_frame,
    parse_status,
)
