#!/bin/bash
# power-report.sh — Raspberry Pi power / thermal report (vcgencmd + PMIC ADC + sysfs).
# Read-only: decodes get_throttled, lists the SoC voltage rails with their sum, reads
# the PMIC ADC (Pi 5: every rail's volts and amps, the 5 V input, computed watts), the
# USB-PD supply contract the firmware negotiated, the temperatures, and closes with a
# power summary, an hourly / daily / monthly / yearly energy forecast, and a one-line
# "trend" record for averaging over time. Changes nothing.
# Paired with power-report.timer (see etc/systemd/system/): hourly runs append to the log.
#
# Usage:
#   ./power-report.sh                 # DEFAULT: throttle flags, SoC rails + sum, 5 V input, temps, forecast
#   ./power-report.sh --full          # + every PMIC rail with watts, USB-PD PDOs, RP1 ADC raw
#   ./power-report.sh --samples 30    # average the PMIC power over 30 one-second reads before forecasting
#   ./power-report.sh --rate 0.17     # add cost lines at 0.17 per kWh (your tariff, any currency)
#   ./power-report.sh --wall 4.2      # forecast from a plug-meter reading in watts instead of the estimate
#   ./power-report.sh --help
#
# Log: /var/log/power-report.log (self-rotates at 512 KiB, one previous generation kept;
#      journald holds the primary copy via the service unit). Runs by a user who cannot
#      write /var/log print to the terminal only. Weekly average from the trend lines:
#        grep '^trend ' /var/log/power-report.log | awk '{for(i=2;i<=NF;i++){split($i,kv,"="); if(kv[1]=="rail_w") s+=kv[2]; if(kv[1]=="est_w") e+=kv[2]}; n++} END{printf "runs=%d avg rail=%.3f W avg est=%.3f W  => %.2f kWh/yr\n", n, s/n, e/n, e/n*8.76}'
#
# Needs: vcgencmd (libraspberrypi-bin) and membership of group video, or sudo.
# Pi 4 and earlier have no PMIC ADC; those sections and the forecast are skipped with a note.
# Installed by the build (layer/ke-20-avhicfg.yaml, same hook shape as dns-health-check).
# To try a newer copy on a running appliance before rebuilding:
#   sudo cp home/scripts/monitoring/power-report.sh /usr/local/bin/ && sudo chmod 0755 /usr/local/bin/power-report.sh
#   sudo cp etc/systemd/system/power-report.{service,timer} /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now power-report.timer
#
# Rail sum: the four measure_volts rails are independent supplies, so their sum is a
# checksum for diffing two runs, not a physical total. Real board power comes from the
# PMIC section (volts × amps per rail).
# Forecast basis: the PMIC only meters its own output rails. The board's 5 V input has no
# current sense, so "estimated input" = rail power / 0.85 (typical buck efficiency) and
# still omits the fan, NVMe/PCIe, and USB devices. Treat it as a floor; a plug meter
# (--wall) is the real number. One sample is a snapshot: use --samples for a steadier basis.

set -euo pipefail

FULL=0; SAMPLES=1; RATE=""; WALL=""; EFFICIENCY=0.85
is_num() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
while (( $# )); do
    case "$1" in
        -f|--full|full)   FULL=1 ;;
        -s|--samples)     SAMPLES=${2:-}; shift
                          [[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]] || { echo "power-report.sh: --samples needs a positive integer" >&2; exit 2; } ;;
        -r|--rate)        RATE=${2:-}; shift
                          is_num "$RATE" || { echo "power-report.sh: --rate needs a number (cost per kWh)" >&2; exit 2; } ;;
        -w|--wall)        WALL=${2:-}; shift
                          is_num "$WALL" || { echo "power-report.sh: --wall needs a number (watts from a plug meter)" >&2; exit 2; } ;;
        -h|--help)
            sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "power-report.sh: unknown argument '$1' (see --help)" >&2
            exit 2 ;;
    esac
    shift
done

if ! command -v vcgencmd >/dev/null 2>&1; then
    echo "power-report.sh: vcgencmd not found (package: libraspberrypi-bin)" >&2
    exit 1
fi

