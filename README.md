# ESP8266 Hardware Entropy Source (TRNG-Style) for OPNsense

> ⚠️ **Honest disclaimer:** This is a physically-derived entropy source with a carefully designed HMAC-SHA256 extractor — **not** a certified True Random Number Generator. Adding entropy to FreeBSD's **Fortuna** CSPRNG does **not** make it cryptographically stronger: on any modern OPNsense install, Fortuna is already securely seeded from OS-level sources. Use this project because it is instructive, fun, and produces verifiably high-quality bits — not because your firewall's security depends on it.

A standalone, zero-component **hardware entropy source** based on an ESP8266 microcontroller and a Silicon Labs CP2102 USB-to-UART bridge. The raw source is internal silicon voltage-regulator thermal noise (`ADC_MODE(ADC_VCC)`) mixed with CPU-cycle jitter; the raw stream is conditioned by an HMAC-SHA256 extractor against a hidden 256-bit state (32:1 compression) and then fed through a domain-separated HMAC-SHA256 PRF for forward secrecy. The conditioned output is streamed into FreeBSD **Fortuna** (`/dev/random`) on **OPNsense**.

Includes full service integration (`configd`, `devd`, `rc.syshook.d`), an automated health-check watchdog, a CLI diagnostic suite (`ENT` + `FIPS 140-2`), and a native **OPNsense Dashboard Widget** with zero-wear RAM (`/tmp`) telemetry.

![OPNsense Dashboard Widget](docs/widget-preview.png)

---

## Key Features

* **Zero External Components:** Uses internal silicon power supply thermal noise (`ADC_MODE(ADC_VCC)` / `ESP.getVcc()`) combined with CPU cycle jitter (`ESP.getCycleCount()`) and non-periodic delays (`10 + ((vcc ^ c1) & 0x1F)` µs). Pin `A0` (`TOUT`) is left floating.
* **Physical Data Diode (with firmware defense-in-depth):** The ESP8266 `RX` (`GPIO3`) line is physically disconnected from the adapter's `TXD` pin, and `GPIO3` is configured as `INPUT_PULLUP` right after `Serial.begin()`. **The security guarantee comes from the missing wire, not from the firmware** — if someone re-solders `TXD`, the pin becomes an active UART RX again. The `INPUT_PULLUP` is defense-in-depth against accidental noise, not a cryptographic boundary.
* **EMI Shielding & Low Power:** Wi-Fi is hard-disabled (`WIFI_OFF` + `forceSleepBegin()`, ~15–20 mA draw). All unused GPIOs are pulled up/down internally to eliminate floating-pin electromagnetic interference.
* **Real-Time Multi-Stage Health Check (scaled for 8192 raw bits per block):**
  1. *RCT (Repetition Count Test, SP 800-90B-inspired):* Rejects blocks containing a run of `>= 41` identical consecutive bits. Conservative assumption `H = 0.5 bit/sample`, false-positive rate `alpha = 2^-20`.
  2. *APT (Adaptive Proportion Test, SP 800-90B-inspired):* Non-overlapping `1024`-bit windows inside each block must contain between `224` and `800` ones (8 windows per 8192-bit block). Catches *local* bias that global monobit misses.
  3. *ADC Range Check:* Requires `(max_vcc - min_vcc) >= 4` LSB across the block (replaces the old `min_vcc != max_vcc`, which passed on a 1-LSB fluctuation).
  4. *Lag-1 & Lag-2 Pattern Lock:* Rejects stuck square waves (`101010...` and `11001100...`) — accepted band `1600..6592` matches (~20%–80%).
  5. *Monobit Bias Bounds:* Rejects blocks outside `2048..6144` ones per `8192` raw bits (25%–75%).
  6. *Cold-Start Discard:* Drops the very first block after power-on before emitting data.
* **Cryptographic Conditioning (HMAC-SHA256 Extractor + Domain-Separated PRF):** Each output block draws `1024 bytes` (`8192 bits`) of raw physical entropy and runs it through a keyed HMAC-SHA256 extractor against a 256-bit internal secret state (`state_key`), yielding `32:1` compression with an ~18x min-entropy safety margin. Output bytes are then derived through a separate HMAC-SHA256 PRF over a 64-bit monotonic frame counter with strict domain-separation tags (`_INIT`, `_STEP`, `_OUT`), providing **forward secrecy** — the emitted bytes never reveal the internal state, and previously emitted output remains unrecoverable after a state compromise. Raw entropy is wiped from RAM immediately after each state update.
* **Zero-Wear OPNsense Integration:** All 11 integration files live under `/usr/local/` (surviving reboots and firmware updates). Live telemetry is written strictly to `/tmp/esp_trng_stats.json` (RAM) to avoid SSD/flash wear.

