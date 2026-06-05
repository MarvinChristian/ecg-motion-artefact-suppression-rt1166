"""
ecg_phase4_monitor_gui.py

Phase 4 ECG monitor for the NXP real-time stream.

This GUI plots the selected Phase4 MAS ECG streams for both ADS1293 channels, shows
the ECG/HRV, selector, and M4 classifier state on the right, and mutes
heart-monitor features whenever the epoch-aligned classifier label marks that
displayed segment as corrupted.
"""

from __future__ import annotations

import argparse
import math
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

import numpy as np
import pyqtgraph as pg
from pyqtgraph.Qt import QtCore, QtGui, QtWidgets
import serial


def _support_recording_dir(folder_name: str) -> Path:
    for parent in Path(__file__).resolve().parents:
        if parent.name == "Support_Tools":
            return parent / "Recordings" / folder_name
    return Path(__file__).resolve().parent / folder_name


DEFAULT_PORT = "COM13"
DEFAULT_BAUD = 500000
WINDOW_S = 10.0
DISPLAY_DELAY_S = 0.5
REFRESH_MS = 40
MAX_TERM_ROWS = 240
RECORDINGS_DIR = str(_support_recording_dir("Phase4_Monitor_Recordings"))
ADS1293_TARGET_FS_HZ = 200.0
RATE_WARN_FRACTION = 0.15
ECG_DISPLAY_HALF_RANGE_MV = 0.50
# Acquired lead is QRS-down (electrode polarity); invert for display only.
# Applied uniformly to raw and selected traces, after the data is logged and
# classified, so firmware, recordings, and trained models are unaffected.
ECG_DISPLAY_SIGN = -1.0
ECG_FEATURE_WINDOW_S = 8.0
HR_DISPLAY_HOLD_S = 5.0

ADS1293_VREF_MV = 2400.0
ADS1293_INA_GAIN = 3.5
ADS1293_ADCMAX = 0xC35000
ADS_SCALE_MV_PER_CODE = (2.0 * ADS1293_VREF_MV / ADS1293_INA_GAIN) / ADS1293_ADCMAX

CPU_HZ_FOR_DISPLAY = 600_000_000.0

# Firmware flag bits mirrored from phase4_realtime.h.
PHASE4_FLAG_CH1_CORRUPT = 1 << 0
PHASE4_FLAG_CH2_CORRUPT = 1 << 1
PHASE4_FLAG_PRIMARY_CORRUPT = 1 << 2
PHASE4_FLAG_MOTION_RISK = 1 << 3
PHASE4_FLAG_MOTION_CORRUPT = 1 << 4
PHASE4_FLAG_LMS_ACTIVE = 1 << 5
PHASE4_FLAG_IMU_TIMING_BAD = 1 << 6
PHASE4_FLAG_ADS_SATURATED = 1 << 7
PHASE4_FLAG_ECG_SPIKE = 1 << 8
PHASE4_FLAG_ECG_FLATLINE = 1 << 9
PHASE4_FLAG_PEAK_UNRELIABLE = 1 << 10
PHASE4_FLAG_SQI_LOW = 1 << 11
PHASE4_CLASSIFIER_CORRUPT_FLAGS = (
    PHASE4_FLAG_CH1_CORRUPT | PHASE4_FLAG_CH2_CORRUPT | PHASE4_FLAG_PRIMARY_CORRUPT
)
PHASE4_EPOCH_LABEL_FLAGS = (
    PHASE4_FLAG_CH1_CORRUPT
    | PHASE4_FLAG_CH2_CORRUPT
    | PHASE4_FLAG_PRIMARY_CORRUPT
)
PHASE4_SAMPLE_CORRUPT_FLAGS = (
    PHASE4_FLAG_ADS_SATURATED
    | PHASE4_FLAG_ECG_SPIKE
    | PHASE4_FLAG_ECG_FLATLINE
)
PHASE4_SAMPLE_WARN_FLAGS = (
    PHASE4_FLAG_MOTION_RISK
    | PHASE4_FLAG_MOTION_CORRUPT
    | PHASE4_FLAG_IMU_TIMING_BAD
    | PHASE4_FLAG_PEAK_UNRELIABLE
    | PHASE4_FLAG_SQI_LOW
)

SELECTOR_NAMES = {
    0: "waiting",
    1: "BPF+N3",
    2: "MAS LL",
    3: "MAS LA",
    4: "MAS RA",
    5: "MAS RA-pair",
    6: "MAS RA+LA",
}
MAS_SELECTOR_IDS = frozenset((2, 3, 4, 5, 6))

# Display palette.
BG = "#242424"
BG_PANEL = "#303030"
BG_DARK = "#181818"
BG_TABLE = "#202020"
FG = "#f0f0f0"
FG_DIM = "#a8a8a8"
BORDER = "#484848"
BLUE = "#4aa3df"
GREEN = "#5ed36a"
RED = "#ef4f4f"
YELLOW = "#e2c94c"


def fix_sign(v: int) -> int:
    return v - 4_294_967_296 if v > 2_147_483_647 else v


def finite_median(y: np.ndarray) -> float:
    finite = np.isfinite(y)
    if not np.any(finite):
        return 0.0
    return float(np.median(y[finite]))


def display_ecg(y_mv: np.ndarray) -> np.ndarray:
    if y_mv.size == 0:
        return y_mv
    y = y_mv.astype(np.float32, copy=True)
    y *= ECG_DISPLAY_SIGN
    y -= finite_median(y)
    y[np.abs(y) > 4.0] = np.nan
    if y.size < 3:
        return y

    out = y.copy()
    finite = np.isfinite(y)
    for i in range(1, y.size - 1):
        if finite[i - 1] and finite[i] and finite[i + 1]:
            out[i] = 0.2 * y[i - 1] + 0.6 * y[i] + 0.2 * y[i + 1]
    return out


def display_selected_ecg(samples: list["Sample"], channel: int) -> np.ndarray:
    y_mv = np.array([s.stitched_mv[channel] for s in samples], dtype=np.float32)
    return display_ecg(y_mv)