LOG_FILE="/var/log/power-report.log"
# Self-rotate: cap the local copy (journald holds the primary via the service unit).
LOG_MAX_BYTES=524288   # 512 KiB (~10 days of hourly default reports), then keep one previous generation
if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) >= LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
fi
# Manual runs without write access to /var/log go to the terminal only.
if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then
    echo "power-report.sh: $LOG_FILE not writable, output to terminal only" >&2
    LOG_FILE=/dev/null
fi
TS=$(date '+%Y-%m-%d %H:%M:%S')

emit() { echo "$*" | tee -a "$LOG_FILE" >/dev/null; echo "$*"; }
section() { emit; emit "--- $* ---"; }

# vcgencmd wrapper: prints "n/a" instead of aborting under set -e when a sub-command is
# unsupported (older firmware, Pi 4) or the caller lacks group video.
vc() { vcgencmd "$@" 2>/dev/null || echo "n/a"; }
# Big-endian u32 cells from a device-tree property, space separated.
dt_u32() { od -An -tu4 --endian=big "$1" 2>/dev/null | tr -s ' \n' ' '; }
# stdin: a pmic_read_adc dump -> "<sum of volts×amps over paired rails> <EXT5V volts>"
pmic_totals() {
    awk '{
            name = $1; split($2, kv, "="); val = kv[2]; sub(/[AV]$/, "", val)
            rail = name; sub(/_[AV]$/, "", rail)
            if (name ~ /_V$/) volt[rail] = val; else if (name ~ /_A$/) amp[rail] = val
         }
         END { t = 0; for (r in amp) if (r in volt) t += volt[r] * amp[r]
               printf "%.4f %.4f\n", t, volt["EXT5V"] + 0 }'
}
milli_c() { printf '%d.%d' $(( $1 / 1000 )) $(( $1 % 1000 / 100 )); }

