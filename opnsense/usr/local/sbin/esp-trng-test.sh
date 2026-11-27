#!/bin/sh

DEV="/dev/trng_esp"
BAUD="115200"
BYTES="${1:-2500}"
START_HOOK="/usr/local/etc/rc.syshook.d/start/90-esp-trng"
STOP_HOOK="/usr/local/etc/rc.syshook.d/stop/90-esp-trng"

if [ ! -c "$DEV" ]; then
    echo "Error: device $DEV not found!"
    exit 1
fi

restore_feeder() {
    exec 3<&- 2>/dev/null
    echo ""
    echo "[*] Restarting background esp-trng-feeder..."
    "$START_HOOK"
    sleep 2
    if [ -f /var/run/esp-trng-feeder.pid ]; then
        echo "[OK] Feeder running (PID: $(cat /var/run/esp-trng-feeder.pid))."
    else
        echo "[!] Warning: could not verify feeder PID."
    fi
}

trap 'restore_feeder; exit 130' INT TERM

echo "[*] Stopping background feeder..."
"$STOP_HOOK"
sleep 1

EST_SEC=$(( (BYTES + 36) / 37 ))
echo "[*] Configuring $DEV ($BAUD 8N1 raw) and capturing $BYTES bytes (~${EST_SEC} sec)..."
exec 3< "$DEV"
stty -f "$DEV" "$BAUD" raw cs8 -cstopb -parenb -crtscts -ixon -ixoff clocal

PYCODE='
import sys, time, math, os

target = int(os.environ.get("TARGET_BYTES", "2500"))
buf = bytearray()
t0 = time.monotonic()

f = sys.stdin.buffer
while len(buf) < target:
    chunk = f.read(min(32, target - len(buf)))
    if not chunk:
        break
    buf.extend(chunk)

elapsed = time.monotonic() - t0
n = len(buf)

if n < 64:
    print("Error: insufficient data read from UART.")
    sys.exit(1)

speed_B = n / elapsed
speed_b = speed_B * 8

counts = list(bytes(256))
for b in buf:
    counts[b] += 1

entropy = 0.0
unique_vals = 0
for c in counts:
    if c > 0:
        unique_vals += 1
        p = c / n
        entropy -= p * math.log2(p)

mean = sum(buf) / n

expected = n / 256.0
chi2 = sum(((c - expected) ** 2) / expected for c in counts)
df = 255.0
z = ((chi2 / df) ** (1.0 / 3.0) - (1.0 - 2.0 / (9.0 * df))) / math.sqrt(2.0 / (9.0 * df))
p_exceed = 0.5 * math.erfc(z / math.sqrt(2.0)) * 100.0

s_xy = 0.0
s_x = 0.0
s_x2 = 0.0
for i in range(n):
    x = buf[i]
    y = buf[(i + 1) % n]
    s_xy += x * y
    s_x += x
    s_x2 += x * x

denom = (n * s_x2 - s_x * s_x)
scc = ((n * s_xy - s_x * s_x) / denom) if denom != 0 else 0.0

pairs = n // 6
inside = 0
max_coord = (1 << 24) - 1
r2 = float(max_coord) ** 2
for i in range(pairs):
    off = i * 6
    x = (buf[off] << 16) | (buf[off + 1] << 8) | buf[off + 2]
    y = (buf[off + 3] << 16) | (buf[off + 4] << 8) | buf[off + 5]
    if (x * x + y * y) <= r2:
        inside += 1
pi_est = (4.0 * inside / pairs) if pairs > 0 else 0.0
pi_err = abs(pi_est - math.pi) / math.pi * 100.0