def split_corrupt(y: np.ndarray, corrupt: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    good = y.copy()
    bad = y.copy()
    good[corrupt] = np.nan
    bad[~corrupt] = np.nan
    return good, bad


def band_power(y: np.ndarray, fs_hz: float, lo_hz: float, hi_hz: float) -> float:
    if y.size < 8 or not np.isfinite(fs_hz) or fs_hz <= 0:
        return float("nan")
    y = y - finite_median(y)
    y = np.nan_to_num(y, nan=0.0)
    win = np.hanning(y.size)
    spec = np.fft.rfft(y * win)
    freqs = np.fft.rfftfreq(y.size, d=1.0 / fs_hz)
    mask = (freqs >= lo_hz) & (freqs < hi_hz)
    if not np.any(mask):
        return float("nan")
    return float(np.sum(np.abs(spec[mask]) ** 2))


def entropy_8bit(y: np.ndarray) -> float:
    if y.size < 8:
        return float("nan")
    lo = float(np.nanpercentile(y, 1))
    hi = float(np.nanpercentile(y, 99))
    if not np.isfinite(lo) or not np.isfinite(hi) or hi <= lo:
        return float("nan")
    hist, _ = np.histogram(y, bins=32, range=(lo, hi), density=False)
    p = hist.astype(np.float64)
    p = p[p > 0]
    if p.size == 0:
        return float("nan")
    p /= np.sum(p)
    return float(-np.sum(p * np.log2(p)))


def primary_mv(sample: "Sample") -> float:
    if sample.has_phase4:
        return sample.primary_ecg * ADS_SCALE_MV_PER_CODE
    if sample.primary_lead == 2:
        return sample.ads_ch[1] * ADS_SCALE_MV_PER_CODE
    return sample.ads_ch[0] * ADS_SCALE_MV_PER_CODE


def primary_raw_code(sample: "Sample") -> int:
    if sample.primary_lead == 2:
        return sample.ads_ch[1]
    return sample.ads_ch[0]


def ecg_feature_rows(window: list["Sample"], fs_est: float) -> list[tuple[str, str, bool]]:
    if not window:
        return []

    end_t = window[-1].host_t
    recent = [s for s in window if (end_t - s.host_t) <= ECG_FEATURE_WINDOW_S]
    if len(recent) < 8:
        return [("ECG features", "waiting for window", True)]

    corrupt = np.array([s.primary_corrupt for s in recent], dtype=bool)
    y_all = np.array([primary_mv(s) for s in recent], dtype=np.float64)
    raw_codes = np.array([primary_raw_code(s) for s in recent], dtype=np.int32)
    good_mask = np.isfinite(y_all) & ~corrupt
    clean_pct = 100.0 * float(np.count_nonzero(good_mask)) / float(len(recent))
    if np.count_nonzero(good_mask) < 8:
        return [
            ("Clean coverage", f"{clean_pct:.0f}%", True),
            ("ECG features", "corrupted window", True),
        ]

    y = y_all[good_mask]
    y = y - finite_median(y)
    rms = float(np.sqrt(np.mean(y * y)))
    p2p = float(np.nanpercentile(y, 95) - np.nanpercentile(y, 5))
    skew = float(np.mean(((y - np.mean(y)) / (np.std(y) + 1.0e-12)) ** 3))
    kurt = float(np.mean(((y - np.mean(y)) / (np.std(y) + 1.0e-12)) ** 4))
    ent = entropy_8bit(y)

    drift = float("nan")
    if np.isfinite(fs_est) and fs_est > 1.0:
        n = max(3, int(round(0.60 * fs_est)))
        kernel = np.ones(n, dtype=np.float64) / float(n)
        base = np.convolve(y, kernel, mode="same")
        drift = float(np.nanpercentile(base, 95) - np.nanpercentile(base, 5))

    low_band = band_power(y, fs_est, 0.5, 8.0)
    qrs_band = band_power(y, fs_est, 8.0, 35.0)
    qrs_share = float("nan")
    if np.isfinite(low_band) and np.isfinite(qrs_band) and (low_band + qrs_band) > 0:
        qrs_share = 100.0 * qrs_band / (low_band + qrs_band)

    sat_pct = 100.0 * float(np.count_nonzero(np.abs(raw_codes) >= int(0.98 * ADS1293_ADCMAX))) / float(len(raw_codes))

    return [
        ("Clean coverage", f"{clean_pct:.0f}%", clean_pct < 80.0),
        ("ECG RMS", f"{rms:.3f} mV", rms < 0.02),
        ("ECG amplitude", f"{p2p:.3f} mV", p2p < 0.08),
        ("Baseline drift", "--" if not np.isfinite(drift) else f"{drift:.3f} mV", np.isfinite(drift) and drift > 0.45),
        ("QRS band share", "--" if not np.isfinite(qrs_share) else f"{qrs_share:.0f}%", np.isfinite(qrs_share) and qrs_share < 20.0),
        ("ECG skew/kurt", f"{skew:+.2f} / {kurt:.1f}", abs(skew) > 3.0 or kurt > 30.0),
        ("ECG entropy", "--" if not np.isfinite(ent) else f"{ent:.2f}", False),
        ("Rail saturation", f"{sat_pct:.1f}%", sat_pct > 0.0),
    ]


def lead_timing_row(window: list["Sample"], fs_est: float) -> tuple[str, str, bool]:
    if len(window) < 16 or not np.isfinite(fs_est) or fs_est <= 0:
        return ("Lead timing", "same ADS1293 sample row", False)

    good = np.array([not (s.ch1_corrupt or s.ch2_corrupt) for s in window], dtype=bool)
    y1 = np.array([s.stitched_mv[0] for s in window], dtype=np.float64)
    y2 = np.array([s.stitched_mv[1] for s in window], dtype=np.float64)
    good &= np.isfinite(y1) & np.isfinite(y2)
    if np.count_nonzero(good) < 16:
        return ("Lead timing", "same ADS1293 sample row", False)

    y1 = y1[good] - finite_median(y1[good])
    y2 = y2[good] - finite_median(y2[good])
    y1_std = float(np.std(y1))
    y2_std = float(np.std(y2))
    if y1_std < 1.0e-9 or y2_std < 1.0e-9:
        return ("Lead timing", "same ADS1293 sample row", False)

    y1 /= y1_std
    y2 /= y2_std
    corr = np.correlate(y1, y2, mode="full")
    lags = np.arange(-y2.size + 1, y1.size)
    max_lag = max(1, int(round(0.20 * fs_est)))
    keep = np.abs(lags) <= max_lag
    if not np.any(keep):
        return ("Lead timing", "same ADS1293 sample row", False)
    corr_keep = corr[keep]
    lags_keep = lags[keep]
    best = int(np.argmax(np.abs(corr_keep)))
    lag_samples = int(lags_keep[best])
    lag_ms = 1000.0 * float(lag_samples) / fs_est
    coef = float(abs(corr_keep[best]) / max(1.0, y1.size))
    if coef < 0.20:
        return ("Lead timing", "same ADS1293 row; low cross-lead match", False)
    return ("Lead timing", f"same sample row; est lag {lag_ms:+.0f} ms", abs(lag_ms) > 20.0)


def nxp_primary_hrv(sample: "Sample") -> dict[str, float | str | int | bool]:
    hr = float(sample.primary_hr_x10) / 10.0
    rmssd = float(sample.primary_rmssd_x10) / 10.0
    peak_unreliable = bool(sample.flags & PHASE4_FLAG_PEAK_UNRELIABLE)
    ok = np.isfinite(hr) and hr > 0.0
    source = "NXP MAS peak detector"
    if ok and peak_unreliable:
        source = "NXP MAS peak detector (verify)"
    elif not ok:
        source = "waiting for NXP MAS peaks"
    return {
        "ok": ok,
        "hr_bpm": hr,
        "rmssd_ms": rmssd,
        "beats": 0,
        "source": source,
    }


def flags_to_text(flags: int) -> str:
    names = []
    if flags & PHASE4_FLAG_CH1_CORRUPT:
        names.append("CH1 corrupt")
    if flags & PHASE4_FLAG_CH2_CORRUPT:
        names.append("CH2 corrupt")
    if flags & PHASE4_FLAG_PRIMARY_CORRUPT:
        names.append("primary corrupt")
    if flags & PHASE4_FLAG_MOTION_RISK:
        names.append("motion risk")
    if flags & PHASE4_FLAG_MOTION_CORRUPT:
        names.append("motion corrupt")
    if flags & PHASE4_FLAG_LMS_ACTIVE:
        names.append("NLMS active")
    if flags & PHASE4_FLAG_IMU_TIMING_BAD:
        names.append("IMU timing mismatch")
    if flags & PHASE4_FLAG_ADS_SATURATED:
        names.append("ADS rail/saturation")
    if flags & PHASE4_FLAG_ECG_SPIKE:
        names.append("ECG spike")
    if flags & PHASE4_FLAG_ECG_FLATLINE:
        names.append("ECG flatline")
    if flags & PHASE4_FLAG_PEAK_UNRELIABLE:
        names.append("peak unreliable")
    if flags & PHASE4_FLAG_SQI_LOW:
        names.append("low SQI")
    return "clean" if not names else " | ".join(names)


def fmt_x10(v: int, suffix: str, muted: bool = False) -> str:
    if muted or v <= 0:
        return "--"
    return f"{v / 10.0:.1f} {suffix}"


def fmt_float(v: float, suffix: str, decimals: int = 1, muted: bool = False) -> str:
    if muted or not np.isfinite(v) or v <= 0:
        return "--"
    return f"{v:.{decimals}f} {suffix}"


def fmt_int(v: int, muted: bool = False) -> str:
    if muted:
        return "--"
    return str(v)


@dataclass
class Sample:
    host_t: float
    t_us: int
    ads_ch: list[int] = field(default_factory=lambda: [0, 0])
    stitched_ch: list[int] = field(default_factory=lambda: [0, 0])
    primary_ecg: int = 0
    ra_ll_ch: list[int] = field(default_factory=lambda: [0, 0])
    has_ra_ll: bool = False
    has_phase4: bool = False
    ax: list[int] = field(default_factory=lambda: [0, 0, 0])
    ay: list[int] = field(default_factory=lambda: [0, 0, 0])
    az: list[int] = field(default_factory=lambda: [0, 0, 0])
    gx: list[int] = field(default_factory=lambda: [0, 0, 0])
    gy: list[int] = field(default_factory=lambda: [0, 0, 0])
    gz: list[int] = field(default_factory=lambda: [0, 0, 0])
    accel_mag: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])
    gyro_mag: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])
    imu_dt_us: list[int] = field(default_factory=lambda: [0, 0, 0])
    sel_ch1: int = 0
    sel_ch2: int = 0
    primary_lead: int = 0
    flags: int = 0
    hr1_x10: int = 0
    hr2_x10: int = 0
    rmssd1_x10: int = 0
    rmssd2_x10: int = 0
    motion_x10: int = 0
    sqi1: int = 0
    sqi2: int = 0
    epoch_seq: int = 0
    has_epoch_seq: bool = False
    label_epoch_seq: int = -1
    has_label_epoch_seq: bool = False
    p4_cycles: int = 0
    loop_cycles_max: int = 0
    m4_hb: int = 0
    m4_jobs: int = 0
    m4_results: int = 0
    m4_consumed: int = 0
    m4_drops: int = 0
    m4_seq: int = 0
    m4_sel_ch1: int = 0
    m4_sel_ch2: int = 0
    m4_prob1_x1000: int = 0
    m4_prob2_x1000: int = 0

    @property
    def stitched_mv(self) -> tuple[float, float]:
        return (
            self.stitched_ch[0] * ADS_SCALE_MV_PER_CODE,
            self.stitched_ch[1] * ADS_SCALE_MV_PER_CODE,
        )

    @property
    def raw_mv(self) -> tuple[float, float]:
        return (
            self.ads_ch[0] * ADS_SCALE_MV_PER_CODE,
            self.ads_ch[1] * ADS_SCALE_MV_PER_CODE,
        )

    @property
    def primary_hr_x10(self) -> int:
        return self.hr1_x10 if self.primary_lead == 1 else self.hr2_x10

    @property
    def primary_rmssd_x10(self) -> int:
        return self.rmssd1_x10 if self.primary_lead == 1 else self.rmssd2_x10

    @property
    def primary_sqi(self) -> int:
        return self.sqi1 if self.primary_lead == 1 else self.sqi2

    @property
    def immediate_critical(self) -> bool:
        return bool(self.flags & PHASE4_SAMPLE_CORRUPT_FLAGS)

    @property
    def immediate_warning(self) -> bool:
        return bool(self.flags & PHASE4_SAMPLE_WARN_FLAGS)

    @property
    def primary_corrupt(self) -> bool:
        return bool(self.flags & (PHASE4_FLAG_PRIMARY_CORRUPT | PHASE4_SAMPLE_CORRUPT_FLAGS))

    @property
    def ch1_corrupt(self) -> bool:
        return bool(self.flags & (PHASE4_FLAG_CH1_CORRUPT | PHASE4_SAMPLE_CORRUPT_FLAGS))

    @property
    def ch2_corrupt(self) -> bool:
        return bool(self.flags & (PHASE4_FLAG_CH2_CORRUPT | PHASE4_SAMPLE_CORRUPT_FLAGS))