# Readings taken once in the main shell so every section (they run in tee pipelines) shares them.
MODEL=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "unknown model")
RAW=$(vc get_throttled)
ARM=$(vc measure_clock arm)                       # frequency(0)=2400030464
ARM_MHZ=""; [[ "$ARM" == frequency* ]] && ARM_MHZ=$(( ${ARM#*=} / 1000000 ))
SOC_TEMP=$(vc measure_temp)                       # temp=48.8'C
PMIC=$(vc pmic_read_adc)
RAIL_W=""; EXT5V=""
if [[ "$PMIC" != "n/a" && -n "$PMIC" ]]; then
    read -r RAIL_W EXT5V < <(pmic_totals <<<"$PMIC")
fi

# ---------------------------------------------------------------- throttle flags
report_throttled() {
    if [[ "$RAW" == throttled=0x* ]]; then
        local status=$(( ${RAW#throttled=} ))
        printf '  %s  %s\n' "$RAW" "$( ((status)) && echo '!! flags set' || echo '(clean: nothing since boot)' )"
        # bit,description — https://www.raspberrypi.com/documentation/computers/os.html#get_throttled
        while IFS=, read -r BIT DESC; do
            if (( status & (1 << BIT) )); then printf '    bit %2d  %s\n' "$BIT" "$DESC"; fi
        done <<'EOF'
0,currently under-voltage
1,ARM frequency currently capped
2,currently throttled
3,soft temperature limit reached
16,under-voltage has occurred since last reboot
17,ARM frequency capping has occurred since last reboot
18,throttling has occurred since last reboot
19,soft temperature reached since last reboot
EOF
    else
        echo "  $RAW  (vcgencmd needs group video or sudo)"
    fi
    [[ -n "$ARM_MHZ" ]] && printf '  ARM clock now: %d MHz\n' "$ARM_MHZ"
    return 0
}

# ---------------------------------------------------------------- SoC rails
report_rails() {
    local sum=0 rail v num
    for rail in core sdram_c sdram_i sdram_p; do
        v=$(vc measure_volts "$rail")             # volt=0.8769V
        printf '  %9s  %s\n' "$rail" "$v"
        num=${v#volt=}; num=${num%V}
        if [[ "$num" =~ ^[0-9.]+$ ]]; then
            sum=$(awk -v a="$sum" -v b="$num" 'BEGIN { printf "%.4f", a + b }')
        fi
    done
    printf '  %9s  volt=%sV   (checksum of the four rails above, for diffing runs)\n' "sum" "$sum"
    printf '  %9s  %s   (core rail via the ARM-side uncached read)\n' "uncached" "$(vc measure_volts uncached)"
}

# ---------------------------------------------------------------- PMIC ADC (Pi 5)
report_pmic() {
    if [[ -z "$RAIL_W" ]]; then
        echo "  pmic_read_adc unsupported on this board or firmware — skipped"
        return 0
    fi
    # The 5 V input is the value that trips the under-voltage flag (documented threshold 4.63 V).
    if [[ "$EXT5V" != "0.0000" ]]; then
        awk -v v="$EXT5V" 'BEGIN {
            if (v < 4.63)      s = "!! below the 4.63 V under-voltage threshold"
            else if (v < 4.80) s = "marginal (threshold 4.63 V)"
            else               s = "ok (threshold 4.63 V)"
            printf "  EXT5V_V (5 V input)  = %.3f V  %s\n", v, s }'
    fi
    # Pair each <RAIL>_V with its <RAIL>_A, compute watts, total the board.
    awk -v full="$FULL" '
        {
            name = $1; split($2, kv, "="); val = kv[2]; sub(/[AV]$/, "", val)
            rail = name; sub(/_[AV]$/, "", rail)
            if (name ~ /_V$/) volt[rail] = val; else if (name ~ /_A$/) amp[rail] = val
            if (!(rail in seen)) { seen[rail] = 1; order[++n] = rail }
        }
        END {
            total = 0
            if (full) printf "  %-12s %9s %9s %9s\n", "rail", "volts", "amps", "watts"
            for (i = 1; i <= n; i++) {
                r = order[i]
                if ((r in volt) && (r in amp)) {
                    w = volt[r] * amp[r]; total += w
                    if (full) printf "  %-12s %9.4f %9.4f %9.4f\n", r, volt[r], amp[r], w
                } else if (full) {
                    printf "  %-12s %9s %9s %9s\n", r,
                           (r in volt ? sprintf("%.4f", volt[r]) : "-"),
                           (r in amp  ? sprintf("%.4f", amp[r])  : "-"), "-"
                }
            }
            printf "  PMIC rail power total = %.3f W  (SoC/RAM/IO rails only: excludes USB, PCIe/NVMe, fan, PMIC losses)\n", total
            if (!full) print "  (--full lists every rail with volts / amps / watts)"
        }' <<<"$PMIC"
}

# ---------------------------------------------------------------- supply contract
report_supply() {
    local pwr=/proc/device-tree/chosen/power maxc note k pdo mv ma
    if [[ ! -d "$pwr" ]]; then
        echo "  no chosen/power node (pre-Pi 5 firmware) — skipped"
        return 0
    fi
    maxc=$(dt_u32 "$pwr/max_current"); maxc=${maxc// /}
    if [[ "${maxc:-0}" -ge 5000 ]]; then
        note="5 A supply recognised: full USB current and PCIe budget"
    else
        note="below 5 A: firmware caps USB at 600 mA total unless usb_max_current_enable=1"
    fi
    printf '  %-26s= %s mA  (%s)\n' "max_current" "${maxc:-?}" "$note"
    for k in usb_max_current_enable usb_over_current_detected sd_overcurrent power_reset; do
        [[ -f "$pwr/$k" ]] && printf '  %-26s= %s\n' "$k" "$(dt_u32 "$pwr/$k" | tr -d ' ')"
    done
    if (( FULL )) && [[ -f "$pwr/usbpd_power_data_objects" ]]; then
        echo "  USB-PD source capabilities advertised by the supply:"
        for pdo in $(dt_u32 "$pwr/usbpd_power_data_objects"); do
            (( pdo == 0 )) && continue
            case $(( (pdo >> 30) & 3 )) in
                0)  mv=$(( ((pdo >> 10) & 0x3ff) * 50 )); ma=$(( (pdo & 0x3ff) * 10 ))
                    printf '    fixed     %2d.%02d V @ %d.%02d A%s\n' \
                        $(( mv / 1000 )) $(( mv % 1000 / 10 )) $(( ma / 1000 )) $(( ma % 1000 / 10 )) \
                        "$( (( pdo & (1 << 27) )) && echo '  (unconstrained power)' )" ;;
                1)  printf '    battery   0x%08x\n' "$pdo" ;;
                2)  printf '    variable  0x%08x\n' "$pdo" ;;
                3)  printf '    PPS/APDO  0x%08x\n' "$pdo" ;;
            esac
        done
    elif [[ -f "$pwr/usbpd_power_data_objects" ]]; then
        echo "  (--full decodes the USB-PD power data objects)"
    fi
    return 0
}

# ---------------------------------------------------------------- kernel view
report_kernel() {
    local h name a t p r f cd
    printf '  %-11s %s\n' "SoC"  "$SOC_TEMP"
    printf '  %-11s %s\n' "PMIC" "$(vc measure_temp pmic)"
    for h in /sys/class/hwmon/hwmon*; do
        [[ -r "$h/name" ]] || continue
        name=$(<"$h/name")
        case "$name" in
            rpi_volt)
                a=$(cat "$h/in0_lcrit_alarm" 2>/dev/null || echo "?")
                printf '  %-11s in0_lcrit_alarm=%s  (%s)\n' "$name" "$a" \
                    "$( [[ "$a" == 0 ]] && echo 'kernel sees no under-voltage now' || echo '!! kernel under-voltage alarm' )" ;;
            nvme)
                t=$(cat "$h/temp1_input" 2>/dev/null || echo "")
                [[ -n "$t" ]] && printf "  %-11s temp=%s'C\n" "$name" "$(milli_c "$t")" ;;
            pwmfan)
                p=$(cat "$h/pwm1" 2>/dev/null || echo "")
                r=$(cat "$h/fan1_input" 2>/dev/null || echo "")
                printf '  %-11s pwm1=%s/255%s\n' "$name" "${p:-?}" "${r:+  rpm=$r}" ;;
            rp1_adc)
                if (( FULL )); then
                    t=$(cat "$h/temp1_input" 2>/dev/null || echo "")
                    [[ -n "$t" ]] && printf "  %-11s temp=%s'C  (RP1 die)\n" "$name" "$(milli_c "$t")"
                    for f in "$h"/in[0-9]_input; do
                        [[ -r "$f" ]] || continue
                        printf '  %-11s %s=%s mV  (RP1 internal ADC channel, raw)\n' "" "$(basename "$f" _input)" "$(<"$f")"
                    done
                fi ;;
        esac
    done
    for cd in /sys/class/thermal/cooling_device*; do
        [[ -r "$cd/type" && -r "$cd/cur_state" ]] || continue
        printf '  %-11s %s state %s/%s\n' "cooling" "$(<"$cd/type")" "$(<"$cd/cur_state")" "$(<"$cd/max_state")"
    done
    return 0
}

