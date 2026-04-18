"""
ecg_monitor.py

AUTHOR:      Marvin Christian
TITLE:       Phase 1 real-time ECG + IMU monitor with per-condition recording
DATE:        11/04/2026
"""

from __future__ import annotations
import sys, time, threading, math
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

import numpy as np
import pyqtgraph as pg
from pyqtgraph.Qt import QtCore, QtGui, QtWidgets
import serial

# ─────────────────────────────────────────────────────────────────────────────
# SETTINGS
# ─────────────────────────────────────────────────────────────────────────────
PORT           = "COM13"
BAUD           = 500000
WINDOW_S       = 10.0
REFRESH_MS     = 40
# Recordings folder is always created next to this script file,
# regardless of where Python is launched from.
RECORDINGS_DIR = str(Path(__file__).parent / "Recordings")
MAX_TERM_ROWS  = 500

VREF_MV     = 1800.0
ADC_SPAN    = 4096.0
LSB_PER_G   = 16384.0
LSB_PER_DPS = 131.0

CONDITIONS = ["resting","walking","arm_movement","vibration","custom"]
IMU_SITE_NAMES = ["Left Arm (IMU0)","Right Arm (IMU1)","Right Leg (IMU2)"]

# ── Colour palette (charcoal, not pure black) ──────────────────────────────
BG          = "#2b2b2b"   # main background
BG_PANEL    = "#323232"   # slightly lighter panels
BG_DARK     = "#1e1e1e"   # terminal / info boxes
FG          = "#e8e8e8"   # primary text
FG_DIM      = "#aaaaaa"   # secondary text
BORDER      = "#4a4a4a"   # borders
ACCENT_BLUE = "#4a9eda"   # highlights
REC_GREEN   = "#2d7a2d"
REC_RED     = "#7a1f1f"

# ─────────────────────────────────────────────────────────────────────────────
def fix_sign(v: int) -> int:
    return v - 4_294_967_296 if v > 2_147_483_647 else v

# ─────────────────────────────────────────────────────────────────────────────
@dataclass
class Sample:
    host_t:   float
    t_us:     int
    ecg_corr: int   = 0
    ecg_mV:   float = 0.0
    has_imu:  bool  = False
    mode:     str   = "?"
    ax: list[int]   = field(default_factory=lambda: [0,0,0])
    ay: list[int]   = field(default_factory=lambda: [0,0,0])
    az: list[int]   = field(default_factory=lambda: [0,0,0])
    gx: list[int]   = field(default_factory=lambda: [0,0,0])
    gy: list[int]   = field(default_factory=lambda: [0,0,0])
    gz: list[int]   = field(default_factory=lambda: [0,0,0])
    mag: list[float] = field(default_factory=lambda: [0.0,0.0,0.0])

# ─────────────────────────────────────────────────────────────────────────────
class Logger:
    def __init__(self, recordings_dir: str) -> None:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.dir = Path(recordings_dir)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.session_path = self.dir / f"session_raw_{ts}.txt"
        self._session_f   = self.session_path.open("w", encoding="utf-8", buffering=1)
        self._cond_f    = None
        self._cond_path = None
        self._recording = False
        self._lock      = threading.Lock()
        self._csv_header = None

    def write_session(self, line: str) -> None:
        with self._lock:
            self._session_f.write(line + "\n")

    def start_recording(self, condition: str) -> Path:
        ts   = datetime.now().strftime("%Y%m%d_%H%M%S")
        path = self.dir / f"{condition}_{ts}.txt"
        with self._lock:
            if self._cond_f:
                self._cond_f.close()
            self._cond_f    = path.open("w", encoding="utf-8", buffering=1)
            self._cond_path = path
            self._recording = True
            if self._csv_header:
                self._cond_f.write(self._csv_header + "\n")
        return path

    def stop_recording(self) -> Optional[Path]:
        with self._lock:
            if self._cond_f:
                self._cond_f.close()
                self._cond_f = None
            p = self._cond_path
            self._cond_path = None
            self._recording = False
        return p

    @property
    def is_recording(self) -> bool:
        with self._lock:
            return self._recording

    @property
    def condition_path(self) -> Optional[Path]:
        with self._lock:
            return self._cond_path

    def write_line(self, line: str) -> None:
        with self._lock:
            self._session_f.write(line + "\n")
            if self._recording and self._cond_f:
                self._cond_f.write(line + "\n")

    def set_csv_header(self, header: str) -> None:
        with self._lock:
            self._csv_header = header
            self._session_f.write(header + "\n")
            if self._cond_f:
                self._cond_f.write(header + "\n")

    def close(self) -> None:
        with self._lock:
            if self._cond_f:
                self._cond_f.close()
            self._session_f.close()