class Logger:
    def __init__(self, recordings_dir: str) -> None:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.dir = Path(recordings_dir)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.session_path = self.dir / f"session_raw_{ts}.txt"
        self._session_f = self.session_path.open("w", encoding="utf-8", buffering=1)
        self._record_f = None
        self._record_path: Optional[Path] = None
        self._recording = False
        self._csv_header: Optional[str] = None
        self._lock = threading.Lock()

    @property
    def is_recording(self) -> bool:
        with self._lock:
            return self._recording

    @property
    def record_path(self) -> Optional[Path]:
        with self._lock:
            return self._record_path

    def set_csv_header(self, header: str) -> None:
        with self._lock:
            self._csv_header = header
            self._session_f.write(header + "\n")
            if self._record_f:
                self._record_f.write(header + "\n")

    def write_data_line(self, line: str) -> None:
        with self._lock:
            self._session_f.write(line + "\n")
            if self._recording and self._record_f:
                self._record_f.write(line + "\n")

    def write_session_line(self, line: str) -> None:
        with self._lock:
            self._session_f.write(line + "\n")

    def start_recording(self, label: str) -> Path:
        safe = "".join(c if c.isalnum() or c in ("_", "-") else "_" for c in label)
        safe = safe.strip("_") or "phase4_monitor"
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        path = self.dir / f"{safe}_{ts}.txt"
        with self._lock:
            if self._record_f:
                self._record_f.close()
            self._record_f = path.open("w", encoding="utf-8", buffering=1)
            self._record_path = path
            self._recording = True
            if self._csv_header:
                self._record_f.write(self._csv_header + "\n")
        return path

    def stop_recording(self) -> Optional[Path]:
        with self._lock:
            if self._record_f:
                self._record_f.close()
                self._record_f = None
            path = self._record_path
            self._record_path = None
            self._recording = False
        return path

    def close(self) -> None:
        with self._lock:
            if self._record_f:
                self._record_f.close()
            self._session_f.close()