# ---------------------------------------------------------------- summary + forecast
report_summary() {
    local rail_w=$RAIL_W ext5v=$EXT5V est_w="" basis_w="" basis="" sum_w sum_v min_w max_w w v i
    if [[ -z "$rail_w" ]]; then
        echo "  no PMIC ADC on this board: nothing to forecast from (use --wall <watts> with a plug meter)"
    elif (( SAMPLES > 1 )); then
        # Average further one-second reads so the forecast rests on more than one instant.
        sum_w=$rail_w; sum_v=$ext5v; min_w=$rail_w; max_w=$rail_w
        for (( i = 2; i <= SAMPLES; i++ )); do
            sleep 1
            read -r w v < <(vc pmic_read_adc | pmic_totals)
            sum_w=$(awk -v a="$sum_w" -v b="$w" 'BEGIN { printf "%.4f", a + b }')
            sum_v=$(awk -v a="$sum_v" -v b="$v" 'BEGIN { printf "%.4f", a + b }')
            min_w=$(awk -v a="$min_w" -v b="$w" 'BEGIN { print (b < a ? b : a) }')
            max_w=$(awk -v a="$max_w" -v b="$w" 'BEGIN { print (b > a ? b : a) }')
        done
        rail_w=$(awk -v s="$sum_w" -v n="$SAMPLES" 'BEGIN { printf "%.4f", s / n }')
        ext5v=$(awk -v s="$sum_v" -v n="$SAMPLES" 'BEGIN { printf "%.4f", s / n }')
        printf '  sampling              %d reads over %d s: PMIC rail power min %.3f W, max %.3f W\n' "$SAMPLES" "$((SAMPLES - 1))" "$min_w" "$max_w"
    fi
    if [[ -n "$rail_w" ]]; then
        est_w=$(awk -v w="$rail_w" -v e="$EFFICIENCY" 'BEGIN { printf "%.3f", w / e }')
        printf '  5 V input             %.3f V\n' "$ext5v"
        printf '  PMIC rail power       %.3f W   measured (SoC / RAM / IO rails)\n' "$rail_w"
        printf '  estimated board input %.3f W   rail power / %s buck efficiency; excludes fan, NVMe, USB (floor)\n' "$est_w" "$EFFICIENCY"
    fi
    if [[ -n "$WALL" ]]; then
        basis_w=$WALL; basis="plug meter, --wall"
        printf '  wall (plug meter)     %.3f W   supplied via --wall\n' "$WALL"
    elif [[ -n "$rail_w" ]]; then
        basis_w=$est_w; basis="estimated board input"
    fi
    if [[ -n "$basis_w" ]]; then
        echo
        echo "  Forecast at a constant ${basis_w} W (${basis}):"
        awk -v w="$basis_w" -v rate="$RATE" 'BEGIN {
            printf "    %-10s %8.2f Wh\n",  "per hour",   w
            printf "    %-10s %8.2f Wh\n",  "per day",    w * 24
            printf "    %-10s %8.3f kWh\n", "per 30 days", w * 24 * 30 / 1000
            printf "    %-10s %8.2f kWh\n", "per year",   w * 8760 / 1000
            if (rate != "") {
                printf "    at %s per kWh: %.4f per day, %.2f per 30 days, %.2f per year\n",
                       rate, w * 24 / 1000 * rate, w * 24 * 30 / 1000 * rate, w * 8760 / 1000 * rate
            } }'
        if [[ -n "$rail_w" && -z "$WALL" ]]; then
            awk -v w="$rail_w" 'BEGIN { printf "  (measured rails alone: %.2f Wh/h, %.2f Wh/day, %.2f kWh/year)\n", w, w * 24, w * 8760 / 1000 }'
            echo "  (a plug meter reading passed as --wall <watts> replaces the estimate)"
        fi
    fi
    # One grep-able record per run for averaging over the log (see header for the awk).
    echo
    printf 'trend ts=%s rail_w=%s est_w=%s wall_w=%s ext5v=%s samples=%d arm_mhz=%s soc_c=%s throttled=%s\n' \
        "${TS// /T}" "${rail_w:--}" "${est_w:--}" "${WALL:--}" "${ext5v:--}" "$SAMPLES" "${ARM_MHZ:--}" \
        "$( [[ "$SOC_TEMP" == temp=* ]] && { t=${SOC_TEMP#temp=}; echo "${t%\'C}"; } || echo '-' )" \
        "$( [[ "$RAW" == throttled=* ]] && echo "${RAW#throttled=}" || echo '-' )"
}

emit "===== power-report $TS — $MODEL ($( ((FULL)) && echo 'full' || echo 'default' )) ====="

section "vcgencmd get_throttled";                       report_throttled | tee -a "$LOG_FILE"
section "vcgencmd measure_volts (SoC rails)";           report_rails     | tee -a "$LOG_FILE"
section "PMIC ADC (vcgencmd pmic_read_adc)";            report_pmic      | tee -a "$LOG_FILE"
section "Supply contract (firmware: /proc/device-tree/chosen/power)"; report_supply | tee -a "$LOG_FILE"
section "Kernel view (sysfs hwmon) and temperatures";   report_kernel    | tee -a "$LOG_FILE"
section "Power summary and energy forecast";            report_summary   | tee -a "$LOG_FILE"

emit
emit "===== end power-report ====="
