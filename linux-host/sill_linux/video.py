"""Capture -> HEVC encode -> access units, with GStreamer.

The device wants HEVC Main 8-bit 4:2:0 without B-frames, as length-prefixed NAL units (hvcC
style), with VPS/SPS/PPS sent apart (kind 0) before each keyframe. Encoders are tried in order
(NVIDIA, then VA-API, then x265 in software); one that fails before its first frame is skipped.
On NVIDIA, Vulkan video (sill-vkenc, FFmpeg's hevc_vulkan) comes first: NVENC through CUDA holds the
GPU at P2 and full clocks while it encodes, Vulkan lets it idle at P5. Any failure of it falls back
to the encoders above for the rest of the run.
"""
import logging
import os
import struct
import subprocess
import threading
import time

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstVideo", "1.0")
from gi.repository import GLib, Gst, GstVideo  # noqa: E402

log = logging.getLogger("sill.video")

ENCODERS = ["nvcudah265enc", "nvh265enc", "nvautogpuh265enc", "vah265enc", "vaapih265enc", "x265enc"]
# (encoder, fps) -> when it failed: an encoder that cannot do 120 fps may still do 60.
# Only for a while: a failure can come from the source (a monitor that is changing its mode,
# a PipeWire stream that is not ready), not the encoder, and must not block it for good.
_bad_encoders = {}
BAD_FOR = 120.0


def mark_bad(enc, fps):
    _bad_encoders[(enc, fps)] = time.monotonic()


def is_bad(enc, fps):
    t = _bad_encoders.get((enc, fps))
    if t is None:
        return False
    if time.monotonic() - t > BAD_FOR:
        del _bad_encoders[(enc, fps)]
        return False
    return True

NAL_VPS, NAL_SPS, NAL_PPS, NAL_AUD, NAL_FD = 32, 33, 34, 35, 38

VULKAN = "hevc_vulkan"
VKENC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vkenc", "sill-vkenc")
_probe_lock = threading.RLock()
_nvidia = None        # NVIDIA GPU names, the one with the display first
_vk_ok = {}           # GPU name -> whether a test encode through Vulkan worked
_vk_off = {}          # GPU name -> why Vulkan failed while streaming: not used again this run
_gpus = None          # the choices for "Encode on"


def _nvidia_gpus():
    global _nvidia
    with _probe_lock:
        if _nvidia is None:
            try:
                out = subprocess.run(["nvidia-smi", "--query-gpu=name,display_attached", "--format=csv,noheader"],
                                     capture_output=True, text=True, timeout=5).stdout
            except (OSError, subprocess.SubprocessError):
                out = ""
            gpus = [[x.strip() for x in line.split(",")] for line in out.splitlines() if "," in line]
            _nvidia = [n for n, a in gpus if a.lower() == "yes"] + [n for n, a in gpus if a.lower() != "yes"]
        return _nvidia


def vulkan_works(name):
    """Whether sill-vkenc encodes on GPU `name`: a short test encode, once, then remembered."""
    with _probe_lock:
        if name in _vk_off:
            return False
        if name not in _vk_ok:
            ok = False
            if os.access(VKENC, os.X_OK):
                try:
                    r = subprocess.run([VKENC, name, "probe"], capture_output=True, text=True, timeout=15)
                    ok = r.returncode == 0
                    if not ok:
                        last = r.stderr.strip().splitlines()[-1:]
                        log.info("Vulkan HEVC not used on %s: %s", name, last[0] if last else f"exit {r.returncode}")
                except (OSError, subprocess.SubprocessError) as e:
                    log.info("Vulkan HEVC not used on %s: %s", name, e)
            _vk_ok[name] = ok
            if ok:
                log.info("Vulkan HEVC works on %s", name)
        return _vk_ok[name]


def vulkan_device():
    """For Auto: the NVIDIA GPU with the display, when Vulkan encoding works there, else None."""
    gpus = _nvidia_gpus()
    return gpus[0] if gpus and vulkan_works(gpus[0]) else None