class SerialReader(threading.Thread):
    def __init__(self, port: str, baud: int, logger: Logger) -> None:
        super().__init__(daemon=True)
        self.port = port
        self.baud = baud
        self.logger = logger
        self._samples: deque[Sample] = deque()
        self._terminal: deque[str] = deque(maxlen=MAX_TERM_ROWS)
        self._term_ver = 0
        self._lock = threading.Lock()
        self._stop_event = threading.Event()
        self._buf = bytearray()
        self._last_t_us: Optional[int] = None
        self._wrap_offset = 0
        self.header_cols: Optional[list[str]] = None
        self.ok_count = 0
        self.bad_count = 0
        self.n_fields: Optional[int] = None
        self.mode_name = "waiting"
        self.error: Optional[str] = None
        self._last_m4_label_seq = 0
        self._last_epoch_seq: Optional[int] = None

    def stop(self) -> None:
        self._stop_event.set()

    def get_window(self, cutoff: float, end_t: Optional[float] = None) -> list[Sample]:
        with self._lock:
            if end_t is None:
                return [s for s in self._samples if s.host_t >= cutoff]
            return [s for s in self._samples if cutoff <= s.host_t <= end_t]

    def get_terminal(self) -> tuple[int, str]:
        with self._lock:
            return self._term_ver, "\n".join(self._terminal)

    def _push_terminal(self, line: str) -> None:
        with self._lock:
            self._terminal.append(line)
            self._term_ver += 1

    def _expand_t_us(self, t32: int) -> int:
        if self._last_t_us is not None and t32 < self._last_t_us:
            self._wrap_offset += 4_294_967_296
        self._last_t_us = t32
        return self._wrap_offset + t32

    def _int_values(self, line: str) -> Optional[list[int]]:
        parts = line.split(",")
        try:
            raw = [int(p.strip()) for p in parts]
        except ValueError:
            return None
        if not raw:
            return None
        vals = [raw[0]] + [fix_sign(v) for v in raw[1:]]
        vals[0] = self._expand_t_us(raw[0])
        return vals

    def _get(self, vals: list[int], cols: dict[str, int], name: str, default: int = 0) -> int:
        idx = cols.get(name)
        if idx is None or idx >= len(vals):
            return default
        return vals[idx]

    def _fill_imu_from_positions(self, s: Sample, vals: list[int], base: int = 3) -> None:
        for site in range(3):
            b = base + site * 6
            if b + 5 >= len(vals):
                break
            s.ax[site] = vals[b]
            s.ay[site] = vals[b + 1]
            s.az[site] = vals[b + 2]
            s.gx[site] = vals[b + 3]
            s.gy[site] = vals[b + 4]
            s.gz[site] = vals[b + 5]
            s.accel_mag[site] = math.sqrt(
                s.ax[site] ** 2 + s.ay[site] ** 2 + s.az[site] ** 2
            )
            s.gyro_mag[site] = math.sqrt(
                s.gx[site] ** 2 + s.gy[site] ** 2 + s.gz[site] ** 2
            )

    def _parse_with_header(self, vals: list[int]) -> Optional[Sample]:
        if not self.header_cols or len(vals) != len(self.header_cols):
            return None
        cols = {name: i for i, name in enumerate(self.header_cols)}
        if "t_us" not in cols or "ads_ch1" not in cols or "ads_ch2" not in cols:
            return None

        s = Sample(host_t=time.monotonic(), t_us=vals[0])
        s.ads_ch[0] = self._get(vals, cols, "ads_ch1")
        s.ads_ch[1] = self._get(vals, cols, "ads_ch2")

        for site in range(3):
            s.ax[site] = self._get(vals, cols, f"ax{site}")
            s.ay[site] = self._get(vals, cols, f"ay{site}")
            s.az[site] = self._get(vals, cols, f"az{site}")
            s.gx[site] = self._get(vals, cols, f"gx{site}")
            s.gy[site] = self._get(vals, cols, f"gy{site}")
            s.gz[site] = self._get(vals, cols, f"gz{site}")
            s.accel_mag[site] = math.sqrt(
                s.ax[site] ** 2 + s.ay[site] ** 2 + s.az[site] ** 2
            )
            s.gyro_mag[site] = math.sqrt(
                s.gx[site] ** 2 + s.gy[site] ** 2 + s.gz[site] ** 2
            )
            s.imu_dt_us[site] = self._get(vals, cols, f"dt{site}_us")

        has_ra_pair = "p4_ra_pair_ch1" in cols and "p4_ra_pair_ch2" in cols
        has_ra_ll_alias = "p4_ra_ll_ch1" in cols and "p4_ra_ll_ch2" in cols
        ra_pair_ch1 = "p4_ra_pair_ch1" if has_ra_pair else "p4_ra_ll_ch1"
        ra_pair_ch2 = "p4_ra_pair_ch2" if has_ra_pair else "p4_ra_ll_ch2"
        s.has_ra_ll = has_ra_pair or has_ra_ll_alias
        s.ra_ll_ch[0] = self._get(vals, cols, ra_pair_ch1)
        s.ra_ll_ch[1] = self._get(vals, cols, ra_pair_ch2)

        s.has_phase4 = "p4_ch1" in cols and "p4_ch2" in cols
        if s.has_phase4:
            s.stitched_ch[0] = self._get(vals, cols, "p4_ch1")
            s.stitched_ch[1] = self._get(vals, cols, "p4_ch2")
            s.primary_ecg = self._get(vals, cols, "p4_primary")
        else:
            s.stitched_ch[0] = s.ads_ch[0]
            s.stitched_ch[1] = s.ads_ch[1]
            s.primary_ecg = s.ads_ch[0]

        s.sel_ch1 = self._get(vals, cols, "sel_ch1")
        s.sel_ch2 = self._get(vals, cols, "sel_ch2")
        s.primary_lead = self._get(vals, cols, "primary_lead")
        s.flags = self._get(vals, cols, "p4_flags")
        s.hr1_x10 = self._get(vals, cols, "hr1_x10")
        s.hr2_x10 = self._get(vals, cols, "hr2_x10")
        s.rmssd1_x10 = self._get(vals, cols, "rmssd1_x10")
        s.rmssd2_x10 = self._get(vals, cols, "rmssd2_x10")
        s.motion_x10 = self._get(vals, cols, "motion_x10")
        s.sqi1 = self._get(vals, cols, "sqi1")
        s.sqi2 = self._get(vals, cols, "sqi2")
        if "epoch_seq" in cols:
            s.epoch_seq = self._get(vals, cols, "epoch_seq")
            s.has_epoch_seq = True
        if "label_epoch_seq" in cols:
            s.label_epoch_seq = self._get(vals, cols, "label_epoch_seq", -1)
            s.has_label_epoch_seq = s.label_epoch_seq >= 0
        s.p4_cycles = self._get(vals, cols, "p4_cycles")
        s.loop_cycles_max = self._get(vals, cols, "loop_cycles_max")
        s.m4_hb = self._get(vals, cols, "m4_hb")
        s.m4_jobs = self._get(vals, cols, "m4_jobs")
        s.m4_results = self._get(vals, cols, "m4_results")
        s.m4_consumed = self._get(vals, cols, "m4_consumed")
        s.m4_drops = self._get(vals, cols, "m4_drops")
        s.m4_seq = self._get(vals, cols, "m4_seq")
        s.m4_sel_ch1 = self._get(vals, cols, "m4_sel_ch1")
        s.m4_sel_ch2 = self._get(vals, cols, "m4_sel_ch2")
        s.m4_prob1_x1000 = self._get(vals, cols, "m4_prob1_x1000")
        s.m4_prob2_x1000 = self._get(vals, cols, "m4_prob2_x1000")
        return s

    def _parse_inferred(self, vals: list[int]) -> Optional[Sample]:
        if len(vals) not in (15, 19, 20, 21, 22, 23, 24, 32, 33, 41, 42, 43, 44, 53, 54):
            return None

        s = Sample(host_t=time.monotonic(), t_us=vals[0])
        s.ads_ch[0] = vals[1]
        s.ads_ch[1] = vals[2]

        if len(vals) in (15, 19, 20, 21):
            s.ra_ll_ch[0] = vals[3]
            s.ra_ll_ch[1] = vals[4]
            s.stitched_ch[0] = vals[5]
            s.stitched_ch[1] = vals[6]
            s.primary_ecg = vals[7]
            s.sel_ch1 = vals[8]
            s.sel_ch2 = vals[9]
            s.primary_lead = vals[10]
            s.flags = vals[11]
            s.motion_x10 = vals[12]
            s.sqi1 = vals[13]
            s.sqi2 = vals[14]
            if len(vals) >= 19:
                s.hr1_x10 = vals[15]
                s.hr2_x10 = vals[16]
                s.rmssd1_x10 = vals[17]
                s.rmssd2_x10 = vals[18]
            if len(vals) >= 20:
                s.epoch_seq = vals[19]
                s.has_epoch_seq = True
            if len(vals) >= 21:
                s.label_epoch_seq = vals[20]
                s.has_label_epoch_seq = s.label_epoch_seq >= 0
            s.has_ra_ll = True
            s.has_phase4 = True
            return s

        if len(vals) in (22, 23, 32, 33):
            s.ra_ll_ch[0] = vals[3]
            s.ra_ll_ch[1] = vals[4]
            s.stitched_ch[0] = vals[5]
            s.stitched_ch[1] = vals[6]
            s.primary_ecg = vals[7]
            s.sel_ch1 = vals[8]
            s.sel_ch2 = vals[9]
            s.primary_lead = vals[10]
            s.flags = vals[11]
            s.motion_x10 = vals[12]
            s.sqi1 = vals[13]
            s.sqi2 = vals[14]
            s.hr1_x10 = vals[15]
            s.hr2_x10 = vals[16]
            s.rmssd1_x10 = vals[17]
            s.rmssd2_x10 = vals[18]
            s.epoch_seq = vals[19]
            s.has_epoch_seq = True
            diag_base = 20
            if len(vals) in (23, 33):
                s.label_epoch_seq = vals[20]
                s.has_label_epoch_seq = s.label_epoch_seq >= 0
                diag_base = 21
            s.p4_cycles = vals[diag_base]
            s.loop_cycles_max = vals[diag_base + 1]
            if len(vals) in (32, 33):
                m4_base = diag_base + 2
                s.m4_hb = vals[m4_base]
                s.m4_jobs = vals[m4_base + 1]
                s.m4_results = vals[m4_base + 2]
                s.m4_consumed = vals[m4_base + 3]
                s.m4_drops = vals[m4_base + 4]
                s.m4_seq = vals[m4_base + 5]
                s.m4_sel_ch1 = vals[m4_base + 6]
                s.m4_sel_ch2 = vals[m4_base + 7]
                s.m4_prob1_x1000 = vals[m4_base + 8]
                s.m4_prob2_x1000 = vals[m4_base + 9]
            s.has_ra_ll = True
            s.has_phase4 = True
            return s

        self._fill_imu_from_positions(s, vals, 3)
        if len(vals) >= 24:
            s.imu_dt_us = [vals[21], vals[22], vals[23]]

        if len(vals) in (43, 44, 53, 54):
            s.ra_ll_ch[0] = vals[24]
            s.ra_ll_ch[1] = vals[25]
            s.stitched_ch[0] = vals[26]
            s.stitched_ch[1] = vals[27]
            s.primary_ecg = vals[28]
            s.sel_ch1 = vals[29]
            s.sel_ch2 = vals[30]
            s.primary_lead = vals[31]
            s.flags = vals[32]
            s.hr1_x10 = vals[33]
            s.hr2_x10 = vals[34]
            s.rmssd1_x10 = vals[35]
            s.rmssd2_x10 = vals[36]
            s.motion_x10 = vals[37]
            s.sqi1 = vals[38]
            s.sqi2 = vals[39]
            s.epoch_seq = vals[40]
            s.has_epoch_seq = True
            diag_base = 41
            if len(vals) in (44, 54):
                s.label_epoch_seq = vals[41]
                s.has_label_epoch_seq = s.label_epoch_seq >= 0
                diag_base = 42
            s.p4_cycles = vals[diag_base]
            s.loop_cycles_max = vals[diag_base + 1]
            if len(vals) in (53, 54):
                m4_base = diag_base + 2
                s.m4_hb = vals[m4_base]
                s.m4_jobs = vals[m4_base + 1]
                s.m4_results = vals[m4_base + 2]
                s.m4_consumed = vals[m4_base + 3]
                s.m4_drops = vals[m4_base + 4]
                s.m4_seq = vals[m4_base + 5]
                s.m4_sel_ch1 = vals[m4_base + 6]
                s.m4_sel_ch2 = vals[m4_base + 7]
                s.m4_prob1_x1000 = vals[m4_base + 8]
                s.m4_prob2_x1000 = vals[m4_base + 9]
            s.has_ra_ll = True
            s.has_phase4 = True
            return s

        if len(vals) in (41, 42):
            s.stitched_ch[0] = vals[24]
            s.stitched_ch[1] = vals[25]
            s.primary_ecg = vals[26]
            s.sel_ch1 = vals[27]
            s.sel_ch2 = vals[28]
            s.primary_lead = vals[29]
            s.flags = vals[30]
            s.hr1_x10 = vals[31]
            s.hr2_x10 = vals[32]
            s.rmssd1_x10 = vals[33]
            s.rmssd2_x10 = vals[34]
            s.motion_x10 = vals[35]
            s.sqi1 = vals[36]
            s.sqi2 = vals[37]
            s.epoch_seq = vals[38]
            s.has_epoch_seq = True
            diag_base = 39
            if len(vals) == 42:
                s.label_epoch_seq = vals[39]
                s.has_label_epoch_seq = s.label_epoch_seq >= 0
                diag_base = 40
            s.p4_cycles = vals[diag_base]
            s.loop_cycles_max = vals[diag_base + 1]
            s.has_phase4 = True
            return s

        s.stitched_ch[0] = s.ads_ch[0]
        s.stitched_ch[1] = s.ads_ch[1]
        s.primary_ecg = s.ads_ch[0]
        return s

    def _parse(self, line: str) -> Optional[Sample]:
        vals = self._int_values(line)
        if vals is None:
            return None
        sample = self._parse_with_header(vals)
        if sample is not None:
            return sample
        return self._parse_inferred(vals)

    def _set_header(self, line: str) -> None:
        self.header_cols = [c.strip() for c in line.split(",")]
        self.n_fields = len(self.header_cols)
        if "p4_primary" in self.header_cols:
            self.mode_name = "PHASE4_FULL"
        elif "p4_ch1" in self.header_cols:
            self.mode_name = "PHASE4_SELECTED_ONLY"
        else:
            self.mode_name = "ADS1293_IMU_TS"
        self.logger.set_csv_header(line)
        self._push_terminal(line)

    def _align_classifier_label_locked(self, sample: Sample) -> None:
        if sample.has_label_epoch_seq:
            return
        if sample.m4_seq <= 0:
            return

        class_flags = sample.flags & PHASE4_CLASSIFIER_CORRUPT_FLAGS
        if sample.m4_seq != self._last_m4_label_seq:
            for old in self._samples:
                if old.epoch_seq == sample.m4_seq:
                    old.flags = (old.flags & ~PHASE4_CLASSIFIER_CORRUPT_FLAGS) | class_flags
            self._last_m4_label_seq = sample.m4_seq

        if sample.epoch_seq != sample.m4_seq:
            sample.flags &= ~PHASE4_CLASSIFIER_CORRUPT_FLAGS

    def _apply_epoch_label_locked(self, label_seq: int, label_flags: int) -> None:
        for old in self._samples:
            if old.has_epoch_seq and old.epoch_seq == label_seq:
                old.flags = (old.flags & ~PHASE4_EPOCH_LABEL_FLAGS) | label_flags

    def _align_epoch_label_locked(self, sample: Sample) -> None:
        if sample.has_label_epoch_seq:
            label_flags = sample.flags & PHASE4_EPOCH_LABEL_FLAGS
            self._apply_epoch_label_locked(sample.label_epoch_seq, label_flags)
            if sample.has_epoch_seq:
                self._last_epoch_seq = sample.epoch_seq
                if sample.epoch_seq == sample.label_epoch_seq:
                    sample.flags = (sample.flags & ~PHASE4_EPOCH_LABEL_FLAGS) | label_flags
                else:
                    sample.flags &= ~PHASE4_EPOCH_LABEL_FLAGS
            return

        if not sample.has_epoch_seq:
            return

        incoming_flags = sample.flags
        if self._last_epoch_seq is None:
            self._last_epoch_seq = sample.epoch_seq
            sample.flags &= ~PHASE4_EPOCH_LABEL_FLAGS
            return

        if sample.epoch_seq != self._last_epoch_seq:
            completed_seq = self._last_epoch_seq
            label_flags = incoming_flags & PHASE4_EPOCH_LABEL_FLAGS
            self._apply_epoch_label_locked(completed_seq, label_flags)
            self._last_epoch_seq = sample.epoch_seq

        sample.flags &= ~PHASE4_EPOCH_LABEL_FLAGS

    def run(self) -> None:
        try:
            ser = serial.Serial(self.port, self.baud, timeout=0.0)
        except serial.SerialException as exc:
            msg = f"[ERROR] Cannot open {self.port}: {exc}"
            with self._lock:
                self.error = msg
            self._push_terminal(msg)
            return

        ser.reset_input_buffer()
        self._push_terminal(f"[GUI] {self.port} @ {self.baud} connected")
        self._push_terminal(f"[GUI] Session backup: {self.logger.session_path}")
        self._push_terminal("[GUI] Waiting for t_us CSV header...")

        try:
            while not self._stop_event.is_set():
                waiting = ser.in_waiting
                if waiting == 0:
                    time.sleep(0.001)
                    continue
                self._buf += ser.read(waiting)
                while True:
                    nl = self._buf.find(b"\n")
                    if nl < 0:
                        break
                    raw = self._buf[: nl + 1]
                    del self._buf[: nl + 1]
                    line = raw.decode("utf-8", errors="ignore").strip()
                    if not line:
                        continue
                    if line.startswith("t_us,"):
                        self._set_header(line)
                        continue

                    sample = self._parse(line)
                    if sample is None:
                        parts = line.split(",")
                        if len(parts) > 1:
                            self.bad_count += 1
                            self._push_terminal(
                                f"[GUI] Dropped unsupported row with {len(parts)} fields."
                            )
                        else:
                            self._push_terminal(line)
                            self.logger.write_session_line(line)
                        continue

                    self.logger.write_data_line(line)
                    with self._lock:
                        self._align_classifier_label_locked(sample)
                        self._align_epoch_label_locked(sample)
                        self._samples.append(sample)
                        self.ok_count += 1
                        self.n_fields = len(line.split(","))
                        if sample.has_phase4:
                            self.mode_name = "PHASE4_FULL"
                        else:
                            self.mode_name = "ADS1293_IMU_TS"
                        cutoff = time.monotonic() - WINDOW_S * 2.0
                        while self._samples and self._samples[0].host_t < cutoff:
                            self._samples.popleft()
        finally:
            ser.close()


