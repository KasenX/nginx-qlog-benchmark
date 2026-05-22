#!/usr/bin/env python3

from __future__ import annotations

import csv
import html
import os
from math import ceil, cos, floor, log10, pi, sin
from statistics import median
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence


ROOT = Path(__file__).resolve().parents[1]
RESULTS_DIR = Path(
    os.environ.get("BENCH_RESULTS_DIR", str(ROOT / "results"))
).expanduser()
ANALYSIS_DIR = Path(
    os.environ.get("BENCH_ANALYSIS_DIR", str(RESULTS_DIR / "analysis"))
).expanduser()
PLOTS_DIR = Path(
    os.environ.get("BENCH_PLOTS_DIR", str(ANALYSIS_DIR / "plots"))
).expanduser()

BASELINE_SCENARIO = "master"
SCENARIO_ORDER = [
    "master",
    "qlog-off",
    "quic-qlog",
    "quic-qlog-extended",
    "http3-qlog",
    "qlog-on-disk",
]
RAM_QLOG_SCENARIOS = {"quic-qlog", "quic-qlog-extended", "http3-qlog"}
QLOG_SCENARIOS = [
    "quic-qlog",
    "quic-qlog-extended",
    "http3-qlog",
    "qlog-on-disk",
]
QLOG_PLOT_SCENARIOS = [
    "quic-qlog",
    "quic-qlog-extended",
    "http3-qlog",
]
SCENARIO_COLORS = {
    "master": "#3b4252",
    "qlog-off": "#5e81ac",
    "quic-qlog": "#d08700",
    "quic-qlog-extended": "#b48ead",
    "http3-qlog": "#a3be8c",
    "qlog-on-disk": "#bf616a",
}
WORKLOAD_ORDER = ["small", "bulk"]
WORKLOAD_LABELS = {
    "small": "Small 16k",
    "bulk": "Bulk 1m",
}
WORKLOAD_SHORT = {
    "small": "small",
    "bulk": "bulk",
}
SERIF_FONT_STACK = (
    '"TeX Gyre Termes", "Nimbus Roman No9 L", "Times New Roman", Times, serif'
)
AXIS_FONT_SIZE = 20
LEGEND_FONT_SIZE = 20
VALUE_FONT_SIZE = 20
LEGEND_SWATCH_WIDTH = 16
LEGEND_SWATCH_HEIGHT = 12


@dataclass
class SeriesValue:
    scenario: str
    value: float
    saturated: bool = False


def write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def read_tsv(path: Path) -> List[Dict[str, str]]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def display_path(path: Path) -> str:
    path = path.resolve()
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def escape(text: object) -> str:
    return html.escape(str(text))


def fmt_number(value: float) -> str:
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.1f}G"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.1f}k"
    return f"{value:.0f}"


def fmt_req_per_s(value: float) -> str:
    if value >= 1000:
        return f"{value / 1000:.1f}k"
    return f"{value:.0f}"


def fmt_req_per_s_scaled(value: float) -> str:
    if value >= 1000:
        return fmt_compact_scaled(value, 1000, "k")
    return f"{value:.0f}"


def fmt_compact_scaled(value: float, divisor: float, suffix: str) -> str:
    scaled = value / divisor
    if scaled.is_integer():
        return f"{scaled:.0f} {suffix}"
    return f"{scaled:.1f} {suffix}"


def fmt_bytes_per_request(value: float) -> str:
    if value >= 1_000_000:
        return fmt_compact_scaled(value, 1_000_000, "MB")
    if value >= 1_000:
        return fmt_compact_scaled(value, 1_000, "kB")
    return f"{value:.0f} B"


def fmt_bytes(value: float) -> str:
    if value >= 1_000_000_000:
        return fmt_compact_scaled(value, 1_000_000_000, "GB")
    if value >= 1_000_000:
        return fmt_compact_scaled(value, 1_000_000, "MB")
    if value >= 1_000:
        return fmt_compact_scaled(value, 1_000, "kB")
    return f"{value:.0f} B"


def fmt_percent(value: float) -> str:
    return f"{value:.0f}%"


def fmt_milliseconds_from_us(value: float) -> str:
    return f"{value / 1000:.0f} ms"


def nice_tick_step(raw_step: float) -> float:
    if raw_step <= 0:
        return 1.0
    magnitude = 10 ** floor(log10(raw_step))
    residual = raw_step / magnitude
    if residual <= 1:
        nice = 1
    elif residual <= 2:
        nice = 2
    elif residual <= 5:
        nice = 5
    else:
        nice = 10
    return nice * magnitude


def build_axis_ticks(max_value: float, tick_count: int = 5) -> tuple[List[float], float]:
    if max_value <= 0:
        return [0.0, 1.0], 1.0
    step = nice_tick_step(max_value / tick_count)
    y_max = step * ceil(max_value / step)
    tick_total = int(round(y_max / step))
    ticks = [step * idx for idx in range(tick_total + 1)]
    return ticks, y_max


def parse_hex_color(color: str) -> tuple[float, float, float]:
    color = color.lstrip("#")
    if len(color) != 6:
        raise ValueError(f"unsupported color: {color}")
    return (
        int(color[0:2], 16) / 255.0,
        int(color[2:4], 16) / 255.0,
        int(color[4:6], 16) / 255.0,
    )


