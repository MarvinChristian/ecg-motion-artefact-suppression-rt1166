"""
ecg_imu_freq_gui.py

Frequency-domain overlay: ECG signal vs IMU motion.

Shows that motion artefact and ECG signal share the same frequency band,
which is why simple bandpass filtering cannot remove motion artefact
without damaging the ECG, which motivates the reference-based NLMS approach.

Accepts:
  - CSV from NXP serial output  (ads_ch2 for ECG, motion_x10 for motion)
  - CSV with raw IMU columns    (imu_ax / imu_ay / imu_az)
  - MATLAB .mat recordings      (any 1-D numeric field)

Dependencies:
    pip install pyqtgraph numpy scipy matplotlib
"""
from __future__ import annotations

import sys
import csv
import numpy as np
from pathlib import Path
from scipy import signal as spsig

try:
    from scipy.io import loadmat as _loadmat
    HAS_SCIPY_IO = True
except ImportError:
    HAS_SCIPY_IO = False

import matplotlib
matplotlib.use("Qt5Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg as FigureCanvas
from matplotlib.figure import Figure

from pyqtgraph.Qt import QtCore, QtWidgets


def _default_recordings_dir() -> Path:
    for parent in Path(__file__).resolve().parents:
        if parent.name == "Support_Tools":
            curated = parent / "Recordings" / "R01_R10_ADS1293_IMU_TS"
            if curated.is_dir():
                return curated
            return parent / "Recordings"
    return Path(__file__).resolve().parent


# Plot colours
BG     = "#0d0d0d"
GREEN  = "#5ed36a"
CYAN   = "#5ec4d3"
ORANGE = "#e8944a"
DIM    = "#2a2a2a"
FG     = "#d0d0d0"
FG_DIM = "#606060"
CTRL   = "#131313"

ADS_SCALE_MV = (2.0 * 2400.0 / 3.5) / 0xC35000   # ADS1293 code to mV

# Preferred column name detection order
_ECG_PREF  = ["ads_ch2", "ads_ch1", "p4_ch2", "p4_ch1", "ch2", "ch1",
               "ecg", "lead_ii", "lead_i", "ecg_ch2", "ecg_ch1"]
_IMU_PREF  = ["imu_ax", "imu_ay", "imu_az",
               "imu0_ax", "imu0_ay", "imu0_az",
               "imu1_ax", "imu1_ay", "imu1_az",
               "imu2_ax", "imu2_ay", "imu2_az",
               "acc_x", "acc_y", "acc_z",
               "motion_x10", "motion"]


# Data helpers
def _fix_sign(v: np.ndarray) -> np.ndarray:
    out = v.copy().astype(np.int64)
    out[out > 2_147_483_647] -= 4_294_967_296
    return out.astype(np.float64)


def _auto_col(cols: list[str], prefs: list[str]) -> str:
    lower = {c.lower(): c for c in cols}
    for p in prefs:
        if p.lower() in lower:
            return lower[p.lower()]
    return cols[0] if cols else ""


def _welch_db(y: np.ndarray, fs: float, win_s: float = 4.0
              ) -> tuple[np.ndarray, np.ndarray]:
    """Welch PSD normalised to 0 dB at peak."""
    nperseg = min(len(y), max(4, int(fs * win_s)))
    f, pxx  = spsig.welch(y, fs=fs, nperseg=nperseg,
                           scaling="density", detrend="constant")
    db  = 10.0 * np.log10(np.maximum(pxx, 1e-20))
    db -= db.max()
    return f, db


def _downsample(x: np.ndarray, y: np.ndarray, n: int = 4000
                ) -> tuple[np.ndarray, np.ndarray]:
    if len(x) > n:
        idx = np.round(np.linspace(0, len(x) - 1, n)).astype(int)
        return x[idx], y[idx]
    return x, y


# Main window
class FreqDomainGUI(QtWidgets.QMainWindow):

    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("ECG vs IMU Motion — Frequency Domain")
        self.resize(1050, 720)
        self.setStyleSheet(f"QMainWindow {{ background: {BG}; }}")

        self._arrays: dict[str, np.ndarray] = {}

        central = QtWidgets.QWidget()
        central.setStyleSheet(f"background: {BG};")
        self.setCentralWidget(central)
        root = QtWidgets.QVBoxLayout(central)
        root.setContentsMargins(8, 8, 8, 8)
        root.setSpacing(5)

        # File and column selection.
        r1 = self._hrow()

        self._load_btn = self._btn("Load Recording…")
        self._load_btn.clicked.connect(self._load_file)
        r1.addWidget(self._load_btn)

        self._file_lbl = QtWidgets.QLabel("No file loaded")
        self._file_lbl.setStyleSheet(f"color: {FG_DIM}; font-size: 10px;")
        r1.addWidget(self._file_lbl, stretch=1)

        r1.addWidget(self._lbl("ECG col:"))
        self._ecg_col = self._combo()
        r1.addWidget(self._ecg_col)

        r1.addWidget(self._lbl("IMU col:"))
        self._imu_col = self._combo()
        r1.addWidget(self._imu_col)

        root.addWidget(r1)

        # Sample rates, time range, and plot action.
        r2 = self._hrow()

        r2.addWidget(self._lbl("FS ECG (Hz):"))
        self._fs_ecg = self._edit("200", 55)
        r2.addWidget(self._fs_ecg)

        r2.addWidget(self._lbl("FS IMU (Hz):"))
        self._fs_imu = self._edit("200", 55)
        r2.addWidget(self._fs_imu)

        r2.addWidget(self._lbl("  Time (s): from"))
        self._t_start = self._edit("0", 55)
        r2.addWidget(self._t_start)

        r2.addWidget(self._lbl("to"))
        self._t_end = self._edit("(all)", 60)
        r2.addWidget(self._t_end)

        r2.addWidget(self._lbl("  Welch win (s):"))
        self._welch_s = self._edit("4", 45)
        r2.addWidget(self._welch_s)

        r2.addStretch()

        self._plot_btn = self._btn("Plot")
        self._plot_btn.clicked.connect(self._compute_and_plot)
        self._plot_btn.setEnabled(False)
        r2.addWidget(self._plot_btn)

        root.addWidget(r2)

        # Matplotlib canvas.
        plt.style.use("dark_background")
        self._fig = Figure(facecolor=BG)
        self._canvas = FigureCanvas(self._fig)
        self._canvas.setStyleSheet(f"background: {BG};")
        root.addWidget(self._canvas, stretch=1)

        self._draw_empty()

    # Widget factories.
    @staticmethod
    def _hrow() -> QtWidgets.QHBoxLayout:
        w = QtWidgets.QWidget()
        lay = QtWidgets.QHBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)
        return lay          # caller must addWidget(w); this helper returns the layout

    def _hrow_widget(self) -> tuple[QtWidgets.QWidget, QtWidgets.QHBoxLayout]:
        w   = QtWidgets.QWidget()
        w.setStyleSheet(f"background: {BG};")
        lay = QtWidgets.QHBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)
        return w, lay

    def _hrow(self) -> QtWidgets.QWidget:          # type: ignore[override]
        w, lay = self._hrow_widget()
        w._lay = lay                               # stash so callers can addWidget
        w.addWidget    = lay.addWidget             # forward for ergonomics
        w.addStretch   = lay.addStretch
        return w

    def _lbl(self, text: str) -> QtWidgets.QLabel:
        l = QtWidgets.QLabel(text)
        l.setStyleSheet(f"color: {FG_DIM}; font-size: 10px; background: {BG};")
        return l

    def _btn(self, text: str) -> QtWidgets.QPushButton:
        b = QtWidgets.QPushButton(text)
        b.setFixedHeight(24)
        b.setStyleSheet(
            f"background: #1d3828; color: {FG}; border: 1px solid #2e5a3a; "
            "border-radius: 3px; padding: 0 10px; font-size: 10px;"
        )
        return b

    def _combo(self) -> QtWidgets.QComboBox:
        c = QtWidgets.QComboBox()
        c.setMinimumWidth(130)
        c.setStyleSheet(
            f"background: #1a1a1a; color: {FG}; border: 1px solid #333; "
            "border-radius: 2px; font-size: 10px; padding: 2px;"
        )
        return c

    def _edit(self, text: str, w: int = 60) -> QtWidgets.QLineEdit:
        e = QtWidgets.QLineEdit(text)
        e.setFixedWidth(w)
        e.setStyleSheet(
            f"background: #1a1a1a; color: {FG}; border: 1px solid #333; "
            "border-radius: 2px; font-size: 10px; padding: 2px;"
        )
        return e

    # Empty state.
    def _draw_empty(self) -> None:
        self._fig.clear()
        ax = self._fig.add_subplot(111)
        ax.set_facecolor(BG)
        ax.text(0.5, 0.5,
                "Load a CSV or .mat recording, select ECG and IMU columns, then click Plot.",
                transform=ax.transAxes, ha="center", va="center",
                color=FG_DIM, fontsize=11)
        ax.set_axis_off()
        self._canvas.draw()

    # File loading.
    def _load_file(self) -> None:
        path, _ = QtWidgets.QFileDialog.getOpenFileName(
            self, "Open recording",
            str(_default_recordings_dir()),
            "Recordings (*.csv *.txt *.mat);;CSV/TXT (*.csv *.txt);;MAT (*.mat);;All (*)"
        )
        if not path:
            return
        p = Path(path)
        try:
            if p.suffix.lower() == ".mat":
                self._load_mat(p)
            else:  # .csv, .txt, or anything else
                self._load_csv(p)
        except Exception as exc:
            QtWidgets.QMessageBox.critical(self, "Load error", str(exc))
            return

        self._file_lbl.setText(p.name)
        self._populate_combos()
        self._plot_btn.setEnabled(True)

    def _load_csv(self, p: Path) -> None:
        # Parse CSV with stdlib only; pandas is not required.
        with open(p, newline="", encoding="utf-8", errors="ignore") as fh:
            # Skip comment lines; find first non-comment row for header detection
            lines = [ln.rstrip("\n") for ln in fh if ln.strip() and not ln.startswith("#")]

        if not lines:
            raise ValueError("CSV file is empty or all lines are comments.")

        # Detect whether first data line is a text header
        first = lines[0]
        parts = first.split(",")
        try:
            [float(p.strip()) for p in parts]
            has_header = False
        except ValueError:
            has_header = True

        if has_header:
            col_names = [c.strip() for c in parts]
            data_lines = lines[1:]
        else:
            col_names = [f"col_{i}" for i in range(len(parts))]
            data_lines = lines

        if not data_lines:
            raise ValueError("No data rows found after header.")

        # Parse rows; skip any that don't convert cleanly
        rows = []
        n_cols = len(col_names)
        for ln in data_lines:
            cells = ln.split(",")
            if len(cells) != n_cols:
                continue
            try:
                rows.append([float(c.strip()) for c in cells])
            except ValueError:
                continue

        if not rows:
            raise ValueError("No numeric rows could be parsed from CSV.")

        mat = np.array(rows, dtype=np.float64)  # shape (n_rows, n_cols)
        self._arrays = {col_names[i]: mat[:, i] for i in range(n_cols)}

    def _load_mat(self, p: Path) -> None:
        if not HAS_SCIPY_IO:
            raise ImportError("pip install scipy")
        mat = _loadmat(str(p), squeeze_me=True)
        arrays: dict[str, np.ndarray] = {}
        for k, v in mat.items():
            if k.startswith("_"):
                continue
            arr = np.atleast_1d(v)
            if arr.dtype.kind not in ("f", "i", "u"):
                continue
            if arr.ndim == 1:
                arrays[k] = arr.astype(np.float64)
            elif arr.ndim == 2:
                for j in range(arr.shape[1]):
                    arrays[f"{k}_{j}"] = arr[:, j].astype(np.float64)
        if not arrays:
            raise ValueError("No 1-D numeric arrays found in .mat file.")
        self._arrays = arrays

    def _populate_combos(self) -> None:
        cols = list(self._arrays.keys())
        ecg_def = _auto_col(cols, _ECG_PREF)
        imu_def = _auto_col(cols, _IMU_PREF)
        for combo, default in [(self._ecg_col, ecg_def), (self._imu_col, imu_def)]:
            combo.clear()
            combo.addItems(cols)
            if default:
                combo.setCurrentText(default)

    # Plot preparation.
    def _compute_and_plot(self) -> None:
        ecg_col = self._ecg_col.currentText()
        imu_col = self._imu_col.currentText()
        if not ecg_col or not imu_col:
            return
        if ecg_col not in self._arrays or imu_col not in self._arrays:
            return

        try:
            fs_ecg   = float(self._fs_ecg.text())
            fs_imu   = float(self._fs_imu.text())
            welch_ws = float(self._welch_s.text())
        except ValueError:
            QtWidgets.QMessageBox.warning(self, "Input error", "Invalid sample rate or window.")
            return

        ecg_raw = self._arrays[ecg_col].copy()
        imu_raw = self._arrays[imu_col].copy()

        # Slice by time range
        t_start  = self._parse_float(self._t_start.text(), 0.0)
        t_end_e  = self._parse_float(self._t_end.text(), len(ecg_raw) / fs_ecg)
        t_end_i  = self._parse_float(self._t_end.text(), len(imu_raw) / fs_imu)
        t_end_e  = min(t_end_e, len(ecg_raw) / fs_ecg)
        t_end_i  = min(t_end_i, len(imu_raw) / fs_imu)

        ecg = ecg_raw[int(t_start * fs_ecg): int(t_end_e * fs_ecg)]
        imu = imu_raw[int(t_start * fs_imu): int(t_end_i * fs_imu)]

        if len(ecg) < 16 or len(imu) < 16:
            QtWidgets.QMessageBox.warning(self, "Too short",
                                          "Selected window is too short for PSD.")
            return

        # Convert ECG codes to mV when values look like raw ADS1293 output.
        if np.abs(ecg).max() > 1000.0:
            ecg = _fix_sign(ecg) * ADS_SCALE_MV

        # motion_x10 is stored at 10x scale in the firmware stream.
        if "motion_x10" in imu_col.lower():
            imu = imu / 10.0

        f_ecg, db_ecg = _welch_db(ecg, fs_ecg, welch_ws)
        f_imu, db_imu = _welch_db(imu, fs_imu, welch_ws)

        self._draw(f_ecg, db_ecg, f_imu, db_imu,
                   ecg, imu, fs_ecg, fs_imu, t_start,
                   ecg_col, imu_col)

    @staticmethod
    def _parse_float(text: str, default: float) -> float:
        try:
            return float(text)
        except ValueError:
            return default

    # Drawing.
    def _draw(self,
              f_ecg, db_ecg, f_imu, db_imu,
              ecg, imu, fs_ecg, fs_imu, t_start,
              ecg_col, imu_col) -> None:

        self._fig.clear()
        self._fig.patch.set_facecolor(BG)

        gs  = self._fig.add_gridspec(2, 1, height_ratios=[2.2, 1],
                                     hspace=0.38,
                                     left=0.07, right=0.97,
                                     top=0.94, bottom=0.08)
        ax_f = self._fig.add_subplot(gs[0])
        ax_t = self._fig.add_subplot(gs[1])

        for ax in (ax_f, ax_t):
            ax.set_facecolor("#090909")
            for spine in ax.spines.values():
                spine.set_color("#2a2a2a")
            ax.tick_params(colors=FG_DIM, labelsize=8)
            ax.xaxis.label.set_color(FG_DIM)
            ax.yaxis.label.set_color(FG_DIM)
            ax.title.set_color(FG)

        f_nyq = min(fs_ecg / 2.0, fs_imu / 2.0, 80.0)

        # Frequency-domain panel.
        # ECG clinical band shaded
        ax_f.axvspan(0.5, 40.0, alpha=0.09, color=GREEN, zorder=0)
        ax_f.axvline(0.5,  color=GREEN, lw=0.7, ls="--", alpha=0.35, zorder=1)
        ax_f.axvline(40.0, color=GREEN, lw=0.7, ls="--", alpha=0.35, zorder=1)

        # QRS energy band lightly highlighted
        ax_f.axvspan(5.0, 25.0, alpha=0.04, color="#ffffff", zorder=0)

        mask_e = f_ecg <= f_nyq
        mask_i = f_imu <= f_nyq

        ax_f.plot(f_ecg[mask_e], db_ecg[mask_e],
                  color=GREEN, lw=1.6, label=f"ECG — {ecg_col}", zorder=3)
        ax_f.plot(f_imu[mask_i], db_imu[mask_i],
                  color=CYAN,  lw=1.6, label=f"IMU — {imu_col}", alpha=0.85, zorder=3)

        # Annotations
        band_x = 21.0
        ax_f.text(band_x, -1.5,
                  "0.5 – 40 Hz\nECG clinical band",
                  color=GREEN, fontsize=7.5, alpha=0.65, va="top")

        ax_f.text(5.2, -1.5,
                  "QRS\nenergy\n5 – 25 Hz",
                  color=FG_DIM, fontsize=7, va="top", alpha=0.55)

        # Find where IMU has most power and annotate overlap
        overlap_mask = (f_imu >= 0.5) & (f_imu <= 10.0) & mask_i
        if overlap_mask.any():
            peak_f = f_imu[overlap_mask][np.argmax(db_imu[overlap_mask])]
            ax_f.annotate(
                f"Motion peak\n≈ {peak_f:.1f} Hz",
                xy=(peak_f, db_imu[(np.abs(f_imu - peak_f)).argmin()]),
                xytext=(peak_f + 3.5, -8),
                fontsize=7.5, color=CYAN, alpha=0.8,
                arrowprops=dict(arrowstyle="->", color=CYAN, lw=0.8),
            )

        ax_f.set_xlim(0.1, f_nyq)
        ax_f.set_ylim(-50, 4)
        ax_f.set_xlabel("Frequency (Hz)", fontsize=9)
        ax_f.set_ylabel("Relative power (dB)", fontsize=9)
        ax_f.set_title("Frequency Domain — ECG vs IMU Motion  (Welch PSD, peak-normalised)",
                        fontsize=10, pad=6)
        ax_f.legend(loc="upper right", fontsize=8,
                    facecolor="#1a1a1a", edgecolor="#2a2a2a", labelcolor=FG)
        ax_f.grid(True, color="#1e1e1e", lw=0.5)

        # Time-domain preview.
        t_e = np.arange(len(ecg)) / fs_ecg + t_start
        t_i = np.arange(len(imu)) / fs_imu + t_start

        ecg_n = ecg / (np.abs(ecg).max() or 1.0)
        imu_n = imu / (np.abs(imu).max() or 1.0)

        ax_t.plot(*_downsample(t_e, ecg_n), color=GREEN, lw=0.8,
                  label=f"ECG ({ecg_col})", alpha=0.9)
        ax_t.plot(*_downsample(t_i, imu_n), color=CYAN,  lw=0.8,
                  label=f"IMU ({imu_col})", alpha=0.75)

        ax_t.set_ylim(-1.6, 1.6)
        ax_t.set_xlabel("Time (s)", fontsize=9)
        ax_t.set_ylabel("Normalised", fontsize=9)
        ax_t.set_title("Time Domain Preview (normalised ±1)", fontsize=9, pad=4)
        ax_t.legend(loc="upper right", fontsize=7,
                    facecolor="#1a1a1a", edgecolor="#2a2a2a", labelcolor=FG)
        ax_t.grid(True, color="#1e1e1e", lw=0.5)

        self._canvas.draw()


# Entry point.
def main() -> None:
    app = QtWidgets.QApplication(sys.argv)
    win = FreqDomainGUI()
    win.show()
    sys.exit(app.exec_() if hasattr(app, "exec_") else app.exec())


if __name__ == "__main__":
    main()