# ─────────────────────────────────────────────────────────────────────────────
class SerialReader(threading.Thread):
    _HDR_ECG_ONLY = "t_us,ecg_corr"
    _HDR_ECG_IMU  = ("t_us,ecg_corr,"
                      "ax0,ay0,az0,gx0,gy0,gz0,"
                      "ax1,ay1,az1,gx1,gy1,gz1,"
                      "ax2,ay2,az2,gx2,gy2,gz2")

    def __init__(self, logger: Logger) -> None:
        super().__init__(daemon=True)
        self.logger = logger
        self._lock  = threading.Lock()
        self._samples: deque[Sample] = deque()
        self._terminal: deque[str]   = deque(maxlen=MAX_TERM_ROWS)
        self._term_ver = 0
        self._error: Optional[str] = None
        self.ok_count  = 0
        self.bad_count = 0
        self.mode_name = "waiting..."
        self.n_fields: Optional[int] = None
        self.csv_header: Optional[str] = None
        self._last_t_us: Optional[int] = None
        self._wrap_offset = 0
        self._stop = threading.Event()
        self._buf  = bytearray()

    def stop(self) -> None: self._stop.set()

    def get_window(self, cutoff: float) -> list[Sample]:
        with self._lock:
            return [s for s in self._samples if s.host_t >= cutoff]

    def get_terminal(self) -> tuple[int, str]:
        with self._lock:
            return self._term_ver, "\n".join(self._terminal)

    @property
    def error_message(self) -> Optional[str]:
        with self._lock:
            return self._error

    def _push_terminal(self, line: str) -> None:
        with self._lock:
            self._terminal.append(line)
            self._term_ver += 1

    def _expand_t_us(self, t32: int) -> int:
        if self._last_t_us is not None and t32 < self._last_t_us:
            self._wrap_offset += 4_294_967_296
        self._last_t_us = t32
        return self._wrap_offset + t32

    def _parse(self, line: str) -> Optional[Sample]:
        parts = line.split(",")
        if len(parts) not in (2, 20):
            return None
        try:
            raw = [int(p.strip()) for p in parts]
        except ValueError:
            return None
        t_us = self._expand_t_us(raw[0])
        vals = [raw[0]] + [fix_sign(v) for v in raw[1:]]
        s = Sample(host_t=time.monotonic(), t_us=t_us)
        if len(vals) == 2:
            s.ecg_corr = vals[1]
            s.ecg_mV   = s.ecg_corr * (VREF_MV / ADC_SPAN)
            s.mode     = "ECG_ONLY"
            return s
        s.ecg_corr = vals[1]
        s.ecg_mV   = s.ecg_corr * (VREF_MV / ADC_SPAN)
        s.mode     = "ECG_IMU"
        s.has_imu  = True
        for site in range(3):
            b = 2 + site * 6
            s.ax[site] = vals[b];   s.ay[site] = vals[b+1]; s.az[site] = vals[b+2]
            s.gx[site] = vals[b+3]; s.gy[site] = vals[b+4]; s.gz[site] = vals[b+5]
            s.mag[site] = math.sqrt(s.ax[site]**2 + s.ay[site]**2 + s.az[site]**2)
        return s

    def run(self) -> None:
        try:
            ser = serial.Serial(PORT, BAUD, timeout=0.0)
        except serial.SerialException as e:
            msg = f"[ERROR] Cannot open {PORT}: {e}"
            with self._lock:
                self._error = msg
            self._push_terminal(msg)
            return
        ser.reset_input_buffer()
        self._push_terminal(f"[GUI] {PORT} @ {BAUD} — connected")
        self._push_terminal(f"[GUI] Session backup: {self.logger.session_path}")
        self._push_terminal(f"[GUI] Recordings folder: {self.logger.dir}")
        self._push_terminal("[GUI] Select condition and press Start Recording.")
        try:
            while not self._stop.is_set():
                waiting = ser.in_waiting
                if not waiting:
                    time.sleep(0.001)
                    continue
                self._buf += ser.read(waiting)
                while True:
                    nl = self._buf.find(b"\n")
                    if nl < 0:
                        break
                    raw = self._buf[:nl+1]
                    del self._buf[:nl+1]
                    line = raw.decode("utf-8", errors="ignore").strip()
                    if not line:
                        continue
                    if line.startswith("t_us,"):
                        self.csv_header = line
                        self.logger.set_csv_header(line)
                        self.mode_name = ("ECG_ONLY" if line == self._HDR_ECG_ONLY
                                          else "ECG_IMU" if line == self._HDR_ECG_IMU
                                          else "UNKNOWN")
                        self._push_terminal(line)
                        continue
                    sample = self._parse(line)
                    if sample is not None:
                        self.mode_name = sample.mode
                        self.n_fields  = len(line.split(","))
                        self.logger.write_line(line)
                        with self._lock:
                            self._samples.append(sample)
                            self.ok_count += 1
                            cutoff = time.monotonic() - WINDOW_S * 2
                            while self._samples and self._samples[0].host_t < cutoff:
                                self._samples.popleft()
                        continue
                    self._push_terminal(line)
                    self.logger.write_session(line)
                    self.bad_count += 1
        finally:
            ser.close()