def pdf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def estimate_text_width(text: str, font_size: float, bold: bool = False) -> float:
    width = 0.0
    for char in text:
        if char == " ":
            width += 0.28
        elif char in "il.,:;|!":
            width += 0.22
        elif char in "MW@#%&":
            width += 0.9
        elif char.isupper():
            width += 0.68
        else:
            width += 0.52
    if bold:
        width *= 1.03
    return width * font_size


class PdfCanvas:
    def __init__(self, width: int, height: int) -> None:
        self.width = width
        self.height = height
        self.commands: List[str] = []

    def _y(self, y: float) -> float:
        return self.height - y

    def _rgb(self, color: str) -> str:
        r, g, b = parse_hex_color(color)
        return f"{r:.4f} {g:.4f} {b:.4f}"

    def line(
        self,
        x1: float,
        y1: float,
        x2: float,
        y2: float,
        *,
        color: str = "#000000",
        width: float = 1.0,
    ) -> None:
        self.commands.append(
            "q "
            f"{self._rgb(color)} RG {width:.2f} w "
            f"{x1:.2f} {self._y(y1):.2f} m {x2:.2f} {self._y(y2):.2f} l S Q"
        )

    def rect(
        self,
        x: float,
        y: float,
        width: float,
        height: float,
        *,
        fill: str | None = None,
        stroke: str | None = None,
        stroke_width: float = 1.0,
    ) -> None:
        pdf_y = self._y(y + height)
        ops = ["q"]
        if fill:
            ops.append(f"{self._rgb(fill)} rg")
        if stroke:
            ops.append(f"{self._rgb(stroke)} RG {stroke_width:.2f} w")
        ops.append(f"{x:.2f} {pdf_y:.2f} {width:.2f} {height:.2f} re")
        if fill and stroke:
            ops.append("B")
        elif fill:
            ops.append("f")
        else:
            ops.append("S")
        ops.append("Q")
        self.commands.append(" ".join(ops))

    def circle(
        self,
        cx: float,
        cy: float,
        radius: float,
        *,
        fill: str | None = None,
        stroke: str | None = None,
        stroke_width: float = 1.0,
    ) -> None:
        cy_pdf = self._y(cy)
        k = 0.5522847498 * radius
        ops = ["q"]
        if fill:
            ops.append(f"{self._rgb(fill)} rg")
        if stroke:
            ops.append(f"{self._rgb(stroke)} RG {stroke_width:.2f} w")
        ops.append(f"{cx + radius:.2f} {cy_pdf:.2f} m")
        ops.append(
            f"{cx + radius:.2f} {cy_pdf + k:.2f} {cx + k:.2f} {cy_pdf + radius:.2f} {cx:.2f} {cy_pdf + radius:.2f} c"
        )
        ops.append(
            f"{cx - k:.2f} {cy_pdf + radius:.2f} {cx - radius:.2f} {cy_pdf + k:.2f} {cx - radius:.2f} {cy_pdf:.2f} c"
        )
        ops.append(
            f"{cx - radius:.2f} {cy_pdf - k:.2f} {cx - k:.2f} {cy_pdf - radius:.2f} {cx:.2f} {cy_pdf - radius:.2f} c"
        )
        ops.append(
            f"{cx + k:.2f} {cy_pdf - radius:.2f} {cx + radius:.2f} {cy_pdf - k:.2f} {cx + radius:.2f} {cy_pdf:.2f} c"
        )
        if fill and stroke:
            ops.append("B")
        elif fill:
            ops.append("f")
        else:
            ops.append("S")
        ops.append("Q")
        self.commands.append(" ".join(ops))

    def text(
        self,
        x: float,
        y: float,
        text: str,
        *,
        font_size: float = 12.0,
        color: str = "#000000",
        bold: bool = False,
        anchor: str = "start",
        rotate_deg: float | None = None,
        baseline: str = "alphabetic",
    ) -> None:
        anchor_offset = 0.0
        if anchor == "middle":
            anchor_offset = estimate_text_width(text, font_size, bold=bold) / 2.0
        elif anchor == "end":
            anchor_offset = estimate_text_width(text, font_size, bold=bold)

        baseline_offset = 0.0
        if baseline == "middle":
            baseline_offset = font_size * 0.35

        y_pdf = self._y(y + baseline_offset)
        font_name = "/F2" if bold else "/F1"
        rgb = self._rgb(color)
        if rotate_deg is None:
            x -= anchor_offset
            matrix = f"1 0 0 1 {x:.2f} {y_pdf:.2f}"
        else:
            radians = rotate_deg * pi / 180.0
            c = cos(radians)
            s = sin(radians)
            x -= anchor_offset * c
            y_pdf -= anchor_offset * s
            matrix = f"{c:.5f} {s:.5f} {-s:.5f} {c:.5f} {x:.2f} {y_pdf:.2f}"
        self.commands.append(
            "q "
            f"{rgb} rg BT {font_name} {font_size:.2f} Tf {matrix} Tm ({pdf_escape(text)}) Tj ET Q"
        )

    def striped_rect(
        self,
        x: float,
        y: float,
        width: float,
        height: float,
        *,
        color: str = "#ffffff",
        step: float = 8.0,
        stroke_width: float = 1.5,
    ) -> None:
        top = y
        bottom = y + height
        left = x
        right = x + width
        start = left - height
        pos = start
        while pos < right:
            x1 = max(left, pos)
            y1 = top + max(0.0, left - pos)
            x2 = min(right, pos + height)
            y2 = bottom - max(0.0, pos + height - right)
            self.line(x1, y1, x2, y2, color=color, width=stroke_width)
            pos += step

    def save(self, path: Path) -> None:
        content = "\n".join(self.commands).encode("latin-1", "replace")
        objects: List[bytes] = [
            b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            (
                f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {self.width} {self.height}] "
                f"/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>"
            ).encode("ascii"),
            b"<< /Length " + str(len(content)).encode("ascii") + b" >>\nstream\n" + content + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Times-Bold >>",
        ]

        out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = [0]
        for idx, obj in enumerate(objects, start=1):
            offsets.append(len(out))
            out.extend(f"{idx} 0 obj\n".encode("ascii"))
            out.extend(obj)
            out.extend(b"\nendobj\n")
        xref_pos = len(out)
        out.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
        out.extend(b"0000000000 65535 f \n")
        for offset in offsets[1:]:
            out.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
        out.extend(
            (
                f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
                f"startxref\n{xref_pos}\n%%EOF\n"
            ).encode("ascii")
        )
        write_bytes(path, bytes(out))


