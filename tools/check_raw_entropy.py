#!/usr/bin/env python3
"""
Quick Raw Entropy Estimator (NIST SP 800-90B MCV Approximation)
Captures raw bytes from ESP8266 running raw_entropy_dump.ino and checks
if the hardware noise floor is sufficient for 16:1 SHA-256 conditioning.
"""

import os
import sys
import math
import subprocess
from collections import Counter

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/trng_esp"
BYTES_TO_CAPTURE = int(sys.argv[2]) if len(sys.argv) > 2 else 50000
BAUD = "115200"


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
    print(f"NIST MCV Min-Entr. : {min_entropy:.4f} bits/byte (required >= 0.5000)")

    # 16:1 compression (512 bytes -> 32 bytes) requires >= 0.5000 bits/byte.
    # Require >= 1.0000 for at least a 2x safety margin.
    if min_entropy >= 1.0:
        margin = min_entropy / 0.5
        print(f"VERDICT            : PASS (Safety margin: {margin:.2f}x)")
    elif min_entropy >= 0.5:
        print("VERDICT            : MARGINAL (Passes minimum 0.5, low safety margin.)")
    else:
        print("VERDICT            : FAIL (Insufficient hardware entropy! Do NOT use this board.)")


def main():
    # Stop background feeder if running on OPNsense so it doesn't compete for UART
    subprocess.run(["configctl", "esp_trng", "stop"], capture_output=True)

    configure_uart_freebsd(PORT)
    print(f"Reading from {PORT} at {BAUD} baud...")

    try:
        with open(PORT, "rb", buffering=0) as f:
            # Discard first 1024 bytes (cold start & stale UART buffer)
            discarded = 0
            while discarded < 1024:
                chunk = f.read(1024 - discarded)
                if not chunk:
                    break
                discarded += len(chunk)

            print(f"Capturing {BYTES_TO_CAPTURE} raw bytes (~4 seconds)...")
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


if __name__ == "__main__":
    main()