# ─────────────────────────────────────────────────────────────────────────────
class RecordingControls(QtWidgets.QWidget):
    def __init__(self, reader: SerialReader, logger: Logger, parent=None):
        super().__init__(parent)
        self.reader = reader
        self.logger = logger
        layout = QtWidgets.QHBoxLayout(self)
        layout.setContentsMargins(12, 6, 12, 6)
        layout.setSpacing(12)

        lbl = QtWidgets.QLabel("Condition:")
        lbl.setStyleSheet(f"color:{FG}; font-weight:bold; font-size:10pt;")
        layout.addWidget(lbl)

        self.combo = QtWidgets.QComboBox()
        self.combo.addItems(CONDITIONS)
        self.combo.setEditable(True)
        self.combo.setFixedWidth(180)
        self.combo.setStyleSheet(f"""
            QComboBox {{
                background:{BG_PANEL}; color:{FG};
                border:1px solid {BORDER}; border-radius:3px;
                padding:4px 8px; font-size:10pt;
            }}
            QComboBox QAbstractItemView {{
                background:{BG_PANEL}; color:{FG};
                selection-background-color:{ACCENT_BLUE};
            }}
        """)
        layout.addWidget(self.combo)

        self.btn = QtWidgets.QPushButton("⏺  Start Recording")
        self.btn.setFixedSize(210, 34)
        self._style_btn_idle()
        self.btn.clicked.connect(self._toggle)
        layout.addWidget(self.btn)

        self.status = QtWidgets.QLabel("● Not recording")
        self.status.setStyleSheet(f"color:{FG_DIM}; font-size:10pt; font-weight:bold;")
        layout.addWidget(self.status)

        self.counter = QtWidgets.QLabel("")
        self.counter.setStyleSheet(f"color:{FG_DIM}; font-size:9pt; font-family:monospace;")
        layout.addWidget(self.counter)

        layout.addStretch()

        self.file_lbl = QtWidgets.QLabel("")
        self.file_lbl.setStyleSheet(f"color:{ACCENT_BLUE}; font-size:8.5pt; font-family:monospace;")
        layout.addWidget(self.file_lbl)

        self._rec_start_ok = 0
        timer = QtCore.QTimer(self)
        timer.timeout.connect(self._tick)
        timer.start(500)

    def _style_btn_idle(self):
        self.btn.setStyleSheet(f"""
            QPushButton {{
                background:{REC_GREEN}; color:{FG};
                font-size:10pt; font-weight:bold;
                border-radius:4px; border:1px solid #3d9b3d;
            }}
            QPushButton:hover {{ background:#3d8f3d; }}
        """)

    def _style_btn_recording(self):
        self.btn.setStyleSheet(f"""
            QPushButton {{
                background:{REC_RED}; color:{FG};
                font-size:10pt; font-weight:bold;
                border-radius:4px; border:1px solid #9b2f2f;
            }}
            QPushButton:hover {{ background:#8f2f2f; }}
        """)

    def _toggle(self):
        if not self.logger.is_recording:
            cond = self.combo.currentText().strip().replace(" ", "_") or "unnamed"
            path = self.logger.start_recording(cond)
            self._rec_start_ok = self.reader.ok_count
            self.btn.setText("⏹  Stop Recording")
            self._style_btn_recording()
            self.status.setText(f"● REC  [{cond}]")
            self.status.setStyleSheet("color:#ff6666; font-size:10pt; font-weight:bold;")
            self.file_lbl.setText(path.name)
            self.combo.setEnabled(False)
        else:
            path = self.logger.stop_recording()
            self.btn.setText("⏺  Start Recording")
            self._style_btn_idle()
            self.status.setText("● Not recording")
            self.status.setStyleSheet(f"color:{FG_DIM}; font-size:10pt; font-weight:bold;")
            if path:
                self.file_lbl.setText(f"Saved: {path}")
            self.combo.setEnabled(True)

    def _tick(self):
        if self.logger.is_recording:
            n = self.reader.ok_count - self._rec_start_ok
            self.counter.setText(f"{n:,} samples")
        else:
            self.counter.setText("")

