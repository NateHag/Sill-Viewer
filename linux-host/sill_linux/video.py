"""Capture -> HEVC encode -> access units, with GStreamer.

The device wants HEVC Main 8-bit 4:2:0 without B-frames, as length-prefixed NAL units (hvcC
style), with VPS/SPS/PPS sent apart (kind 0) before each keyframe. Encoders are tried in order
(NVIDIA, then VA-API, then x265 in software); one that fails before its first frame is skipped.
"""
import logging
import threading
import time

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstVideo", "1.0")
from gi.repository import GLib, Gst, GstVideo  # noqa: E402

log = logging.getLogger("sill.video")

ENCODERS = ["nvcudah265enc", "nvh265enc", "nvautogpuh265enc", "vah265enc", "vaapih265enc", "x265enc"]
# (encoder, fps) pairs that failed: an encoder that cannot do 120 fps may still do 60.
_bad_encoders = set()

NAL_VPS, NAL_SPS, NAL_PPS, NAL_AUD = 32, 33, 34, 35


def init():
    Gst.init(None)


def have(element):
    return Gst.ElementFactory.find(element) is not None


def _prop_text(el, prop, value):
    """`value` as gst-launch text when `el` has `prop` and accepts it, else None."""
    spec = el.find_property(prop)
    if spec is None:
        return None
    vt = spec.value_type
    if vt.is_a(GObjectEnum):
        ok = any(value == v.value_nick or value == v.value_name for v in spec.enum_class.__enum_values__.values())
        return str(value) if ok else None
    if vt == GObjectBool:
        return "true" if value else "false"
    if isinstance(value, (int, float)) and hasattr(spec, "minimum"):
        value = max(spec.minimum, min(spec.maximum, value))
        return str(int(value)) if isinstance(spec.default_value, int) else str(value)
    return str(value)


from gi.repository import GObject  # noqa: E402

GObjectEnum = GObject.TYPE_ENUM
GObjectBool = GObject.TYPE_BOOLEAN