---

## Hardware Wiring

Only **3 wires** are required between the ESP8266 module (ESP-12F / ESP-07 / ESP-01) and the CP2102 USB-UART adapter (`VID: 0x10c4`, `PID: 0xea60`):

| CP2102 Pin | ESP8266 Pin | Purpose |
| :--- | :--- | :--- |
| `3V3` | `VCC` / `3.3V` (+ `EN`/`CH_PD`) | 3.3V Power Supply |
| `GND` | `GND` (+ `GPIO15` on bare modules) | Common Ground |
| `RXD` | `TXD` (`GPIO1`) | Unidirectional Entropy Stream (`115200 8N1`) |
| `TXD` | *Not Connected* | **Data Diode** (isolated for security) |

> **Note:** Ensure `A0` (`TOUT`) has nothing connected to it, as `ADC_MODE(ADC_VCC)` measures internal supply voltage directly.

---

## Verified Entropy Benchmarks

### 1. Pre-Conditioning Raw Entropy (`NIST SP 800-90B`, 32,500 bytes)
* **NIST Min-Entropy (MCV):** `4.5420 bits/byte` (threshold for 32:1 compression: `>= 0.2500`, **18.17x safety margin**)
* **Raw Shannon Entropy:** `7.0369 bits/byte`
* **Raw Bit Bias:** `10.48%` (completely whitened by the SHA-256 extractor)
* **Unique Byte Values:** `256 / 256`

### 2. `FIPS 140-2` Statistical Suite (260,000 bits / 13 consecutive 20,000-bit blocks)
* **Overall Result:** `13 / 13` Blocks Passed (**100% PASS**)
* **Monobit Test:** `13/13 PASS` (last: `10037` ones; acceptable range: `9725–10275`)
* **Poker Test:** `13/13 PASS` (last: `19.10`; acceptable range: `2.16–46.17`)
* **Runs Test:** `13/13 PASS` (bit runs of length `1..6+` within bounds)
* **Long Run Test:** `13/13 PASS` (last max run: `15` bits; norm: `< 26`)

### 3. `ENT` Pseudorandom Sequence Test (32,500 bytes over 872.51 sec)
* **Throughput:** `37.25 B/s` (`298.0 bit/s`) — reflects 32:1 conditioning
* **Shannon Entropy:** `7.9941 bits/byte` (ideal: `8.0000`)
* **Arithmetic Mean:** `127.49` (ideal: `127.50`)
* **Chi-Square (χ²):** `261.76` (`p-value: 37.21%`, normal range: `10–90%`)
* **Serial Correlation Coefficient:** `0.00302` (ideal: `0.00000`)
* **Unique Byte Values:** `256 / 256`
* **Monte Carlo π Estimation:** `3.13442` (`0.23%` error)

Note: χ² p-values across repeated runs are consistent with the χ²(255) null distribution (mean z ≈ +0.2σ over 10 independent captures); the reference run above is representative, not cherry-picked.

---

## Pre-Deployment Hardware Verification (Recommended)

Verify raw physical entropy before cryptographic whitening, as hardware quality varies across ESP8266 modules (ESP-12F, ESP-07, ESP-01):

1. Flash `tools/raw_entropy_dump.ino` to the ESP8266 (this diagnostic sketch outputs raw ADC/jitter samples without SHA-256 conditioning).
2. Connect to OPNsense via SSH and run verification script:
   ```sh
   python3 tools/check_raw_entropy.py /dev/trng_esp 32500
   ```
   *(Use `/dev/cuaU0` if `install.sh` has not been run yet).*
3. Ensure NIST MCV Min-Entropy exceeds 0.2500 bits/byte for the 32:1 extractor (typically 3.5–5.0 bits/byte across modules; the reference board measured 4.5420).
4. Proceed to flash the production firmware (firmware/esp8266_trng/esp8266_trng.ino) and disconnect the TXD line.

---

## Installation

### Step 1: Flash the ESP8266
1. Open `firmware/esp8266_trng/esp8266_trng.ino` in **Arduino IDE** or **PlatformIO** (requires `ESP8266 Core 3.1.2+`).
2. Select your board (`Generic ESP8266 Module`), CPU Frequency: `80 MHz`, Flash Mode: `DOUT` (or matching your module).
3. Flash the firmware, then permanently disconnect the `TXD` wire from the CP2102 adapter.