def run_fips_block(block):
    ones = sum(b.bit_count() if hasattr(int, "bit_count") else bin(b).count("1") for b in block)
    monobit_ok = (9725 < ones < 10275)

    nibbles = list(bytes(16))
    for b in block:
        nibbles[b >> 4] += 1
        nibbles[b & 0x0F] += 1
    poker_x = (16.0 / 5000.0) * sum(c * c for c in nibbles) - 5000.0
    poker_ok = (2.16 < poker_x < 46.17)

    runs0 = list(bytes(7))
    runs1 = list(bytes(7))
    first_byte = next(iter(block))
    cur_bit = (first_byte >> 7) & 1
    cur_len = 0
    max_run = 0

    for b in block:
        for shift in range(7, -1, -1):
            bit = (b >> shift) & 1
            if bit == cur_bit:
                cur_len += 1
            else:
                if cur_len > max_run:
                    max_run = cur_len
                idx = min(cur_len, 6)
                if cur_bit == 0:
                    runs0[idx] += 1
                else:
                    runs1[idx] += 1
                cur_bit = bit
                cur_len = 1

    if cur_len > max_run:
        max_run = cur_len
    if cur_bit == 0:
        runs0[min(cur_len, 6)] += 1
    else:
        runs1[min(cur_len, 6)] += 1

    long_run_ok = (max_run < 26)

    bounds = {
        1: (2315, 2685),
        2: (1114, 1386),
        3: (527, 723),
        4: (240, 384),
        5: (103, 209),
        6: (103, 209)
    }
    runs_ok = True
    for r_len, (low, high) in bounds.items():
        if not (low <= runs0[r_len] <= high and low <= runs1[r_len] <= high):
            runs_ok = False

    return monobit_ok, poker_ok, runs_ok, long_run_ok, ones, poker_x, max_run

fips_blocks = n // 2500
fips_passed = 0
f_mono = f_poker = f_runs = f_long = 0
last_ones = 0
last_px = 0.0
last_mrun = 0

for i in range(fips_blocks):
    blk = buf[i*2500 : (i+1)*2500]
    m_ok, p_ok, r_ok, l_ok, ones, px, mrun = run_fips_block(blk)
    if m_ok: f_mono += 1
    if p_ok: f_poker += 1
    if r_ok: f_runs += 1
    if l_ok: f_long += 1
    if m_ok and p_ok and r_ok and l_ok:
        fips_passed += 1
    last_ones, last_px, last_mrun = ones, px, mrun

print("\n========================================================")
print("        ESP8266 TRNG DIAGNOSTIC REPORT (OPNsense)       ")
print("========================================================")
print(f" Bytes captured      : {n} bytes in {elapsed:.2f} sec")
print(f" Throughput          : {speed_B:.2f} B/s ({speed_b:.1f} bit/s)")
print("--------------------------------------------------------")
print(" [ENT STATISTICAL SUITE]")
print(f" Shannon Entropy     : {entropy:.4f} bit/byte (ideal: 8.0000)")
print(f" Arithmetic Mean     : {mean:.2f} (ideal: 127.50)")
print(f" Chi-square (Chi2)   : {chi2:.2f} (p-value: {p_exceed:.2f}%, normal: 10-90%)")
print(f" Serial Correlation  : {scc:.5f} (ideal: 0.00000)")
print(f" Unique Byte Values  : {unique_vals} / 256")
if pairs > 0:
    print(f" Monte Carlo Pi      : {pi_est:.5f} (error: {pi_err:.2f}%)")
print("--------------------------------------------------------")
print(" [FIPS 140-2 SUITE (20,000-bit blocks)]")
if fips_blocks == 0:
    print(" Skipped (need at least 2500 bytes for 1 FIPS block)")
else:
    print(f" Blocks Passed       : {fips_passed} / {fips_blocks}")
    print(f"   1. Monobit Test   : {f_mono}/{fips_blocks} PASS (last: {last_ones} ones, norm: 9725-10275)")
    print(f"   2. Poker Test     : {f_poker}/{fips_blocks} PASS (last: {last_px:.2f}, norm: 2.16-46.17)")
    print(f"   3. Runs Test      : {f_runs}/{fips_blocks} PASS (bit sequences 1..6+)")
    print(f"   4. Long Run Test  : {f_long}/{fips_blocks} PASS (last max run: {last_mrun}, norm: <26)")
print("========================================================")
'

TARGET_BYTES="$BYTES" python3 -c "$PYCODE" <&3

restore_feeder
