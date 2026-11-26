#!/usr/bin/env python3
"""
Quick Raw Entropy Estimator (NIST SP 800-90B MCV Approximation)
Captures raw bytes from ESP8266 running raw_entropy_dump.ino and checks
if the hardware noise floor is sufficient for 16:1 SHA-256 conditioning.
"""

import sys
import math
from collections import Counter

try:
    import serial
except ImportError:
    print("Error: pyserial is required. Install via: pip install pyserial")
    sys.exit(1)

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
BYTES_TO_CAPTURE = int(sys.argv[2]) if len(sys.argv) > 2 else 50000
BAUD = 115200

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
    
    # For 16:1 compression (512 bytes -> 32 bytes), we need > 256 bits of min-entropy per 512 bytes
    # That equals >= 0.5000 bits/byte. We require >= 1.0000 for a 2x safety margin.
    if min_entropy >= 1.0:
        margin = min_entropy / 0.5
        print(f"VERDICT            : PASS (Safety margin: {margin:.2f}x)")
    elif min_entropy >= 0.5:
        print("VERDICT            : MARGINAL (Passes minimum 0.5, but low safety margin. Check LDO/power.)")
    else:
        print("VERDICT            : FAIL (Insufficient hardware entropy! Do NOT use this board.)")

def main():
    print(f"Connecting to {PORT} at {BAUD} baud...")
    with serial.Serial(PORT, BAUD, timeout=5) as ser:
        ser.reset_input_buffer()
        # Discard first 1024 bytes (cold start)
        ser.read(1024)
        print(f"Capturing {BYTES_TO_CAPTURE} raw bytes...")
        data = ser.read(BYTES_TO_CAPTURE)
        if len(data) < BYTES_TO_CAPTURE:
            print(f"Timeout: captured only {len(data)} bytes.")
            sys.exit(1)
    analyze(data)

if __name__ == "__main__":
    main()