class TopBar(QtWidgets.QWidget):
    def __init__(self, reader: SerialReader, logger: Logger, parent=None) -> None:
        super().__init__(parent)
        self.reader = reader
        self.logger = logger
        self._rec_start_ok = 0

        layout = QtWidgets.QHBoxLayout(self)
        layout.setContentsMargins(12, 6, 12, 6)
        layout.setSpacing(10)

        self.port_lbl = QtWidgets.QLabel(f"{reader.port} @ {reader.baud}")
        self.port_lbl.setStyleSheet(f"color:{FG}; font-weight:bold;")
        layout.addWidget(self.port_lbl)

        layout.addSpacing(14)
        layout.addWidget(QtWidgets.QLabel("Record label:"))
        self.label_edit = QtWidgets.QLineEdit("phase4_monitor")
        self.label_edit.setFixedWidth(170)
        layout.addWidget(self.label_edit)

        self.record_btn = QtWidgets.QPushButton("Start Recording")
        self.record_btn.setFixedWidth(150)
        self.record_btn.clicked.connect(self._toggle_recording)
        layout.addWidget(self.record_btn)

        self.record_status = QtWidgets.QLabel("Not recording")
        self.record_status.setStyleSheet(f"color:{FG_DIM};")
        layout.addWidget(self.record_status)

        layout.addStretch()
        self.count_lbl = QtWidgets.QLabel("")
        self.count_lbl.setStyleSheet(
            f"color:{FG_DIM}; font-family:Consolas,'Courier New',monospace;"
        )
        layout.addWidget(self.count_lbl)

        self.setStyleSheet(
            f"""
            QWidget {{ background:{BG_PANEL}; color:{FG}; }}
            QLineEdit {{
                background:{BG_DARK}; color:{FG}; border:1px solid {BORDER};
                padding:4px 7px; border-radius:3px;
            }}
            QPushButton {{
                background:#287848; color:{FG}; border:1px solid #3aa86a;
                border-radius:3px; padding:5px 10px; font-weight:bold;
            }}
            """
        )

        self._timer = QtCore.QTimer(self)
        self._timer.timeout.connect(self._refresh)
        self._timer.start(500)

    def _toggle_recording(self) -> None:
        if not self.logger.is_recording:
            path = self.logger.start_recording(self.label_edit.text())
            self._rec_start_ok = self.reader.ok_count
            self.record_btn.setText("Stop Recording")
            self.record_btn.setStyleSheet(
                f"background:#832626; color:{FG}; border:1px solid #aa3838; "
                "border-radius:3px; padding:5px 10px; font-weight:bold;"
            )
            self.record_status.setText(f"REC {path.name}")
            self.record_status.setStyleSheet("color:#ff8585; font-weight:bold;")
            self.label_edit.setEnabled(False)
        else:
            path = self.logger.stop_recording()
            self.record_btn.setText("Start Recording")
            self.record_btn.setStyleSheet("")
            self.record_status.setText(f"Saved {path.name}" if path else "Not recording")
            self.record_status.setStyleSheet(f"color:{FG_DIM};")
            self.label_edit.setEnabled(True)

    def _refresh(self) -> None:
        if self.logger.is_recording:
            self.count_lbl.setText(f"{self.reader.ok_count - self._rec_start_ok:,} rec samples")
        else:
            self.count_lbl.setText(f"{self.reader.ok_count:,} samples")