def encoder_description(name, kbps, fps, gop, speed):
    """gst-launch text for encoder `name` tuned for low latency, or None if it is not installed."""
    factory = Gst.ElementFactory.find(name)
    if factory is None:
        return None
    el = factory.create(None)
    if el is None:
        return None
    vbv = max(kbps // max(fps, 1) * 3, 200)       # about three frames: low latency, room for detail
    if name in ("nvcudah265enc", "nvautogpuh265enc"):
        want = [("preset", "p1" if speed else "p4"), ("tune", "ultra-low-latency"), ("rc-mode", "vbr"),
                ("bitrate", kbps), ("max-bitrate", kbps * 2), ("vbv-buffer-size", vbv), ("gop-size", gop),
                ("bframes", 0), ("zero-reorder-delay", True), ("repeat-sequence-header", True), ("aud", False),
                ("rc-lookahead", 0), ("multi-pass", "disabled"), ("spatial-aq", True)]
    elif name == "nvh265enc":
        want = [("preset", "low-latency-hp" if speed else "low-latency-hq"), ("rc-mode", "vbr"),
                ("bitrate", kbps), ("max-bitrate", kbps * 2), ("vbv-buffer-size", vbv), ("gop-size", gop),
                ("bframes", 0), ("zerolatency", True), ("aud", False), ("rc-lookahead", 0), ("spatial-aq", True)]
    elif name == "vah265enc":
        want = [("rate-control", "vbr"), ("bitrate", kbps), ("target-percentage", 66), ("key-int-max", gop),
                ("b-frames", 0), ("ref-frames", 1), ("target-usage", 7 if speed else 4), ("aud", False)]
    elif name == "vaapih265enc":
        want = [("rate-control", "vbr"), ("bitrate", kbps), ("keyframe-period", gop), ("max-bframes", 0),
                ("tune", "low-power" if speed else "none")]
    else:  # x265enc
        want = [("speed-preset", "ultrafast" if speed else "superfast"), ("tune", "zerolatency"),
                ("bitrate", kbps), ("key-int-max", gop),
                ("option-string", f"bframes=0:repeat-headers=1:vbv-maxrate={kbps}:vbv-bufsize={vbv}")]
    parts = [name]
    for prop, value in want:
        text = _prop_text(el, prop, value)
        if text is not None:
            parts.append(f'{prop}="{text}"' if " " in text or ":" in text else f"{prop}={text}")
    return " ".join(parts)


def convert_description(encoder, width, height):
    size = f",width={width},height={height}" if width and height else ""
    if encoder.startswith("nv") and have("cudaupload") and have("cudaconvertscale"):
        return f"cudaupload ! cudaconvertscale ! video/x-raw(memory:CUDAMemory),format=NV12{size}"
    if encoder == "vah265enc" and have("vapostproc"):
        return f"vapostproc ! video/x-raw(memory:VAMemory),format=NV12{size}"
    fmt = "I420" if encoder == "x265enc" else "NV12"
    return f"videoconvert n-threads=4 ! videoscale ! video/x-raw,format={fmt}{size}"


def split_annexb(data):
    """NAL units of an Annex B access unit, start codes and trailing zeros removed."""
    nals = []
    i = data.find(b"\x00\x00\x01")
    while i >= 0:
        start = i + 3
        j = data.find(b"\x00\x00\x01", start)
        end = len(data) if j < 0 else j
        nal = data[start:end].rstrip(b"\x00")
        if nal:
            nals.append(nal)
        i = j
    return nals


class Pipeline:
    """One running capture+encode. on_au(param_sets or None, payload, is_key) is called from a
    GStreamer thread; on_failed(reason) from the main thread."""

    def __init__(self, source_desc, enc_width, enc_height, fps, bitrate, speed, on_au, on_failed, encoder=None,
                 gpu_source=False):
        self.source_desc = source_desc
        # Frames that come as GPU (GL) memory: a failure may be the source's, not the encoder's, so
        # no encoder is marked bad and only the first is tried; the host then falls back to copies.
        self.gpu_source = gpu_source
        self.enc_width, self.enc_height = enc_width, enc_height
        self.fps, self.bitrate, self.speed = fps, bitrate, speed
        self.on_au, self.on_failed = on_au, on_failed
        self.forced_encoder = encoder
        self.pipeline = None
        self.sink = None
        self.encoder = None
        self.frames = 0
        self.captured = 0     # frames out of PipeWire, before the queue that may drop them
        self.started = 0.0
        self.param_sets = None
        self.capture_size = None
        self.last_key_request = 0.0
        self.lock = threading.Lock()
        self.stopped = False

    def candidates(self):
        if self.forced_encoder:
            return [self.forced_encoder]
        found = [e for e in ENCODERS if (e, self.fps) not in _bad_encoders and have(e)]
        return found[:1] if self.gpu_source else found

    def start(self):
        kbps = max(1000, int(self.bitrate * self.fps / 60 / 1000))
        gop = self.fps * 4
        errors = []
        for enc in self.candidates():
            enc_desc = encoder_description(enc, kbps, self.fps, gop, self.speed)
            if enc_desc is None:
                continue
            desc = (f"{self.source_desc} ! capsfilter name=srccaps ! queue max-size-buffers=1 leaky=downstream ! "
                    f"{convert_description(enc, self.enc_width, self.enc_height)} ! {enc_desc} ! "
                    f"h265parse config-interval=-1 ! video/x-h265,stream-format=byte-stream,alignment=au ! "
                    f"appsink name=sink emit-signals=true sync=false max-buffers=8 drop=false")
            try:
                pipeline = Gst.parse_launch(desc)
            except GLib.Error as e:
                errors.append(f"{enc}: {e.message}")
                continue
            self.encoder = enc
            self.pipeline = pipeline
            self.sink = pipeline.get_by_name("sink")
            self.sink.connect("new-sample", self._sample)
            pad = pipeline.get_by_name("srccaps").get_static_pad("src")
            pad.add_probe(Gst.PadProbeType.BUFFER, self._count_captured)
            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message", self._message)
            self.started = time.monotonic()
            log.info("pipeline: %s", desc)
            r = pipeline.set_state(Gst.State.PLAYING)
            if r == Gst.StateChangeReturn.FAILURE:
                errors.append(f"{enc}: could not start")
                self._teardown()
                if not self.gpu_source:
                    _bad_encoders.add((enc, self.fps))
                continue
            log.info("encoding with %s at %d kbps, %d fps", enc, kbps, self.fps)
            return True
        raise RuntimeError("no HEVC encoder works: " + "; ".join(errors or ["none installed"]))

    def _count_captured(self, _pad, _info):
        self.captured += 1
        return Gst.PadProbeReturn.OK

    def _teardown(self):
        if self.pipeline is not None:
            self.pipeline.get_bus().remove_signal_watch()
            self.pipeline.set_state(Gst.State.NULL)
        self.pipeline = None
        self.sink = None

    def stop(self):
        self.stopped = True
        self._teardown()

    def _message(self, _bus, msg):
        if self.stopped:
            return
        if msg.type == Gst.MessageType.ERROR:
            err, dbg = msg.parse_error()
            log.error("GStreamer: %s (%s)", err.message, dbg)
            src = msg.src
            factory = src.get_factory().get_name() if isinstance(src, Gst.Element) and src.get_factory() else ""
            encoder_side = factory in ENCODERS or factory in ("cudaupload", "cudaconvertscale", "vapostproc")
            if self.frames == 0 and self.encoder and not self.forced_encoder and encoder_side and not self.gpu_source:
                if time.monotonic() - self.started < 10:
                    log.warning("encoder %s failed before its first frame; trying the next one", self.encoder)
                    _bad_encoders.add((self.encoder, self.fps))
            self._teardown()
            self.on_failed(err.message)
        elif msg.type == Gst.MessageType.EOS:
            self._teardown()
            self.on_failed("end of stream")

    def force_keyframe(self):
        now = time.monotonic()
        with self.lock:
            if now - self.last_key_request < 0.1 or self.sink is None:
                return
            self.last_key_request = now
            sink = self.sink
        ev = GstVideo.video_event_new_upstream_force_key_unit(Gst.CLOCK_TIME_NONE, True, 0)
        sink.send_event(ev)

    def _sample(self, sink):
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.OK
        buf = sample.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.FlowReturn.OK
        try:
            data = bytes(info.data)
        finally:
            buf.unmap(info)
        if self.capture_size is None and self.pipeline is not None:
            caps = self.pipeline.get_by_name("srccaps").get_static_pad("src").get_current_caps()
            if caps:
                s = caps.get_structure(0)
                self.capture_size = (s.get_value("width"), s.get_value("height"))
                log.info("capture size %dx%d", *self.capture_size)
        params, out, key = [], bytearray(), False
        for nal in split_annexb(data):
            t = (nal[0] >> 1) & 0x3F
            if t in (NAL_VPS, NAL_SPS, NAL_PPS):
                params.append((t, nal))
                continue
            if t == NAL_AUD:
                continue
            if 16 <= t <= 21:
                key = True
            out += len(nal).to_bytes(4, "big")
            out += nal
        if params:
            params.sort(key=lambda p: p[0])
            self.param_sets = [n for _, n in params]
        if not out:
            return Gst.FlowReturn.OK
        self.frames += 1
        self.on_au(self.param_sets if key else None, bytes(out), key)
        return Gst.FlowReturn.OK
