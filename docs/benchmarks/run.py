#!/usr/bin/env python3
"""Mide Faset frente a C, Python y Node y escribe results.json.

Uso (desde la raíz del repositorio, con ./faset ya compilado):
    python3 docs/benchmarks/run.py

Metodología:
  * Faset: `faset build -c Release` (C11 generado + cc -O2).
  * C:     `gcc -O2` sobre el mismo algoritmo escrito a mano.
  * Python / Node: el intérprete del sistema, sin flags.
  * Cada programa se ejecuta varias veces; se publica la mediana del tiempo de pared.
  * Antes de medir se comprueba que todas las versiones imprimen lo mismo.
"""
import datetime
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(HERE, "src")
OUT = os.path.join(HERE, "build")
FASET = os.path.join(ROOT, "faset")
NODE = shutil.which("node") or os.path.expanduser("~/.local/node/bin/node")
PYTHON = shutil.which("python3")


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def timed(cmd, runs, cwd=None):
    times, out = [], None
    for _ in range(runs):
        t0 = time.perf_counter()
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
        times.append(time.perf_counter() - t0)
        if r.returncode != 0:
            raise RuntimeError(f"{cmd} falló: {r.stderr}")
        out = r.stdout
    return statistics.median(times), out


def first_line(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
        return (r.stdout or r.stderr).strip().splitlines()[0]
    except Exception:
        return None


def cpu_name():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor()


def mem_gb():
    try:
        with open("/proc/meminfo") as f:
            kb = int(f.readline().split()[1])
        return round(kb / 1024 / 1024)
    except OSError:
        return None


def os_name():
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.system()


def main():
    os.makedirs(OUT, exist_ok=True)
    results = {
        "date": datetime.date.today().isoformat(),
        "machine": {
            "cpu": cpu_name(),
            "cores": os.cpu_count(),
            "memoryGB": mem_gb(),
            "os": os_name(),
            "kernel": platform.release(),
            "gcc": first_line(["gcc", "--version"]),
            "python": first_line([PYTHON, "--version"]) if PYTHON else None,
            "node": first_line([NODE, "--version"]) if NODE else None,
            "faset": first_line([FASET, "version"]),
        },
        "cpu": [],
        "build": [],
        "startup": [],
    }

    # ------------------------------------------------------------- CPU
    benches = [
        ("fib", "Fibonacci recursivo (fib 37)", 10, 3),
        ("sieve", "Criba de Eratóstenes (20 M)", 10, 3),
        ("nbody", "N-body, 2 M pasos", 10, 3),
    ]
    for name, title, runs, slow_runs in benches:
        fexe = os.path.join(OUT, name + "-faset")
        cexe = os.path.join(OUT, name + "-c")
        sh([FASET, "build", "-c", "Release", os.path.join(SRC, name + ".fst"), "-o", fexe])
        sh(["gcc", "-O2", "-o", cexe, os.path.join(SRC, name + ".c"), "-lm"])
        langs = [("Faset", [fexe], runs), ("C (gcc -O2)", [cexe], runs)]
        if NODE:
            langs.append(("Node.js", [NODE, os.path.join(SRC, name + ".js")], slow_runs))
        if PYTHON:
            langs.append(("Python", [PYTHON, os.path.join(SRC, name + ".py")], slow_runs))
        entry = {"id": name, "title": title, "results": []}
        reference = None
        for lang, cmd, n in langs:
            t, out = timed(cmd, n)
            # Comparación del resultado (los flotantes se comparan con 9 cifras).
            norm = []
            for tok in out.split():
                try:
                    norm.append(f"{float(tok):.9g}")
                except ValueError:
                    norm.append(tok)
            if reference is None:
                reference = norm
            elif norm != reference:
                raise RuntimeError(f"{name}: {lang} imprime {norm}, se esperaba {reference}")
            entry["results"].append({"lang": lang, "seconds": round(t, 4), "runs": n})
            print(f"{name:6} {lang:12} {t:8.3f} s  (mediana de {n})", flush=True)
        entry["output"] = " ".join(reference)
        results["cpu"].append(entry)

    # ------------------------------------------------------------- compilación y tamaño
    projects = [
        ("Consola (faset new)", os.path.join(HERE, "..", "samples", "Consola"), 5),
        ("AppUI con std.ui (faset new --ui)", os.path.join(HERE, "..", "samples", "HolaUI"), 5),
        ("FasetStudio (el IDE completo)", os.path.join(ROOT, "studio"), 3),
    ]
    for title, path, n in projects:
        path = os.path.abspath(path)
        exe = os.path.join(OUT, "proj-" + os.path.basename(path))
        t, _ = timed([FASET, "build", "-c", "Release", path, "-o", exe], n)
        lines = 0
        for dirpath, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs if d not in ("bin", "obj", "pruebas")]
            for f in files:
                if f.endswith(".fst") or f.endswith(".fstui"):
                    with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                        lines += sum(1 for _ in fh)
        results["build"].append({
            "title": title,
            "seconds": round(t, 3),
            "runs": n,
            "bytes": os.path.getsize(exe),
            "lines": lines,
        })
        print(f"build  {title:36} {t:6.2f} s  {os.path.getsize(exe)} bytes  {lines} líneas", flush=True)

    # ------------------------------------------------------------- arranque
    fhello = os.path.join(OUT, "hello-faset")
    chello = os.path.join(OUT, "hello-c")
    sh([FASET, "build", "-c", "Release", os.path.join(SRC, "hello.fst"), "-o", fhello])
    sh(["gcc", "-O2", "-o", chello, os.path.join(SRC, "hello.c")])
    for lang, cmd, exe in [("Faset", [fhello], fhello), ("C (gcc -O2)", [chello], chello)]:
        n = 200
        t0 = time.perf_counter()
        for _ in range(n):
            subprocess.run(cmd, stdout=subprocess.DEVNULL, check=True)
        avg = (time.perf_counter() - t0) / n
        results["startup"].append({"lang": lang, "ms": round(avg * 1000, 3), "runs": n, "bytes": os.path.getsize(exe)})
        print(f"start  {lang:12} {avg * 1000:6.3f} ms  {os.path.getsize(exe)} bytes", flush=True)

    with open(os.path.join(HERE, "results.json"), "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("Escrito", os.path.join(HERE, "results.json"))


if __name__ == "__main__":
    sys.exit(main())