def workload_sort_key(workload: str) -> int:
    return WORKLOAD_ORDER.index(workload)


def scenario_sort_key(scenario: str) -> int:
    return SCENARIO_ORDER.index(scenario)


def scenario_label(scenario: str, has_ram_saturation: bool) -> str:
    if scenario in RAM_QLOG_SCENARIOS and has_ram_saturation:
        return f"{scenario}*"
    return scenario


def svg_header(width: int, height: int) -> List[str]:
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img">',
        '<defs>',
        '<style>',
        f'.axis {{ font: {AXIS_FONT_SIZE}px {SERIF_FONT_STACK}; fill: #444; }}',
        '.tick { stroke: #c7c7c7; stroke-width: 1; }',
        '.grid { stroke: #ececec; stroke-width: 1; }',
        f'.legend {{ font: {LEGEND_FONT_SIZE}px {SERIF_FONT_STACK}; fill: #333; }}',
        f'.note {{ font: 12px {SERIF_FONT_STACK}; fill: #555; }}',
        f'.label {{ font: 11px {SERIF_FONT_STACK}; fill: #333; }}',
        f'.value {{ font: {VALUE_FONT_SIZE}px {SERIF_FONT_STACK}; fill: #333; }}',
        '</style>',
        '<pattern id="sat-stripe" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">',
        '<rect width="6" height="6" fill="rgba(255,255,255,0)"/>',
        '<line x1="0" y1="0" x2="0" y2="6" stroke="rgba(255,255,255,0.55)" stroke-width="2"/>',
        '</pattern>',
        '</defs>',
    ]


def svg_footer(lines: List[str]) -> str:
    return "\n".join(lines + ["</svg>", ""])


def add_legend(
    lines: List[str], x: float, y: float, scenarios: Sequence[str], has_ram_saturation: bool
) -> None:
    for idx, scenario in enumerate(scenarios):
        yy = y + idx * 22
        swatch_y = yy - LEGEND_SWATCH_HEIGHT / 2
        color = SCENARIO_COLORS[scenario]
        label = scenario_label(scenario, has_ram_saturation)
        lines.append(
            f'<rect x="{x}" y="{swatch_y}" width="{LEGEND_SWATCH_WIDTH}" height="{LEGEND_SWATCH_HEIGHT}" rx="2" fill="{color}" />'
        )
        if scenario in RAM_QLOG_SCENARIOS and has_ram_saturation:
            lines.append(
                f'<rect x="{x}" y="{swatch_y}" width="{LEGEND_SWATCH_WIDTH}" height="{LEGEND_SWATCH_HEIGHT}" rx="2" fill="url(#sat-stripe)" />'
            )
        lines.append(
            f'<text class="legend" x="{x + 24}" y="{yy}" dominant-baseline="middle">{escape(label)}</text>'
        )