class StatusPanel(QtWidgets.QWidget):
    def __init__(self, reader: SerialReader, logger: Logger, parent=None) -> None:
        super().__init__(parent)
        self.reader = reader
        self.logger = logger
        self.setFixedWidth(420)
        self._last_hr_bpm = float("nan")
        self._last_rmssd_ms = float("nan")
        self._last_hr_t = 0.0

        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(10)

        self.state_lbl = QtWidgets.QLabel("WAITING FOR ECG")
        self.state_lbl.setAlignment(QtCore.Qt.AlignCenter)
        self.state_lbl.setFixedHeight(42)
        layout.addWidget(self.state_lbl)

        hr_row = QtWidgets.QHBoxLayout()
        hr_row.setSpacing(10)
        self.beat_light = QtWidgets.QLabel("")
        self.beat_light.setFixedSize(34, 34)
        hr_row.addWidget(self.beat_light)

        self.hr_lbl = QtWidgets.QLabel("--")
        self.hr_lbl.setAlignment(QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter)
        self.hr_lbl.setStyleSheet(f"color:{GREEN}; font-size:44px; font-weight:bold;")
        hr_row.addWidget(self.hr_lbl, stretch=1)

        self.bpm_lbl = QtWidgets.QLabel("BPM")
        self.bpm_lbl.setAlignment(QtCore.Qt.AlignBottom | QtCore.Qt.AlignLeft)
        self.bpm_lbl.setStyleSheet(f"color:{FG_DIM}; font-size:18px; font-weight:bold;")
        hr_row.addWidget(self.bpm_lbl)
        layout.addLayout(hr_row)

        self.feature_table = QtWidgets.QTableWidget(0, 2)
        self.feature_table.setHorizontalHeaderLabels(["Metric", "Value"])
        self.feature_table.verticalHeader().setVisible(False)
        self.feature_table.horizontalHeader().setStretchLastSection(True)
        self.feature_table.horizontalHeader().setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeToContents)
        self.feature_table.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
        self.feature_table.setSelectionMode(QtWidgets.QAbstractItemView.NoSelection)
        self.feature_table.setFocusPolicy(QtCore.Qt.NoFocus)
        self.feature_table.setAlternatingRowColors(True)
        self.feature_table.setStyleSheet(
            f"""
            QTableWidget {{
                background:{BG_TABLE}; alternate-background-color:#252525;
                color:{FG}; gridline-color:{BORDER}; border:1px solid {BORDER};
                font-size:10pt;
            }}
            QHeaderView::section {{
                background:{BG_PANEL}; color:{FG}; border:0;
                border-bottom:1px solid {BORDER}; padding:5px;
                font-weight:bold;
            }}
            QTableWidget::item {{ padding:4px; }}
            """
        )
        layout.addWidget(self.feature_table, stretch=1)

        self.perf_lbl = QtWidgets.QLabel("Waiting for serial data...")
        self.perf_lbl.setWordWrap(True)
        self.perf_lbl.setAlignment(QtCore.Qt.AlignTop | QtCore.Qt.AlignLeft)
        self.perf_lbl.setStyleSheet(
            f"""
            color:{FG_DIM}; background:{BG_DARK}; border:1px solid {BORDER};
            padding:8px; font-family:Consolas,'Courier New',monospace; font-size:9pt;
            """
        )
        self.perf_lbl.setFixedHeight(130)
        layout.addWidget(self.perf_lbl)

        self.setStyleSheet(f"background:{BG_PANEL}; color:{FG};")

    def _set_state(self, last: Sample) -> None:
        if last.immediate_critical:
            text = "DO NOT USE TRACE"
            bg = "#6f2020"
            border = RED
        elif last.flags & PHASE4_FLAG_PRIMARY_CORRUPT:
            text = "CORRUPTED EPOCH"
            bg = "#6f2020"
            border = RED
        elif last.immediate_warning:
            text = "CHECK SIGNAL"
            bg = "#6c5a1e"
            border = YELLOW
        elif last.has_phase4:
            text = "MONITORING"
            bg = "#1f5c36"
            border = GREEN
        else:
            text = "RAW FALLBACK"
            bg = "#4b4b4b"
            border = FG_DIM
        self.state_lbl.setText(text)
        self.state_lbl.setStyleSheet(
            f"background:{bg}; color:{FG}; border:1px solid {border}; "
            "font-weight:bold; font-size:15px; border-radius:3px;"
        )

    def _set_heartbeat(self, last: Sample, hrv: dict[str, float | str | int | bool]) -> None:
        hr = float(hrv.get("hr_bpm", float("nan")))
        if hr <= 0 or not np.isfinite(hr):
            self.hr_lbl.setText("--")
            self.hr_lbl.setStyleSheet(f"color:{FG_DIM}; font-size:44px; font-weight:bold;")
            light = "#333333"
        else:
            self.hr_lbl.setText(f"{hr:.0f}")
            color = YELLOW if last.primary_corrupt else GREEN
            self.hr_lbl.setStyleSheet(f"color:{color}; font-size:44px; font-weight:bold;")
            period = max(0.35, min(1.4, 60.0 / hr))
            phase = (time.monotonic() % period) / period
            light = "#8dff90" if phase < 0.16 else "#26833e"
        self.beat_light.setStyleSheet(
            f"background:{light}; border:1px solid {BORDER}; border-radius:17px;"
        )

    def _hold_hrv(self, hrv: dict[str, float | str | int | bool]) -> dict[str, float | str | int | bool]:
        now = time.monotonic()
        hr = float(hrv.get("hr_bpm", float("nan")))
        rmssd = float(hrv.get("rmssd_ms", float("nan")))
        if np.isfinite(hr) and hr > 0.0:
            self._last_hr_bpm = hr
            self._last_rmssd_ms = rmssd
            self._last_hr_t = now
            return hrv

        if np.isfinite(self._last_hr_bpm) and (now - self._last_hr_t) <= HR_DISPLAY_HOLD_S:
            hrv = dict(hrv)
            hrv["ok"] = True
            hrv["hr_bpm"] = self._last_hr_bpm
            hrv["rmssd_ms"] = self._last_rmssd_ms
            hrv["source"] = "NXP MAS peak detector (held)"
        return hrv

    def _set_table(
        self,
        last: Sample,
        window: list[Sample],
        lines_per_s: float,
        fs_est: float,
        hrv: dict[str, float | str | int | bool],
    ) -> None:
        muted_primary = last.primary_corrupt
        ch1_muted = last.ch1_corrupt
        ch2_muted = last.ch2_corrupt
        primary_name = f"CH{last.primary_lead}" if last.primary_lead in (1, 2) else "waiting"
        primary_sel = last.sel_ch1 if last.primary_lead == 1 else last.sel_ch2
        if muted_primary:
            corrupt_text = "YES - do not use"
        elif last.immediate_warning:
            corrupt_text = "verify signal"
        else:
            corrupt_text = "No critical flag"
        motion = last.motion_x10 / 10.0
        if motion >= 70.0:
            motion_text = f"{motion:.1f} high"
            motion_warn = True
        elif motion >= 35.0:
            motion_text = f"{motion:.1f} moderate"
            motion_warn = bool(last.flags & PHASE4_FLAG_MOTION_RISK)
        else:
            motion_text = f"{motion:.1f} low"
            motion_warn = False
        rate_warn = False
        target_low = ADS1293_TARGET_FS_HZ * (1.0 - RATE_WARN_FRACTION)
        target_high = ADS1293_TARGET_FS_HZ * (1.0 + RATE_WARN_FRACTION)
        if np.isfinite(fs_est) and (lines_per_s > 1.0):
            rate_warn = abs(fs_est - lines_per_s) > (0.15 * max(fs_est, lines_per_s))
        if np.isfinite(fs_est) and ((fs_est < target_low) or (fs_est > target_high)):
            rate_warn = True
        stream_text = (
            f"host={lines_per_s:.1f} lines/s, t_us={fs_est:.1f} Hz, "
            f"target={ADS1293_TARGET_FS_HZ:.0f} Hz"
        )
        hr_bpm = float(hrv.get("hr_bpm", float("nan")))
        rmssd_ms = float(hrv.get("rmssd_ms", float("nan")))
        hrv_ok = bool(hrv.get("ok", False))
        hrv_source = str(hrv.get("source", "waiting"))
        beats = int(hrv.get("beats", 0))
        rows = [
            ("Primary lead", primary_name, False),
            ("Signal corrupted", corrupt_text, muted_primary),
            ("Cleaning mode", SELECTOR_NAMES.get(primary_sel, f"#{primary_sel}"), muted_primary),
            ("Heart rate", fmt_float(hr_bpm, "bpm", 0, muted=not hrv_ok), not hrv_ok),
            ("HRV RMSSD", fmt_float(rmssd_ms, "ms", 1, muted=not hrv_ok), not hrv_ok),
            ("HR source", f"{hrv_source}" + (f" ({beats} beats)" if hrv_ok and beats > 0 else ""), not hrv_ok),
            ("Lead quality", fmt_int(last.primary_sqi, muted_primary) + "/100", muted_primary or bool(last.flags & PHASE4_FLAG_SQI_LOW)),
            ("CH1 status", "corrupted" if ch1_muted else f"clean, SQI {last.sqi1}/100", ch1_muted),
            ("CH2 status", "corrupted" if ch2_muted else f"clean, SQI {last.sqi2}/100", ch2_muted),
            ("Motion", motion_text, motion_warn),
            lead_timing_row(window, fs_est),
            ("Reason flags", flags_to_text(last.flags), last.flags != 0),
        ]
        rows.extend(ecg_feature_rows(window, fs_est))
        rows.extend([
            ("Stream rate", stream_text, rate_warn),
        ])

        self.feature_table.setRowCount(len(rows))
        for row, (metric, value, muted) in enumerate(rows):
            metric_item = QtWidgets.QTableWidgetItem(metric)
            value_item = QtWidgets.QTableWidgetItem(value)
            if metric in ("Reason flags", "Signal corrupted") and last.flags:
                color = QtGui.QColor(RED if last.primary_corrupt else YELLOW)
            elif muted and metric in ("Heart rate", "HRV RMSSD", "HR source", "Lead quality", "Motion"):
                color = QtGui.QColor(YELLOW if last.immediate_warning and not last.primary_corrupt else FG_DIM)
            elif muted:
                color = QtGui.QColor(FG_DIM)
            else:
                color = QtGui.QColor(FG)
            metric_item.setForeground(color)
            value_item.setForeground(color)
            self.feature_table.setItem(row, 0, metric_item)
            self.feature_table.setItem(row, 1, value_item)
        self.feature_table.resizeRowsToContents()

    def update(self, window: list[Sample], lines_per_s: float) -> None:
        if not window:
            err = self.reader.error
            if err:
                self.state_lbl.setText("SERIAL ERROR")
                self.state_lbl.setStyleSheet(
                    f"background:#6f2020; color:{FG}; border:1px solid {RED}; "
                    "font-weight:bold; font-size:15px; border-radius:3px;"
                )
                self.perf_lbl.setText(err)
            return

        last = window[-1]
        fs_est = float("nan")
        if len(window) >= 3:
            t_arr = np.array([s.t_us for s in window], dtype=np.float64) / 1e6
            dt = np.diff(t_arr)
            dt = dt[dt > 0]
            if dt.size:
                fs_est = 1.0 / float(np.median(dt))

        rec = "REC" if self.logger.is_recording else "idle"
        path = self.logger.record_path.name if self.logger.record_path else self.logger.session_path.name

        self._set_state(last)
        hrv = self._hold_hrv(nxp_primary_hrv(last))
        self._set_heartbeat(last, hrv)
        self._set_table(last, window, lines_per_s, fs_est, hrv)
        self.perf_lbl.setText(
            f"Mode: {self.reader.mode_name}  Fields: {self.reader.n_fields}\n"
            "View: selected ECG, HR/HRV, corruption state, motion, ECG features\n"
            f"Display delay: {DISPLAY_DELAY_S:.1f} s\n"
            f"OK/Bad: {self.reader.ok_count}/{self.reader.bad_count}  t_us: {last.t_us}\n"
            f"Record: {rec}  File: {path}"
        )