### Step 2: Install on OPNsense
Connect the CP2102 adapter to your OPNsense router, log in via SSH as `root`, and run:

```sh
git clone https://github.com/Vladimir7xr/opnsense-esp8266-trng
cd opnsense-esp8266-trng
chmod +x install.sh uninstall.sh
./install.sh
```

After installation:
1. **Log out and log back in** to the OPNsense Web GUI to refresh ACL permissions (for non-root users, grant `Dashboard: ESP8266 Hardware TRNG` under *System → Access → Users/Groups*).
2. Go to **Lobby → Dashboard**, click **Add widget (+)**, and select **ESP8266 Hardware TRNG**.

---

## CLI Monitoring & Diagnostics

Run the built-in diagnostic tool to temporarily pause the background feeder, capture raw bytes over `/dev/trng_esp`, run `ENT` + `FIPS 140-2` validation, and automatically resume feeding:

```sh
# Quick test: 1 FIPS 140-2 block (2,500 bytes / ~70 sec)
esp-trng-test.sh

# Extended test: 4 FIPS 140-2 blocks (10,000 bytes / ~4.5 min)
esp-trng-test.sh 10000

# Full reference run: 32,500 bytes / ~14.5 min (produces the benchmark above)
esp-trng-test.sh 32500
```

Other useful commands:
```sh
# Check live RAM telemetry JSON
cat /tmp/esp_trng_stats.json

# Check service status via configd
configctl esp_trng status

# Inspect FreeBSD Fortuna RNG state
sysctl kern.random

# View watchdog events in system log
grep esp-trng /var/log/system/latest.log
```

## Limitations & Threat Model

This project is honest about what it is and is not. Read this before deploying.

**What this project does NOT do**

* **It does not strengthen Fortuna.** FreeBSD's Fortuna CSPRNG is already securely seeded from OS-level sources on any modern OPNsense install (interrupt timing, `RDRAND`/`RDSEED` if the CPU has it, etc.). Adding a supplementary entropy source does **not** make an already-seeded CSPRNG cryptographically stronger — that is not how CSPRNGs work. The practical benefit is marginal, and only in degraded environments where OS-level entropy is unusually poor.
* **It is not a certified TRNG.** The output is *physically-derived and cryptographically conditioned*, but the physical source (ESP8266 Vcc noise sampled by an on-die ADC) has not been characterized to NIST SP 800-90B standards. The extractor provides the security, not the "trueness" of the source.
* **It does not protect against physical adversaries.** Anyone with physical access to the ESP8266 can influence its power supply, temperature, or EM environment, and thereby bias the raw stream. The HMAC extractor (with ~18x min-entropy margin) absorbs this, but only up to the assumed min-entropy per block.

**What the security actually rests on**

1. **The HMAC-SHA256 extractor and hidden 256-bit state** — this is the real cryptographic boundary. As long as the raw block contains more than 256 bits of min-entropy *from the attacker's point of view*, the output is a PRF output keyed by a secret state, and remains indistinguishable from random.
2. **The physical Data Diode (missing `TXD` wire)** — this is what prevents the host from injecting data or reflashing the ESP8266. The firmware's `INPUT_PULLUP` on `GPIO3` is defense-in-depth, not a guarantee. If someone restores the wire, the diode is gone.
3. **Forward secrecy of the state** — the output is derived via a domain-separated HMAC PRF over the state key, so emitted bytes never reveal the state, and compromising the state does not reveal past output.

**Threat model**

| Adversary | Covered? | Notes |
| :--- | :--- | :--- |
| Remote network attacker | ✅ N/A | Device is not network-connected (Wi-Fi disabled). |
| Malicious host software injecting via UART | ✅ Yes | Physical `TXD` wire missing; `GPIO3` pulled up. |
| Attacker with physical access to the ESP8266 | ❌ No | Can bias the raw source; extractor absorbs up to its margin. |
| Compromised CP2102 bridge | ❌ No | The CP2102 is on the host side and is trusted implicitly. |
| Compromised OPNsense host | ❌ No | If the host is compromised, entropy quality is the least of your problems. |
| Weak OS-level entropy on the host | ⚠️ Marginal | This is the only scenario where this project helps — and even then, only slightly. |

**Bottom line:** Use this project because it is a well-engineered, cryptographically correct educational build that produces verifiably high-quality bits. Do not deploy it expecting a security improvement to your firewall. If you want stronger entropy on OPNsense, ensure your CPU's hardware RNG (`RDRAND`/`RDSEED`) is enabled and trusted first.

---

## License

MIT License — see [LICENSE](LICENSE) for details.