def vulkan_failed(name, why):
    if name and name not in _vk_off:
        _vk_off[name] = why
        log.warning("Vulkan HEVC on %s failed (%s); using the other encoders from now on", name, why)


def _is_va(name):
    """A GStreamer VA-API HEVC encoder: vah265enc for the first GPU, varenderD129h265enc and so on."""
    return name.startswith("va") and name.endswith("h265enc") and name != "vaapih265enc"


def encode_gpus():
    """The choices for "Encode on", as [(id, label)]: each NVIDIA GPU where Vulkan encoding works
    ("vulkan:<name>"), and each GPU with a VA-API HEVC encoder, AMD or Intel ("va:<element>")."""
    global _gpus
    with _probe_lock:
        if _gpus is None:
            found = [(f"vulkan:{n}", n) for n in _nvidia_gpus() if vulkan_works(n)]
            for f in sorted(Gst.Registry.get().get_feature_list(Gst.ElementFactory), key=lambda f: f.get_name()):
                name = f.get_name()
                if _is_va(name):
                    # "VA-API H.265 Encoder in AMD Radeon AI PRO R9700" (+ " in renderD129")
                    label = (f.get_metadata("long-name") or name).split(" in ", 1)[-1].split(" in renderD")[0]
                    found.append((f"va:{name}", label))
            _gpus = found
        return _gpus


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
    elif _is_va(name):
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
    postproc = encoder[:-len("h265enc")] + "postproc"     # vah265enc -> vapostproc, on the same GPU
    if _is_va(encoder) and have(postproc):
        return f"{postproc} ! video/x-raw(memory:VAMemory),format=NV12{size}"
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
                 gpu_source=False, gpu="auto"):
        self.source_desc = source_desc
        # Frames that come as GPU (GL) memory: a failure may be the source's, not the encoder's, so
        # no encoder is marked bad and only the first is tried; the host then falls back to copies.
        self.gpu_source = gpu_source
        self.enc_width, self.enc_height = enc_width, enc_height
        self.fps, self.bitrate, self.speed = fps, bitrate, speed
        self.on_au, self.on_failed = on_au, on_failed
        self.forced_encoder = encoder
        self.gpu = gpu                  # "Encode on": "auto", "vulkan:<GPU name>" or "va:<element>"
        self.vk_device = None           # the GPU sill-vkenc encodes on
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
        self.proc = None                # sill-vkenc, when encoding through Vulkan
        self.write_lock = threading.Lock()
        self.last_raw = None
        self.key_pending = False
        self.encoder_fault = False      # this stream failed because of Vulkan, not the screen

    def candidates(self):
        if self.forced_encoder == VULKAN:
            self.vk_device = vulkan_device()
            return [VULKAN] if self.vk_device else []
        if self.forced_encoder:
            return [self.forced_encoder]
        installed = [e for e in ENCODERS if have(e)]
        found = [e for e in installed if not is_bad(e, self.fps)]
        if installed and not found:
            # Every encoder failed lately: the fault is most likely not theirs. Try them all again.
            log.warning("every encoder failed lately; trying them all again")
            for e in installed:
                _bad_encoders.pop((e, self.fps), None)
            found = installed
        auto = found[:1] if self.gpu_source else found
        # The GPU chosen in "Encode on" first; when it does not work, what Auto would pick.
        first = []
        if self.gpu.startswith("vulkan:") and vulkan_works(self.gpu[len("vulkan:"):]):
            self.vk_device = self.gpu[len("vulkan:"):]
        elif self.gpu.startswith("va:") and have(self.gpu[3:]) and not is_bad(self.gpu[3:], self.fps):
            first = [self.gpu[3:]]
        else:
            self.vk_device = vulkan_device()
        if self.vk_device:
            first = [VULKAN]
        return first + [e for e in auto if e not in first]

    def start(self):
        kbps = max(1000, int(self.bitrate * self.fps / 60 / 1000))
        gop = self.fps * 4
        errors = []
        for enc in self.candidates():
            if enc == VULKAN:
                if self._start_vulkan(kbps, gop, errors):
                    return True
                continue
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
                    mark_bad(enc, self.fps)
                continue
            log.info("encoding with %s at %d kbps, %d fps", enc, kbps, self.fps)
            return True
        raise RuntimeError("no HEVC encoder works: " + "; ".join(errors or ["none installed (gst-inspect-1.0 | grep 265enc)"]))

    def _start_vulkan(self, kbps, gop, errors):
        """Frames to NV12 in memory, then through sill-vkenc. GL frames (a virtual screen's DMA-BUFs)
        convert in GL; no CUDA, which alone holds an NVIDIA GPU at P2. Frames already in memory
        convert on the CPU, as for VA-API."""
        size = f",width={self.enc_width},height={self.enc_height}" if self.enc_width and self.enc_height else ""
        if "GLMemory" in self.source_desc and "gldownload" not in self.source_desc:
            convert = (f"glcolorscale ! glcolorconvert ! video/x-raw(memory:GLMemory),format=NV12{size} ! "
                       f"gldownload ! video/x-raw,format=NV12")
        else:
            convert = f"videoconvert n-threads=4 ! videoscale ! video/x-raw,format=NV12{size}"
        desc = (f"{self.source_desc} ! capsfilter name=srccaps ! queue max-size-buffers=1 leaky=downstream ! "
                f"{convert} ! appsink name=sink emit-signals=true sync=false max-buffers=1 drop=true")
        try:
            pipeline = Gst.parse_launch(desc)
        except GLib.Error as e:
            errors.append(f"{VULKAN}: {e.message}")
            vulkan_failed(self.vk_device, e.message)
            return False
        try:
            proc = subprocess.Popen([VKENC, self.vk_device, str(self.fps), str(kbps), str(gop)],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as e:
            errors.append(f"{VULKAN}: {e}")
            vulkan_failed(self.vk_device, str(e))
            return False
        self.encoder = VULKAN
        self.pipeline = pipeline
        self.proc = proc
        self.sink = pipeline.get_by_name("sink")
        self.sink.connect("new-sample", self._raw_sample)
        pad = pipeline.get_by_name("srccaps").get_static_pad("src")
        pad.add_probe(Gst.PadProbeType.BUFFER, self._count_captured)
        bus = pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self._message)
        threading.Thread(target=self._read_aus, args=(proc,), daemon=True).start()
        threading.Thread(target=self._read_errors, args=(proc,), daemon=True).start()
        self.started = time.monotonic()
        log.info("pipeline: %s ! sill-vkenc on %s", desc, self.vk_device)
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            msg = bus.pop_filtered(Gst.MessageType.ERROR)
            why = msg.parse_error()[0].message if msg else "could not start"
            errors.append(f"{VULKAN}: {why}")
            vulkan_failed(self.vk_device, why)
            self._teardown()
            return False
        log.info("encoding with %s (Vulkan, %s) at %d kbps, %d fps", VULKAN, self.vk_device, kbps, self.fps)
        return True

    def _raw_sample(self, sink):
        """An NV12 frame for sill-vkenc. The last one is kept: a keyframe request re-sends it at once,
        so a viewer who joins a still screen gets a picture now, not at the next screen change."""
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.OK
        caps = sample.get_caps()
        info = GstVideo.VideoInfo.new_from_caps(caps) if caps else None
        buf = sample.get_buffer()
        if info is None:
            return Gst.FlowReturn.OK
        ok, m = buf.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.FlowReturn.OK
        try:
            data = bytes(m.data)
        finally:
            buf.unmap(m)
        meta = GstVideo.buffer_get_video_meta(buf)
        if meta is not None:
            strides, offsets = list(meta.stride), list(meta.offset)
        else:
            strides, offsets = list(info.stride), list(info.offset)
        self._note_capture_size()
        if offsets[0]:
            data = data[offsets[0]:]
        frame = (info.width, info.height, strides[0], strides[1], offsets[1] - offsets[0], data)
        with self.lock:
            self.last_raw = frame
            key, self.key_pending = self.key_pending, False
        self._write_frame(frame, key)
        return Gst.FlowReturn.OK

    def _write_frame(self, frame, key):
        proc = self.proc
        if proc is None:
            return
        w, h, sy, suv, ouv, data = frame
        try:
            with self.write_lock:
                proc.stdin.write(struct.pack("7I", 1 if key else 0, w, h, sy, suv, ouv, len(data)))
                proc.stdin.write(data)
                proc.stdin.flush()
        except (BrokenPipeError, ValueError, OSError):
            pass   # the reader sees it exit and reports it

    def _read_aus(self, proc):
        out = proc.stdout
        while True:
            head = out.read(8)
            if len(head) < 8:
                break
            size, _flags = struct.unpack("2I", head)
            data = out.read(size)
            if len(data) < size:
                break
            if not self.stopped:
                self._emit(data)
        code = proc.wait()
        if proc is self.proc and not self.stopped:
            GLib.idle_add(self._vulkan_died, code)

    def _read_errors(self, proc):
        for line in proc.stderr:
            line = line.decode(errors="replace").strip()
            if line and "not a conformant Vulkan implementation" not in line:
                self.vk_error = line
                log.warning("%s", line)

    def _vulkan_died(self, code):
        if self.stopped or self.proc is None:
            return False
        why = getattr(self, "vk_error", None) or f"sill-vkenc exited ({code})"
        vulkan_failed(self.vk_device, why)
        self.encoder_fault = True
        self._teardown()
        self.on_failed(why)
        return False

    def _note_capture_size(self):
        if self.capture_size is None and self.pipeline is not None:
            caps = self.pipeline.get_by_name("srccaps").get_static_pad("src").get_current_caps()
            if caps:
                s = caps.get_structure(0)
                self.capture_size = (s.get_value("width"), s.get_value("height"))
                log.info("capture size %dx%d", *self.capture_size)

    def _count_captured(self, _pad, _info):
        self.captured += 1
        return Gst.PadProbeReturn.OK

    def _teardown(self):
        if self.pipeline is not None:
            self.pipeline.get_bus().remove_signal_watch()
            self.pipeline.set_state(Gst.State.NULL)
        self.pipeline = None
        self.sink = None
        proc, self.proc = self.proc, None
        if proc is not None:
            try:
                proc.stdin.close()
            except OSError:
                pass
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()

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
            if self.encoder == VULKAN and self.frames == 0:
                vulkan_failed(self.vk_device, err.message)
                self.encoder_fault = True
            elif self.frames == 0 and self.encoder and not self.forced_encoder and encoder_side and not self.gpu_source:
                if time.monotonic() - self.started < 10:
                    log.warning("encoder %s failed before its first frame; trying the next one", self.encoder)
                    mark_bad(self.encoder, self.fps)
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
            if self.proc is not None:
                frame = self.last_raw
                self.key_pending = frame is None
        if self.proc is not None:
            if frame is not None:
                self._write_frame(frame, True)
            return
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
        self._note_capture_size()
        self._emit(data)
        return Gst.FlowReturn.OK

    def _emit(self, data):
        """One Annex B access unit to on_au, as length-prefixed NAL units with the parameter sets apart."""
        params, out, key = [], bytearray(), False
        for nal in split_annexb(data):
            t = (nal[0] >> 1) & 0x3F
            if t in (NAL_VPS, NAL_SPS, NAL_PPS):
                params.append((t, nal))
                continue
            if t in (NAL_AUD, NAL_FD):
                continue
            if 16 <= t <= 21:
                key = True
            out += len(nal).to_bytes(4, "big")
            out += nal
        if params:
            params.sort(key=lambda p: p[0])
            self.param_sets = [n for _, n in params]
        if not out:
            return
        self.frames += 1
        self.on_au(self.param_sets if key else None, bytes(out), key)