class MonitorPanel(QtWidgets.QWidget):
    def __init__(self, reader: SerialReader, logger: Logger, parent=None) -> None:
        super().__init__(parent)
        self.reader = reader
        self.logger = logger

        layout = QtWidgets.QHBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(6)

        self.graphs = pg.GraphicsLayoutWidget()
        layout.addWidget(self.graphs, stretch=1)

        self.ch1_plot = self.graphs.addPlot(row=0, col=0, title="Fixed BPF+N3 ECG - CH1")
        self._setup_ecg_plot(self.ch1_plot)
        self.ch1_raw = self.ch1_plot.plot(
            pen=pg.mkPen("#777777", width=0.7, style=QtCore.Qt.DotLine),
            name="raw CH1",
        )
        self.ch1_good = self.ch1_plot.plot(pen=pg.mkPen(BLUE, width=1.4), name="CH1 clean")
        self.ch1_bad = self.ch1_plot.plot(pen=pg.mkPen(RED, width=2.1), name="CH1 corrupted")
        self.ch1_switch = self.ch1_plot.plot(
            pen=None,
            symbol="t",
            symbolSize=9,
            symbolBrush=pg.mkBrush(YELLOW),
            symbolPen=pg.mkPen(YELLOW),
            name="switch",
        )

        self.ch2_plot = self.graphs.addPlot(row=1, col=0, title="Fixed BPF+N3 ECG - CH2")
        self._setup_ecg_plot(self.ch2_plot)
        self.ch2_raw = self.ch2_plot.plot(
            pen=pg.mkPen("#777777", width=0.7, style=QtCore.Qt.DotLine),
            name="raw CH2",
        )
        self.ch2_good = self.ch2_plot.plot(pen=pg.mkPen(GREEN, width=1.4), name="CH2 clean")
        self.ch2_bad = self.ch2_plot.plot(pen=pg.mkPen(RED, width=2.1), name="CH2 corrupted")
        self.ch2_switch = self.ch2_plot.plot(
            pen=None,
            symbol="t",
            symbolSize=9,
            symbolBrush=pg.mkBrush(YELLOW),
            symbolPen=pg.mkPen(YELLOW),
            name="switch",
        )

        self.motion_plot = self.graphs.addPlot(row=2, col=0, title="Motion and active cleaning")
        self.motion_plot.setLabel("left", "score / selector")
        self.motion_plot.setLabel("bottom", "Time (s)")
        self.motion_plot.setXRange(0, WINDOW_S, padding=0)
        self.motion_plot.setYRange(0, 10, padding=0)
        self.motion_plot.showGrid(x=True, y=True, alpha=0.2)
        self.motion_plot.addLegend(offset=(10, 10))
        self.motion_curve = self.motion_plot.plot(pen=pg.mkPen(YELLOW, width=1.3), name="motion")
        self.sel1_curve = self.motion_plot.plot(
            pen=pg.mkPen(BLUE, width=1.0, style=QtCore.Qt.DashLine),
            name="sel CH1",
        )
        self.sel2_curve = self.motion_plot.plot(
            pen=pg.mkPen(GREEN, width=1.0, style=QtCore.Qt.DashLine),
            name="sel CH2",
        )

        self.status = StatusPanel(reader, logger)
        layout.addWidget(self.status)

    def _setup_ecg_plot(self, plot: pg.PlotItem) -> None:
        plot.setLabel("left", "mV")
        plot.setLabel("bottom", "Time (s)")
        plot.setXRange(0, WINDOW_S, padding=0)
        plot.setYRange(-ECG_DISPLAY_HALF_RANGE_MV, ECG_DISPLAY_HALF_RANGE_MV, padding=0)
        plot.showGrid(x=True, y=True, alpha=0.2)
        plot.addLine(y=0, pen=pg.mkPen(FG_DIM, width=0.5, style=QtCore.Qt.DashLine))
        plot.addLegend(offset=(10, 10))

    def update(
        self,
        window: list[Sample],
        lines_per_s: float,
        display_now: Optional[float] = None,
    ) -> None:
        if not window:
            self.status.update(window, lines_per_s)
            return

        now = display_now if display_now is not None else time.monotonic()
        xs = np.array([s.host_t - (now - WINDOW_S) for s in window], dtype=np.float32)
        ch1 = display_selected_ecg(window, 0)
        ch2 = display_selected_ecg(window, 1)
        raw_ch1 = display_ecg(
            np.array([s.raw_mv[0] for s in window], dtype=np.float32)
        )
        raw_ch2 = display_ecg(
            np.array([s.raw_mv[1] for s in window], dtype=np.float32)
        )
        sel1 = np.array([s.sel_ch1 for s in window], dtype=np.int16)
        sel2 = np.array([s.sel_ch2 for s in window], dtype=np.int16)
        ch1_bad_mask = np.array([s.ch1_corrupt for s in window], dtype=bool)
        ch2_bad_mask = np.array([s.ch2_corrupt for s in window], dtype=bool)
        ch1_good, ch1_bad = split_corrupt(ch1, ch1_bad_mask)
        ch2_good, ch2_bad = split_corrupt(ch2, ch2_bad_mask)
        self.ch1_raw.setData(xs, raw_ch1)
        self.ch1_good.setData(xs, ch1_good)
        self.ch1_bad.setData(xs, ch1_bad)
        ch1_switch_idx = np.nonzero(np.diff(sel1) != 0)[0] + 1
        self.ch1_switch.setData(
            xs[ch1_switch_idx],
            np.full(ch1_switch_idx.size, ECG_DISPLAY_HALF_RANGE_MV * 0.90, dtype=np.float32),
        )
        self.ch2_raw.setData(xs, raw_ch2)
        self.ch2_good.setData(xs, ch2_good)
        self.ch2_bad.setData(xs, ch2_bad)
        ch2_switch_idx = np.nonzero(np.diff(sel2) != 0)[0] + 1
        self.ch2_switch.setData(
            xs[ch2_switch_idx],
            np.full(ch2_switch_idx.size, ECG_DISPLAY_HALF_RANGE_MV * 0.90, dtype=np.float32),
        )

        motion = np.array([s.motion_x10 / 10.0 for s in window], dtype=np.float32)
        self.motion_curve.setData(xs, motion)
        self.sel1_curve.setData(xs, sel1.astype(np.float32))
        self.sel2_curve.setData(xs, sel2.astype(np.float32))

        last = window[-1]
        self.ch1_plot.setTitle(
            f"Selected Phase4 ECG - CH1 ({SELECTOR_NAMES.get(last.sel_ch1, last.sel_ch1)})"
        )
        self.ch2_plot.setTitle(
            f"Selected Phase4 ECG - CH2 ({SELECTOR_NAMES.get(last.sel_ch2, last.sel_ch2)})"
        )
        self.status.update(window, lines_per_s)