def draw_grouped_bar_chart(
    out_path: Path,
    categories: Sequence[str],
    grouped_values: Sequence[Sequence[SeriesValue]],
    ylabel: str,
    y_ticks: Sequence[float],
    y_max: float,
    scenarios: Sequence[str],
    has_ram_saturation: bool = False,
    footnote: str | None = None,
    value_formatter=fmt_number,
    margin_left: int = 110,
) -> None:
    width = 1280
    height = 760
    margin_right = 220
    margin_top = 38
    margin_bottom = 170
    plot_width = width - margin_left - margin_right
    plot_height = height - margin_top - margin_bottom
    plot_x0 = margin_left
    plot_y0 = margin_top
    plot_x1 = plot_x0 + plot_width
    plot_y1 = plot_y0 + plot_height
    group_width = plot_width / len(categories)
    bar_band = group_width * 0.72
    bar_width = bar_band / len(scenarios)
    pdf = PdfCanvas(width, height)

    lines = svg_header(width, height)
    for tick in y_ticks:
        y = plot_y1 - (tick / y_max) * plot_height
        lines.append(f'<line class="grid" x1="{plot_x0}" y1="{y:.2f}" x2="{plot_x1}" y2="{y:.2f}" />')
        lines.append(
            f'<text class="axis" x="{plot_x0 - 12}" y="{y + 4:.2f}" text-anchor="end">{escape(value_formatter(tick))}</text>'
        )
        pdf.line(plot_x0, y, plot_x1, y, color="#ececec", width=1)
        pdf.text(
            plot_x0 - 12,
            y + 4,
            value_formatter(tick),
            font_size=AXIS_FONT_SIZE,
            color="#444444",
            anchor="end",
        )

    lines.append(f'<line class="tick" x1="{plot_x0}" y1="{plot_y1}" x2="{plot_x1}" y2="{plot_y1}" />')
    lines.append(f'<line class="tick" x1="{plot_x0}" y1="{plot_y0}" x2="{plot_x0}" y2="{plot_y1}" />')
    lines.append(
        f'<text class="axis" x="28" y="{plot_y0 + plot_height / 2}" text-anchor="middle" dominant-baseline="middle" transform="rotate(-90 28 {plot_y0 + plot_height / 2})">{escape(ylabel)}</text>'
    )
    pdf.line(plot_x0, plot_y1, plot_x1, plot_y1, color="#c7c7c7", width=1)
    pdf.line(plot_x0, plot_y0, plot_x0, plot_y1, color="#c7c7c7", width=1)
    pdf.text(
        28,
        plot_y0 + plot_height / 2,
        ylabel,
        font_size=AXIS_FONT_SIZE,
        color="#444444",
        anchor="middle",
        rotate_deg=90,
        baseline="middle",
    )

    for cat_idx, category in enumerate(categories):
        gx = plot_x0 + cat_idx * group_width + (group_width - bar_band) / 2
        lines.append(
            f'<text class="axis" x="{gx + bar_band / 2:.2f}" y="{plot_y1 + 48}" text-anchor="middle">{escape(category)}</text>'
        )
        pdf.text(
            gx + bar_band / 2,
            plot_y1 + 48,
            category,
            font_size=AXIS_FONT_SIZE,
            color="#444444",
            anchor="middle",
        )
        for series_idx, series in enumerate(grouped_values[cat_idx]):
            bar_x = gx + series_idx * bar_width
            bar_h = (series.value / y_max) * plot_height
            bar_y = plot_y1 - bar_h
            lines.append(
                f'<rect x="{bar_x:.2f}" y="{bar_y:.2f}" width="{bar_width - 4:.2f}" height="{bar_h:.2f}" '
                f'rx="3" fill="{SCENARIO_COLORS[series.scenario]}" />'
            )
            pdf.rect(
                bar_x,
                bar_y,
                bar_width - 4,
                bar_h,
                fill=SCENARIO_COLORS[series.scenario],
            )
            if series.saturated:
                lines.append(
                    f'<rect x="{bar_x:.2f}" y="{bar_y:.2f}" width="{bar_width - 4:.2f}" height="{bar_h:.2f}" '
                    f'rx="3" fill="url(#sat-stripe)" />'
                )
                pdf.striped_rect(bar_x, bar_y, bar_width - 4, bar_h)
                lines.append(
                    f'<text class="value" x="{bar_x + (bar_width - 4)/2:.2f}" y="{max(plot_y0 + 12, bar_y - 8):.2f}" text-anchor="middle">*</text>'
                )
                pdf.text(
                    bar_x + (bar_width - 4) / 2,
                    max(plot_y0 + 12, bar_y - 8),
                    "*",
                    font_size=VALUE_FONT_SIZE,
                    color="#333333",
                    anchor="middle",
                )

    add_legend(lines, plot_x1 + 32, plot_y0 + 20, scenarios, has_ram_saturation)
    for idx, scenario in enumerate(scenarios):
        yy = plot_y0 + 20 + idx * 22
        swatch_y = yy - LEGEND_SWATCH_HEIGHT / 2
        label = scenario_label(scenario, has_ram_saturation)
        pdf.rect(
            plot_x1 + 32,
            swatch_y,
            LEGEND_SWATCH_WIDTH,
            LEGEND_SWATCH_HEIGHT,
            fill=SCENARIO_COLORS[scenario],
        )
        if scenario in RAM_QLOG_SCENARIOS and has_ram_saturation:
            pdf.striped_rect(
                plot_x1 + 32,
                swatch_y,
                LEGEND_SWATCH_WIDTH,
                LEGEND_SWATCH_HEIGHT,
            )
        pdf.text(
            plot_x1 + 56,
            yy,
            label,
            font_size=LEGEND_FONT_SIZE,
            color="#333333",
            baseline="middle",
        )
    if footnote:
        lines.append(
            f'<text class="note" x="{plot_x0}" y="{height - 26}">{escape(footnote)}</text>'
        )
        pdf.text(plot_x0, height - 26, footnote, font_size=12, color="#555555")

    write_text(out_path, svg_footer(lines))
    pdf.save(out_path.with_suffix(".pdf"))