# ─────────────────────────────────────────────────────────────────────────────
def _info_label(text="Waiting..."):
    lbl = QtWidgets.QLabel(text)
    lbl.setStyleSheet(f"""
        color:{FG}; background:{BG_DARK};
        padding:10px; font-family:Consolas,'Courier New',monospace;
        font-size:9pt; border:1px solid {BORDER}; border-radius:3px;
    """)
    lbl.setAlignment(QtCore.Qt.AlignTop | QtCore.Qt.AlignLeft)
    lbl.setWordWrap(True)
    return lbl

# ─────────────────────────────────────────────────────────────────────────────
class ECGTab(QtWidgets.QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QtWidgets.QHBoxLayout(self)
        layout.setContentsMargins(6,6,6,6)

        gw = pg.GraphicsLayoutWidget()
        self.plt = gw.addPlot(title="ECG — DC-corrected")
        self.plt.setLabel("left","mV"); self.plt.setLabel("bottom","Time (s)")
        self.plt.setXRange(0, WINDOW_S, padding=0)
        self.plt.setYRange(-2000, 2000, padding=0)
        self.plt.showGrid(x=True, y=True, alpha=0.2)
        self.plt.addLine(y=0, pen=pg.mkPen(FG_DIM, width=0.5,
                         style=QtCore.Qt.DashLine))
        self.curve = self.plt.plot(pen=pg.mkPen(ACCENT_BLUE, width=1.3))
        layout.addWidget(gw, stretch=4)

        self.lbl = _info_label()
        self.lbl.setFixedWidth(320)
        layout.addWidget(self.lbl)

    def update(self, window, reader, logger, lps):
        if not window:
            return
        now = time.monotonic()
        xs  = np.array([s.host_t - (now-WINDOW_S) for s in window], dtype=np.float32)
        ecg = np.array([s.ecg_mV for s in window], dtype=np.float32)
        self.curve.setData(xs, ecg)

        if len(window) >= 2:
            t_arr = np.array([s.t_us for s in window], dtype=np.float64)
            dt = np.diff(t_arr/1e6); dt = dt[dt>0]
            fs_est = 1.0/np.median(dt) if dt.size else float("nan")
        else:
            fs_est = float("nan")

        last = window[-1]
        rec  = f"REC → {logger.condition_path.name}" if logger.is_recording else "Not recording"
        self.lbl.setText(
            f" Mode      : {reader.mode_name}\n"
            f" Fields    : {reader.n_fields}\n"
            f" Fs est.   : {fs_est:.1f} Hz\n"
            f" Lines/s   : {lps}\n"
            f" OK        : {reader.ok_count}  Bad: {reader.bad_count}\n"
            f"\n"
            f" Last ECG  : {last.ecg_mV:+.2f} mV\n"
            f" Last t_us : {last.t_us}\n"
            f"\n"
            f" {rec}\n"
            f"\n"
            f" Session backup:\n"
            f"  {logger.session_path.name}\n"
            f"\n"
            f" MATLAB:\n"
            f"  d=readmatrix('resting_*.txt')\n"
            f"  t=d(:,1)/1e6\n"
            f"  ecg=d(:,2)*(1800/4096)\n"
        )

# ─────────────────────────────────────────────────────────────────────────────
class IMUTab(QtWidgets.QWidget):
    def __init__(self, site: int, parent=None):
        super().__init__(parent)
        self.site = site
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(6,6,6,6); layout.setSpacing(4)

        gw = pg.GraphicsLayoutWidget()

        self.plt_a = gw.addPlot(row=0, col=0,
            title=f"Accelerometer — {IMU_SITE_NAMES[site]}  (raw LSB, ±2 g)")
        self.plt_a.setLabel("left","LSB")
        self.plt_a.setXRange(0,WINDOW_S,padding=0)
        self.plt_a.setYRange(-32768,32768,padding=0)
        self.plt_a.showGrid(x=True,y=True,alpha=0.2)
        self.plt_a.addLine(y= LSB_PER_G, pen=pg.mkPen(FG_DIM,width=0.6,style=QtCore.Qt.DotLine))
        self.plt_a.addLine(y=-LSB_PER_G, pen=pg.mkPen(FG_DIM,width=0.6,style=QtCore.Qt.DotLine))
        self.plt_a.addLegend(offset=(5,5))
        self.c_ax  = self.plt_a.plot(pen=pg.mkPen("#e05555",width=1.2), name="ax")
        self.c_ay  = self.plt_a.plot(pen=pg.mkPen("#55cc55",width=1.2), name="ay")
        self.c_az  = self.plt_a.plot(pen=pg.mkPen(ACCENT_BLUE,width=1.2), name="az")
        self.c_mag = self.plt_a.plot(pen=pg.mkPen("#ddcc44",width=1.5,
                                     style=QtCore.Qt.DashLine), name="|a|")

        self.plt_g = gw.addPlot(row=1, col=0,
            title=f"Gyroscope — {IMU_SITE_NAMES[site]}  (raw LSB, ±250°/s)")
        self.plt_g.setLabel("left","LSB"); self.plt_g.setLabel("bottom","Time (s)")
        self.plt_g.setXRange(0,WINDOW_S,padding=0)
        self.plt_g.setYRange(-32768,32768,padding=0)
        self.plt_g.showGrid(x=True,y=True,alpha=0.2)
        self.plt_g.addLegend(offset=(5,5))
        self.c_gx = self.plt_g.plot(pen=pg.mkPen("#e05555",width=1.2), name="gx")
        self.c_gy = self.plt_g.plot(pen=pg.mkPen("#55cc55",width=1.2), name="gy")
        self.c_gz = self.plt_g.plot(pen=pg.mkPen(ACCENT_BLUE,width=1.2), name="gz")

        layout.addWidget(gw)

        self.lbl = QtWidgets.QLabel("Waiting for IMU data...")
        self.lbl.setStyleSheet(f"color:{FG}; background:{BG_DARK}; padding:5px;"
                                "font-family:monospace; font-size:9pt;")
        self.lbl.setFixedHeight(55)
        layout.addWidget(self.lbl)

    def update(self, window):
        imu = [s for s in window if s.has_imu]
        if not imu:
            self.lbl.setText(f"{IMU_SITE_NAMES[self.site]} — no IMU data.")
            return
        now = time.monotonic()
        xs  = np.array([s.host_t-(now-WINDOW_S) for s in imu], dtype=np.float32)
        i   = self.site
        ax  = np.array([s.ax[i]  for s in imu], dtype=np.float32)
        ay  = np.array([s.ay[i]  for s in imu], dtype=np.float32)
        az  = np.array([s.az[i]  for s in imu], dtype=np.float32)
        gx  = np.array([s.gx[i]  for s in imu], dtype=np.float32)
        gy  = np.array([s.gy[i]  for s in imu], dtype=np.float32)
        gz  = np.array([s.gz[i]  for s in imu], dtype=np.float32)
        mag = np.array([s.mag[i] for s in imu], dtype=np.float32)

        self.c_ax.setData(xs,ax); self.c_ay.setData(xs,ay)
        self.c_az.setData(xs,az); self.c_mag.setData(xs,mag)
        self.c_gx.setData(xs,gx); self.c_gy.setData(xs,gy)
        self.c_gz.setData(xs,gz)

        last   = imu[-1]
        mean_g = float(np.mean(mag)) / LSB_PER_G
        ok_str = "OK" if 0.8 < mean_g < 1.2 else "CHECK MOUNTING"
        self.lbl.setText(
            f"  ax={last.ax[i]:+7d}  ay={last.ay[i]:+7d}  az={last.az[i]:+7d}  "
            f"gx={last.gx[i]:+7d}  gy={last.gy[i]:+7d}  gz={last.gz[i]:+7d}   "
            f"|a| mean = {mean_g:.3f} g  {ok_str}"
        )

# ─────────────────────────────────────────────────────────────────────────────
class CompareTab(QtWidgets.QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(6,6,6,6)

        gw = pg.GraphicsLayoutWidget()
        self.plt = gw.addPlot(title="|a| magnitude — all 3 sites  (dashed = 1 g = 16384 LSB)")
        self.plt.setLabel("left","LSB"); self.plt.setLabel("bottom","Time (s)")
        self.plt.setXRange(0,WINDOW_S,padding=0); self.plt.setYRange(0,32768,padding=0)
        self.plt.showGrid(x=True,y=True,alpha=0.2)
        self.plt.addLine(y=LSB_PER_G, pen=pg.mkPen(FG_DIM,width=1.0,style=QtCore.Qt.DashLine))
        self.plt.addLegend(offset=(10,10))

        self.curves = [
            self.plt.plot(pen=pg.mkPen("#e05555",width=1.5), name=IMU_SITE_NAMES[0]),
            self.plt.plot(pen=pg.mkPen("#55cc55",width=1.5), name=IMU_SITE_NAMES[1]),
            self.plt.plot(pen=pg.mkPen(ACCENT_BLUE,width=1.5), name=IMU_SITE_NAMES[2]),
        ]
        layout.addWidget(gw)

    def update(self, window):
        imu = [s for s in window if s.has_imu]
        if not imu:
            return
        now = time.monotonic()
        xs  = np.array([s.host_t-(now-WINDOW_S) for s in imu], dtype=np.float32)
        for i, curve in enumerate(self.curves):
            mag = np.array([s.mag[i] for s in imu], dtype=np.float32)
            curve.setData(xs, mag)

# ─────────────────────────────────────────────────────────────────────────────
class TerminalPane(QtWidgets.QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(6,4,6,6)

        hdr = QtWidgets.QLabel("Firmware terminal")
        hdr.setStyleSheet(f"color:{FG}; font-size:10pt; font-weight:bold; padding:2px;")
        layout.addWidget(hdr)

        self.text = QtWidgets.QPlainTextEdit()
        self.text.setReadOnly(True)
        self.text.setMaximumBlockCount(MAX_TERM_ROWS)
        self.text.setStyleSheet(f"""
            QPlainTextEdit {{
                background:{BG_DARK}; color:{FG};
                border:1px solid {BORDER};
                font-family:Consolas,'Courier New',monospace; font-size:9pt;
            }}
        """)
        layout.addWidget(self.text)
        self._last_ver = -1

    def refresh(self, reader):
        ver, text = reader.get_terminal()
        if ver != self._last_ver:
            self.text.setPlainText(text)
            self.text.moveCursor(QtGui.QTextCursor.End)
            self._last_ver = ver

# ─────────────────────────────────────────────────────────────────────────────
class MainWindow(QtWidgets.QMainWindow):
    def __init__(self, reader: SerialReader, logger: Logger) -> None:
        super().__init__()
        self.reader = reader
        self.logger = logger
        self._last_ok = 0
        self._last_t  = time.monotonic()
        self._lps     = 0

        self.setWindowTitle(f"Phase 1 Monitor — {PORT} @ {BAUD}")
        self.resize(1440, 920)
        self.setStyleSheet(f"QMainWindow {{ background:{BG}; }}")

        pg.setConfigOption("background", BG_PANEL)
        pg.setConfigOption("foreground", FG)

        central = QtWidgets.QWidget()
        central.setStyleSheet(f"background:{BG};")
        self.setCentralWidget(central)
        outer = QtWidgets.QVBoxLayout(central)
        outer.setContentsMargins(0,0,0,0)
        outer.setSpacing(0)

        self.rec_controls = RecordingControls(reader, logger)
        self.rec_controls.setStyleSheet(
            f"background:{BG_PANEL}; border-bottom:2px solid {BORDER};")
        self.rec_controls.setFixedHeight(50)
        outer.addWidget(self.rec_controls)

        splitter = QtWidgets.QSplitter(QtCore.Qt.Vertical)
        splitter.setStyleSheet(f"background:{BG};")
        outer.addWidget(splitter, stretch=1)

        self.tabs = QtWidgets.QTabWidget()
        self.tabs.setStyleSheet(f"""
            QTabWidget::pane {{ border:1px solid {BORDER}; background:{BG_PANEL}; }}
            QTabBar::tab {{
                background:{BG}; color:{FG_DIM};
                padding:7px 16px; border:1px solid {BORDER};
                border-bottom:none; margin-right:2px; border-radius:3px 3px 0 0;
            }}
            QTabBar::tab:selected {{ background:{BG_PANEL}; color:{FG}; font-weight:bold; }}
            QTabBar::tab:hover {{ background:{BG_PANEL}; color:{FG}; }}
        """)
        splitter.addWidget(self.tabs)

        self.ecg_tab     = ECGTab()
        self.imu_tabs    = [IMUTab(i) for i in range(3)]
        self.compare_tab = CompareTab()

        self.tabs.addTab(self.ecg_tab, "ECG")
        for i, t in enumerate(self.imu_tabs):
            self.tabs.addTab(t, f"IMU {i}  ({'LA RA RL'.split()[i]})")
        self.tabs.addTab(self.compare_tab, "IMU Compare")

        self.terminal = TerminalPane()
        splitter.addWidget(self.terminal)
        splitter.setSizes([680, 200])

        self._timer = QtCore.QTimer()
        self._timer.timeout.connect(self._refresh)
        self._timer.start(REFRESH_MS)

    def _refresh(self):
        now = time.monotonic()
        if now - self._last_t >= 1.0:
            self._lps    = self.reader.ok_count - self._last_ok
            self._last_ok = self.reader.ok_count
            self._last_t  = now

        window = self.reader.get_window(now - WINDOW_S)
        self.ecg_tab.update(window, self.reader, self.logger, self._lps)
        for t in self.imu_tabs:
            t.update(window)
        self.compare_tab.update(window)
        self.terminal.refresh(self.reader)

    def closeEvent(self, event):
        self._timer.stop()
        self.reader.stop()
        self.reader.join(timeout=2.0)
        self.logger.close()
        print(f"\nRecordings folder: {self.logger.dir}")
        print(f"Session backup:    {self.logger.session_path}")
        event.accept()

# ─────────────────────────────────────────────────────────────────────────────
def main():
    logger = Logger(RECORDINGS_DIR)
    reader = SerialReader(logger)
    reader.start()
    app    = QtWidgets.QApplication(sys.argv)
    window = MainWindow(reader, logger)
    window.show()
    sys.exit(app.exec_())

if __name__ == "__main__":
    main()