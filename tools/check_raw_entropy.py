#!/usr/bin/env python3
"""
Quick Raw Entropy Estimator (NIST SP 800-90B MCV Approximation)
Captures raw bytes from ESP8266 running raw_entropy_dump.ino and checks
if the hardware noise floor is sufficient for 32:1 HMAC-SHA256 conditioning.
"""

import os
import sys
import math
import subprocess
from collections import Counter

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/trng_esp"
BYTES_TO_CAPTURE = int(sys.argv[2]) if len(sys.argv) > 2 else 50000
BAUD = "115200"

# 32:1 compression (1024 raw bytes -> 32 output bytes / 256 bits) requires >= 0.2500 bits/byte.
MIN_REQUIRED_ENTROPY = 0.2500
SAFE_MARGIN_ENTROPY = 0.5000


def configure_uart_freebsd(port: str):
    """Configure serial port to raw 115200 8N1 using native FreeBSD stty."""
    if not os.path.exists(port):
        print(f"Error: Device {port} not found.")
        sys.exit(1)

    # On FreeBSD, configuring the .init device ensures settings persist on open()
    real_path = os.path.realpath(port)
    init_dev = f"{real_path}.init"
    target = init_dev if os.path.exists(init_dev) else real_path

    cmd = ["stty", "-f", target, BAUD, "raw", "-echo", "-crtscts", "cs8", "-parenb", "-cstopb"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Warning: stty failed ({res.stderr.strip()}), proceeding anyway...")


def analyze(data: bytes):
    n = len(data)
    if n < 2:
        print("Error: Insufficient data captured for analysis.")
        sys.exit(1)

    counts = Counter(data)
    unique = len(counts)

    # 1. Shannon Entropy
    shannon = -sum((c / n) * math.log2(c / n) for c in counts.values())

    # 2. NIST SP 800-90B Most Common Value (MCV) Min-Entropy
    max_count = max(counts.values())
    p_hat = max_count / n
    # Upper bound of 99% confidence interval (z = 2.576)
    p_upper = min(1.0, p_hat + 2.576 * math.sqrt((p_hat * (1.0 - p_hat)) / (n - 1)))
    min_entropy = -math.log2(p_upper)

    # 3. Monobit bias
    ones = sum(bin(b).count("1") for b in data)
    bias = abs(0.5 - (ones / (n * 8))) * 100

    print(f"\n--- Raw Hardware Entropy Report ({n} bytes) ---")
    print(f"Unique byte values : {unique} / 256")
    print(f"Raw Bit Bias       : {bias:.2f}% (ideal: 0.00%)")
    print(f"Shannon Entropy    : {shannon:.4f} bits/byte")
    print(f"NIST MCV Min-Entr. : {min_entropy:.4f} bits/byte (required >= {MIN_REQUIRED_ENTROPY:.4f} for 32:1)")

    if min_entropy >= SAFE_MARGIN_ENTROPY:
        margin = min_entropy / MIN_REQUIRED_ENTROPY
        print(f"VERDICT            : PASS (Safety margin: {margin:.2f}x)")
    elif min_entropy >= MIN_REQUIRED_ENTROPY:
        print(f"VERDICT            : MARGINAL (Passes minimum {MIN_REQUIRED_ENTROPY:.4f}, low safety margin.)")
    else:
        print("VERDICT            : FAIL (Insufficient hardware entropy! Do NOT use this board.)")


def main():
    # Stop background feeder if running on OPNsense so it doesn't compete for UART
    subprocess.run(["configctl", "esp_trng", "stop"], capture_output=True)

    try:
        configure_uart_freebsd(PORT)
        print(f"Reading from {PORT} at {BAUD} baud...")

        with open(PORT, "rb", buffering=0) as f:
            # Discard first 1024 bytes (cold start & stale UART buffer)
            discarded = 0
            while discarded < 1024:
                chunk = f.read(1024 - discarded)
                if not chunk:
                    break
                discarded += len(chunk)

            est_sec = max(1, round(BYTES_TO_CAPTURE / 1200))
            print(f"Capturing {BYTES_TO_CAPTURE} raw bytes (~{est_sec} seconds)...")
            buf = bytearray()
            while len(buf) < BYTES_TO_CAPTURE:
                chunk = f.read(min(4096, BYTES_TO_CAPTURE - len(buf)))
                if not chunk:
                    print(f"\nError: Stream interrupted at {len(buf)} bytes.")
                    sys.exit(1)
                buf.extend(chunk)

        analyze(bytes(buf))
    except KeyboardInterrupt:
        print("\nAborted by user.")
        sys.exit(1)
    finally:
        subprocess.run(["configctl", "esp_trng", "start"], capture_output=True)


if __name__ == "__main__":
    main()