class TerminalPane(QtWidgets.QWidget):
    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._last_ver = -1
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(6, 4, 6, 6)
        hdr = QtWidgets.QLabel("Firmware terminal")
        hdr.setStyleSheet(f"color:{FG}; font-weight:bold;")
        layout.addWidget(hdr)
        self.text = QtWidgets.QPlainTextEdit()
        self.text.setReadOnly(True)
        self.text.setMaximumBlockCount(MAX_TERM_ROWS)
        self.text.setStyleSheet(
            f"""
            QPlainTextEdit {{
                background:{BG_DARK}; color:{FG}; border:1px solid {BORDER};
                font-family:Consolas,'Courier New',monospace; font-size:9pt;
            }}
            """
        )
        layout.addWidget(self.text)

    def update(self, reader: SerialReader) -> None:
        ver, text = reader.get_terminal()
        if ver == self._last_ver:
            return
        self.text.setPlainText(text)
        self.text.moveCursor(QtGui.QTextCursor.End)
        self._last_ver = ver


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self, reader: SerialReader, logger: Logger) -> None:
        super().__init__()
        self.reader = reader
        self.logger = logger
        self._last_ok = 0
        self._last_t = time.monotonic()
        self._lines_per_s = 0.0

        self.setWindowTitle(f"Phase 4 ECG Monitor - {reader.port} @ {reader.baud}")
        self.resize(1540, 940)
        self.setStyleSheet(f"QMainWindow {{ background:{BG}; }}")
        pg.setConfigOption("background", BG_PANEL)
        pg.setConfigOption("foreground", FG)

        central = QtWidgets.QWidget()
        central.setStyleSheet(f"background:{BG};")
        self.setCentralWidget(central)
        outer = QtWidgets.QVBoxLayout(central)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        self.topbar = TopBar(reader, logger)
        self.topbar.setFixedHeight(50)
        outer.addWidget(self.topbar)

        splitter = QtWidgets.QSplitter(QtCore.Qt.Vertical)
        splitter.setStyleSheet(f"background:{BG};")
        outer.addWidget(splitter, stretch=1)

        self.monitor = MonitorPanel(reader, logger)
        splitter.addWidget(self.monitor)

        self.terminal = TerminalPane()
        splitter.addWidget(self.terminal)
        splitter.setSizes([740, 150])

        self._timer = QtCore.QTimer(self)
        self._timer.timeout.connect(self._refresh)
        self._timer.start(REFRESH_MS)

    def _refresh(self) -> None:
        now = time.monotonic()
        if now - self._last_t >= 1.0:
            elapsed = max(1.0e-6, now - self._last_t)
            self._lines_per_s = (self.reader.ok_count - self._last_ok) / elapsed
            self._last_ok = self.reader.ok_count
            self._last_t = now
        display_now = now - DISPLAY_DELAY_S
        window = self.reader.get_window(display_now - WINDOW_S, display_now)
        self.monitor.update(window, self._lines_per_s, display_now)
        self.terminal.update(self.reader)

    def closeEvent(self, event) -> None:
        self._timer.stop()
        self.reader.stop()
        if self.reader.is_alive():
            self.reader.join(timeout=2.0)
        self.logger.close()
        print(f"Recordings folder: {self.logger.dir}")
        print(f"Session backup:    {self.logger.session_path}")
        event.accept()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="NXP Phase 4 selected-output ECG monitor GUI")
    parser.add_argument("--port", default=DEFAULT_PORT, help=f"serial port, default {DEFAULT_PORT}")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD, help=f"baud rate, default {DEFAULT_BAUD}")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logger = Logger(RECORDINGS_DIR)
    reader = SerialReader(args.port, args.baud, logger)
    reader.start()
    app = QtWidgets.QApplication(sys.argv)
    window = MainWindow(reader, logger)
    window.show()
    if hasattr(app, "exec_"):
        sys.exit(app.exec_())
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
