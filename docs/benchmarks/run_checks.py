#!/usr/bin/env python3
"""Mide el coste de las comprobaciones en ejecución con examples/benchmark_checks.fst.

Uso (desde la raíz del repositorio, con ./faset compilado):
    python3 docs/benchmarks/run_checks.py

Compila el ejemplo en cuatro configuraciones (Release/Debug, con y sin checks), ejecuta cada
binario 5 veces y guarda la mediana de cada medición en checks.json.
"""
import datetime
import json
import os
import statistics
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FASET = os.path.join(ROOT, "faset")
SRC = os.path.join(ROOT, "examples", "benchmark_checks.fst")
OUT = os.path.join(HERE, "build")
RUNS = 5

CONFIGS = [
    ("Release", "--no-checks", "Release sin checks"),
    ("Release", "--checks", "Release con checks"),
    ("Debug", "--no-checks", "Debug sin checks"),
    ("Debug", "--checks", "Debug con checks (por defecto)"),
]
ROWS = ["objetos", "listas", "cadenas", "total"]


def main():
    os.makedirs(OUT, exist_ok=True)
    results = {"date": datetime.date.today().isoformat(), "runs": RUNS, "rows": ROWS, "configs": []}
    for conf, flag, title in CONFIGS:
        exe = os.path.join(OUT, f"checks-{conf}{flag}")
        subprocess.run([FASET, "build", "-c", conf, flag, SRC, "-o", exe], check=True, capture_output=True)
        samples = {r: [] for r in ROWS}
        for _ in range(RUNS):
            out = subprocess.run([exe], check=True, capture_output=True, text=True).stdout
            for line in out.splitlines():
                if ":" in line and line.strip().endswith("ms"):
                    name, val = line.split(":", 1)
                    samples[name.strip()].append(int(val.strip().split()[0]))
        med = {r: statistics.median(v) for r, v in samples.items()}
        results["configs"].append({"title": title, "configuration": conf, "flag": flag, "ms": med})
        print(f"{title:32} " + "  ".join(f"{r}={med[r]:g}" for r in ROWS), flush=True)
    with open(os.path.join(HERE, "checks.json"), "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