def draw_dot_plot(
    out_path: Path,
    categories: Sequence[str],
    case_values: Dict[tuple, List[float]],
    ylabel: str,
    y_ticks: Sequence[float],
    y_max: float,
    scenarios: Sequence[str],
    has_ram_saturation: bool = False,
    footnote: str | None = None,
) -> None:
    width = 1280
    height = 760
    margin_left = 110
    margin_right = 220
    margin_top = 38
    margin_bottom = 170
    plot_width = width - margin_left - margin_right
    plot_height = height - margin_top - margin_bottom
    plot_x0 = margin_left
    plot_y0 = margin_top
    plot_x1 = plot_x0 + plot_width
    plot_y1 = plot_y0 + plot_height
    group_width = plot_width / len(categories)
    scenario_band = group_width * 0.72
    scenario_width = scenario_band / len(scenarios)
    pdf = PdfCanvas(width, height)

    lines = svg_header(width, height)
    for tick in y_ticks:
        y = plot_y1 - (tick / y_max) * plot_height
        lines.append(f'<line class="grid" x1="{plot_x0}" y1="{y:.2f}" x2="{plot_x1}" y2="{y:.2f}" />')
        lines.append(
            f'<text class="axis" x="{plot_x0 - 12}" y="{y + 4:.2f}" text-anchor="end">{escape(fmt_req_per_s(tick))}</text>'
        )
        pdf.line(plot_x0, y, plot_x1, y, color="#ececec", width=1)
        pdf.text(
            plot_x0 - 12,
            y + 4,
            fmt_req_per_s(tick),
            font_size=AXIS_FONT_SIZE,
            color="#444444",
            anchor="end",
        )

    lines.append(f'<line class="tick" x1="{plot_x0}" y1="{plot_y1}" x2="{plot_x1}" y2="{plot_y1}" />')
    lines.append(f'<line class="tick" x1="{plot_x0}" y1="{plot_y0}" x2="{plot_x0}" y2="{plot_y1}" />')
    lines.append(
        f'<text class="axis" x="28" y="{plot_y0 + plot_height / 2}" text-anchor="middle" dominant-baseline="middle" transform="rotate(-90 28 {plot_y0 + plot_height / 2})">{escape(ylabel)}</text>'
    )
    pdf.line(plot_x0, plot_y1, plot_x1, plot_y1, color="#c7c7c7", width=1)
    pdf.line(plot_x0, plot_y0, plot_x0, plot_y1, color="#c7c7c7", width=1)
    pdf.text(
        28,
        plot_y0 + plot_height / 2,
        ylabel,
        font_size=AXIS_FONT_SIZE,
        color="#444444",
        anchor="middle",
        rotate_deg=90,
        baseline="middle",
    )

    for cat_idx, category in enumerate(categories):
        gx = plot_x0 + cat_idx * group_width + (group_width - scenario_band) / 2
        lines.append(
            f'<text class="axis" x="{gx + scenario_band / 2:.2f}" y="{plot_y1 + 48}" text-anchor="middle">{escape(category)}</text>'
        )
        pdf.text(
            gx + scenario_band / 2,
            plot_y1 + 48,
            category,
            font_size=AXIS_FONT_SIZE,
            color="#444444",
            anchor="middle",
        )
        for scenario_idx, scenario in enumerate(scenarios):
            values = case_values.get((cat_idx, scenario_idx), [])
            center_x = gx + scenario_idx * scenario_width + scenario_width / 2
            lines.append(
                f'<line x1="{center_x:.2f}" y1="{plot_y1}" x2="{center_x:.2f}" y2="{plot_y1 + 8}" stroke="{SCENARIO_COLORS[scenario]}" stroke-width="2" />'
            )
            pdf.line(
                center_x,
                plot_y1,
                center_x,
                plot_y1 + 8,
                color=SCENARIO_COLORS[scenario],
                width=2,
            )
            if not values:
                continue
            sorted_values = sorted(values)
            for repeat_idx, value in enumerate(sorted_values):
                jitter = (repeat_idx - (len(sorted_values) - 1) / 2) * 7
                y = plot_y1 - (value / y_max) * plot_height
                lines.append(
                    f'<circle cx="{center_x + jitter:.2f}" cy="{y:.2f}" r="5.5" fill="{SCENARIO_COLORS[scenario]}" fill-opacity="0.85" />'
                )
                pdf.circle(
                    center_x + jitter,
                    y,
                    5.5,
                    fill=SCENARIO_COLORS[scenario],
                )
            median_value = sorted_values[len(sorted_values) // 2]
            y = plot_y1 - (median_value / y_max) * plot_height
            lines.append(
                f'<line x1="{center_x - 10:.2f}" y1="{y:.2f}" x2="{center_x + 10:.2f}" y2="{y:.2f}" stroke="#111" stroke-width="2" />'
            )
            pdf.line(center_x - 10, y, center_x + 10, y, color="#111111", width=2)

    add_legend(lines, plot_x1 + 32, plot_y0 + 20, scenarios, has_ram_saturation)
    for idx, scenario in enumerate(scenarios):
        yy = plot_y0 + 20 + idx * 22
        swatch_y = yy - LEGEND_SWATCH_HEIGHT / 2
        label = scenario_label(scenario, has_ram_saturation)
        pdf.rect(
            plot_x1 + 32,
            swatch_y,
            LEGEND_SWATCH_WIDTH,
            LEGEND_SWATCH_HEIGHT,
            fill=SCENARIO_COLORS[scenario],
        )
        if scenario in RAM_QLOG_SCENARIOS and has_ram_saturation:
            pdf.striped_rect(
                plot_x1 + 32,
                swatch_y,
                LEGEND_SWATCH_WIDTH,
                LEGEND_SWATCH_HEIGHT,
            )
        pdf.text(
            plot_x1 + 56,
            yy,
            label,
            font_size=LEGEND_FONT_SIZE,
            color="#333333",
            baseline="middle",
        )
    if footnote:
        lines.append(
            f'<text class="note" x="{plot_x0}" y="{height - 26}">{escape(footnote)}</text>'
        )
        pdf.text(plot_x0, height - 26, footnote, font_size=12, color="#555555")

    write_text(out_path, svg_footer(lines))
    pdf.save(out_path.with_suffix(".pdf"))


def scenario_saturation_by_workload(workload_rows: List[Dict[str, str]]) -> Dict[tuple, bool]:
    saturated: Dict[tuple, bool] = {}
    for row in workload_rows:
        saturated[(row["scenario"], row["workload"])] = row.get("qlog_ram_saturated") == "yes"
    return saturated


def any_ram_saturation(workload_rows: List[Dict[str, str]]) -> bool:
    return any(row.get("qlog_ram_saturated") == "yes" for row in workload_rows)


def category_rows(cell_rows: List[Dict[str, str]]) -> List[Dict[str, str]]:
    rows = sorted(
        cell_rows,
        key=lambda row: (
            workload_sort_key(row["workload"]),
            int(row["clients"]),
            scenario_sort_key(row["scenario"]),
        ),
    )
    seen = set()
    categories: List[Dict[str, str]] = []
    for row in rows:
        key = (row["workload"], row["path"], row["clients"], row["streams"])
        if key in seen:
            continue
        seen.add(key)
        categories.append(row)
    return categories


def build_normalized_grouped_values(
    cell_rows: List[Dict[str, str]],
    workload_rows: List[Dict[str, str]],
    metric_column: str,
    baseline: float = 100.0,
) -> tuple[List[str], List[List[SeriesValue]]]:
    saturation = scenario_saturation_by_workload(workload_rows)
    by_key = {
        (row["scenario"], row["workload"], row["path"], row["clients"], row["streams"]): row
        for row in cell_rows
    }
    categories = category_rows(cell_rows)
    labels: List[str] = []
    grouped_values: List[List[SeriesValue]] = []

    for category in categories:
        workload = category["workload"]
        path = category["path"]
        clients = category["clients"]
        streams = category["streams"]
        label = f'{WORKLOAD_SHORT[workload]} c{clients}'
        labels.append(label)

        series_values: List[SeriesValue] = []
        for scenario in SCENARIO_ORDER:
            row = by_key[(scenario, workload, path, clients, streams)]
            if scenario == BASELINE_SCENARIO:
                value = baseline
            else:
                delta = float(row[metric_column])
                value = baseline + delta
            series_values.append(
                SeriesValue(
                    scenario=scenario,
                    value=value,
                    saturated=saturation.get((scenario, workload), False),
                )
            )
        grouped_values.append(series_values)

    return labels, grouped_values


def build_bytes_per_request_values(
    workload_rows: List[Dict[str, str]]
) -> tuple[List[str], List[List[SeriesValue]]]:
    qlog_rows = [
        row
        for row in workload_rows
        if row["scenario"] in QLOG_PLOT_SCENARIOS
    ]
    labels = [WORKLOAD_LABELS[w] for w in WORKLOAD_ORDER]
    grouped_values: List[List[SeriesValue]] = []
    for workload in WORKLOAD_ORDER:
        series_values: List[SeriesValue] = []
        for scenario in QLOG_PLOT_SCENARIOS:
            values = [
                float(row["qlog_bytes_per_request"])
                for row in qlog_rows
                if row["workload"] == workload and row["scenario"] == scenario
            ]
            series_values.append(
                SeriesValue(
                    scenario=scenario,
                    value=float(median(values)),
                    saturated=any(
                        row.get("qlog_ram_saturated") == "yes"
                        for row in qlog_rows
                        if row["workload"] == workload and row["scenario"] == scenario
                    ),
                )
            )
        grouped_values.append(series_values)
    return labels, grouped_values


def build_total_qlog_bytes_values(
    workload_rows: List[Dict[str, str]]
) -> tuple[List[str], List[List[SeriesValue]]]:
    qlog_rows = [
        row
        for row in workload_rows
        if row["scenario"] in QLOG_PLOT_SCENARIOS
    ]
    labels = [WORKLOAD_LABELS[w] for w in WORKLOAD_ORDER]
    grouped_values: List[List[SeriesValue]] = []
    for workload in WORKLOAD_ORDER:
        series_values: List[SeriesValue] = []
        for scenario in QLOG_PLOT_SCENARIOS:
            values = [
                float(row["qlog_total_bytes"])
                for row in qlog_rows
                if row["workload"] == workload and row["scenario"] == scenario
            ]
            series_values.append(
                SeriesValue(
                    scenario=scenario,
                    value=float(median(values)),
                    saturated=any(
                        row.get("qlog_ram_saturated") == "yes"
                        for row in qlog_rows
                        if row["workload"] == workload and row["scenario"] == scenario
                    ),
                )
            )
        grouped_values.append(series_values)
    return labels, grouped_values


def build_absolute_metric_grouped_values(
    cell_rows: List[Dict[str, str]],
    workload_rows: List[Dict[str, str]],
    metric_column: str,
) -> tuple[List[str], List[List[SeriesValue]]]:
    saturation = scenario_saturation_by_workload(workload_rows)
    by_key = {
        (row["scenario"], row["workload"], row["path"], row["clients"], row["streams"]): row
        for row in cell_rows
    }
    categories = category_rows(cell_rows)
    labels: List[str] = []
    grouped_values: List[List[SeriesValue]] = []

    for category in categories:
        workload = category["workload"]
        path = category["path"]
        clients = category["clients"]
        streams = category["streams"]
        labels.append(f'{WORKLOAD_SHORT[workload]} c{clients}')

        series_values: List[SeriesValue] = []
        for scenario in SCENARIO_ORDER:
            row = by_key[(scenario, workload, path, clients, streams)]
            series_values.append(
                SeriesValue(
                    scenario=scenario,
                    value=float(row[metric_column]),
                    saturated=saturation.get((scenario, workload), False),
                )
            )
        grouped_values.append(series_values)

    return labels, grouped_values


def max_grouped_value(grouped_values: Sequence[Sequence[SeriesValue]]) -> float:
    return max(
        series.value
        for category_values in grouped_values
        for series in category_values
    )


def build_repeat_values(
    case_rows: List[Dict[str, str]]
) -> tuple[List[str], Dict[tuple, List[float]]]:
    categories: List[tuple] = []
    for workload in WORKLOAD_ORDER:
        for clients in ("20", "100"):
            if any(
                row["workload"] == workload and row["clients"] == clients
                for row in case_rows
            ):
                categories.append((workload, clients))

    labels = [f"{WORKLOAD_SHORT[w]} c{c}" for w, c in categories]
    values: Dict[tuple, List[float]] = {}
    for cat_idx, (workload, clients) in enumerate(categories):
        for scenario_idx, scenario in enumerate(SCENARIO_ORDER):
            points = [
                float(row["req_per_s"])
                for row in case_rows
                if row["workload"] == workload
                and row["clients"] == clients
                and row["scenario"] == scenario
            ]
            values[(cat_idx, scenario_idx)] = points
    return labels, values


def main() -> None:
    cell_rows = read_tsv(ANALYSIS_DIR / "client_cell_comparison.tsv")
    workload_rows = read_tsv(ANALYSIS_DIR / "workload_run_summary.tsv")
    case_rows = read_tsv(ANALYSIS_DIR / "client_case_summary.tsv")
    PLOTS_DIR.mkdir(parents=True, exist_ok=True)
    has_ram_saturation = any_ram_saturation(workload_rows)

    labels, grouped = build_normalized_grouped_values(
        cell_rows,
        workload_rows,
        metric_column="delta_req_per_s_vs_master_pct",
    )
    draw_grouped_bar_chart(
        PLOTS_DIR / "throughput_normalized.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="Throughput (% of master)",
        y_ticks=[0, 25, 50, 75, 100, 125],
        y_max=125,
        scenarios=SCENARIO_ORDER,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_percent,
    )

    labels, grouped = build_absolute_metric_grouped_values(
        cell_rows,
        workload_rows,
        metric_column="median_req_per_s",
    )
    y_ticks, y_max = build_axis_ticks(max_grouped_value(grouped))
    draw_grouped_bar_chart(
        PLOTS_DIR / "throughput_absolute.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="Throughput (req/s)",
        y_ticks=y_ticks,
        y_max=y_max,
        scenarios=SCENARIO_ORDER,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_req_per_s_scaled,
    )

    labels, grouped = build_normalized_grouped_values(
        cell_rows,
        workload_rows,
        metric_column="delta_request_p95_vs_master_pct",
    )
    draw_grouped_bar_chart(
        PLOTS_DIR / "latency_p95_normalized.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="p95 latency (% of master)",
        y_ticks=[0, 25, 50, 75, 100, 125, 150],
        y_max=150,
        scenarios=SCENARIO_ORDER,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_percent,
    )

    labels, grouped = build_absolute_metric_grouped_values(
        cell_rows,
        workload_rows,
        metric_column="median_request_p95_us",
    )
    y_ticks, y_max = build_axis_ticks(max_grouped_value(grouped))
    draw_grouped_bar_chart(
        PLOTS_DIR / "latency_p95_absolute.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="p95 latency (ms)",
        y_ticks=y_ticks,
        y_max=y_max,
        scenarios=SCENARIO_ORDER,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_milliseconds_from_us,
    )

    labels, grouped = build_normalized_grouped_values(
        cell_rows,
        workload_rows,
        metric_column="delta_server_cpu_busy_vs_master_pct",
    )
    draw_grouped_bar_chart(
        PLOTS_DIR / "cpu_busy_normalized.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="server CPU busy (% of master)",
        y_ticks=[0, 25, 50, 75, 100, 125, 150],
        y_max=150,
        scenarios=SCENARIO_ORDER,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_percent,
    )

    labels, grouped = build_absolute_metric_grouped_values(
        cell_rows,
        workload_rows,
        metric_column="median_server_cpu_busy_pct",
    )
    draw_grouped_bar_chart(
        PLOTS_DIR / "cpu_busy_absolute.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="server CPU busy (%)",
        y_ticks=[0, 20, 40, 60, 80, 100],
        y_max=100,
        scenarios=SCENARIO_ORDER,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_percent,
    )

    labels, grouped = build_normalized_grouped_values(
        cell_rows,
        workload_rows,
        metric_column="delta_server_cpu_busy_per_krps_vs_master_pct",
    )
    draw_grouped_bar_chart(
        PLOTS_DIR / "cpu_efficiency_normalized.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="CPU busy per 1000 req/s (% of master)",
        y_ticks=[0, 25, 50, 75, 100, 125, 150],
        y_max=150,
        scenarios=SCENARIO_ORDER,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_percent,
    )

    labels, grouped = build_absolute_metric_grouped_values(
        cell_rows,
        workload_rows,
        metric_column="median_server_cpu_busy_per_krps",
    )
    y_ticks, y_max = build_axis_ticks(max_grouped_value(grouped))
    draw_grouped_bar_chart(
        PLOTS_DIR / "cpu_efficiency_absolute.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="CPU busy per 1000 req/s",
        y_ticks=y_ticks,
        y_max=y_max,
        scenarios=SCENARIO_ORDER,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_number,
    )

    labels, grouped = build_bytes_per_request_values(workload_rows)
    draw_grouped_bar_chart(
        PLOTS_DIR / "qlog_bytes_per_request.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="qlog bytes per request",
        y_ticks=[0, 100_000, 200_000, 300_000, 400_000],
        y_max=400_000,
        scenarios=QLOG_PLOT_SCENARIOS,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_bytes_per_request,
    )

    labels, grouped = build_total_qlog_bytes_values(workload_rows)
    draw_grouped_bar_chart(
        PLOTS_DIR / "qlog_total_bytes.svg",
        categories=labels,
        grouped_values=grouped,
        ylabel="total qlog bytes",
        y_ticks=[0, 5_000_000_000, 10_000_000_000, 15_000_000_000, 20_000_000_000, 25_000_000_000],
        y_max=25_000_000_000,
        scenarios=QLOG_PLOT_SCENARIOS,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
        value_formatter=fmt_bytes,
    )

    labels, repeat_values = build_repeat_values(case_rows)
    draw_dot_plot(
        PLOTS_DIR / "throughput_repeats.svg",
        categories=labels,
        case_values=repeat_values,
        ylabel="req/s",
        y_ticks=[0, 10_000, 20_000, 30_000, 40_000, 50_000],
        y_max=55_000,
        scenarios=SCENARIO_ORDER,
        has_ram_saturation=has_ram_saturation,
        footnote=None,
    )

    index_lines = [
        "# Generated Plots",
        "",
        "- `throughput_normalized.{svg,pdf}`: grouped bar chart of median request rate normalized to `master`",
        "- `throughput_absolute.{svg,pdf}`: grouped bar chart of median absolute request rate",
        "- `latency_p95_normalized.{svg,pdf}`: grouped bar chart of median p95 latency normalized to `master`",
        "- `latency_p95_absolute.{svg,pdf}`: grouped bar chart of median absolute p95 latency",
        "- `cpu_busy_normalized.{svg,pdf}`: grouped bar chart of median server CPU busy normalized to `master`",
        "- `cpu_busy_absolute.{svg,pdf}`: grouped bar chart of median absolute server CPU busy percentage",
        "- `cpu_efficiency_normalized.{svg,pdf}`: grouped bar chart of median CPU busy per 1000 req/s normalized to `master`",
        "- `cpu_efficiency_absolute.{svg,pdf}`: grouped bar chart of median absolute CPU busy per 1000 req/s",
        "- `qlog_bytes_per_request.{svg,pdf}`: qlog volume per successful request for each qlog-writing scenario",
        "- `qlog_total_bytes.{svg,pdf}`: total qlog volume per workload run for each qlog-writing scenario",
        "- `throughput_repeats.{svg,pdf}`: repeat-level req/s scatter with median markers",
        "",
        "All plots are generated directly from the checked-in TSV summaries in `results/analysis`.",
        (
            "RAM-backed qlog series are annotated because tmpfs saturation occurred in at least one run."
            if has_ram_saturation
            else "No tmpfs saturation was detected in the current analysis set."
        ),
        "",
    ]
    write_text(PLOTS_DIR / "README.md", "\n".join(index_lines))
    print(f"Wrote plots to {display_path(PLOTS_DIR)}")


if __name__ == "__main__":
    main()
