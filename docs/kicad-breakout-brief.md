# KiCad exercise: UART-to-USB breakout board

## Why this specific board

Because it continues a story you can already tell. You implemented a UART in Verilog and
verified it in simulation; this is the board that would let that UART talk to a PC. In an
interview it reads as one coherent thread ("I built the serial interface in RTL, then drew
the board-level circuit that carries it off-chip") rather than a disconnected tool exercise.

It is also genuinely simple: about a dozen components, no high-speed routing, no impedance
control, and every design decision has a reason you can articulate.

**Be honest about what this is.** After ~90 minutes you will have familiarity with schematic
capture in KiCad. That is worth saying. It is not PCB layout experience and it is not
production hardware, so do not let either be implied.

---

## The circuit

A USB-to-serial bridge that converts a PC's USB port into 3.3V TTL UART lines, with the
supporting power and protection circuitry.

```
   USB-C  ──►  FT232RL  ──►  TXD / RXD  ──►  header pins
   conn        bridge         (3.3V TTL)      to the target

               │
               └─►  3.3V regulator  ──►  decoupling caps  ──►  rail
```

### Bill of materials

| Ref | Component | Value / part | Purpose |
|---|---|---|---|
| J1 | USB-C receptacle | 16-pin, USB 2.0 | Host connection |
| U1 | USB-UART bridge | FT232RL (SSOP-28) | Protocol conversion |
| U2 | LDO regulator | AMS1117-3.3 | 5V from USB down to 3.3V |
| C1 | Bulk capacitor | 10 µF | Input bulk decoupling |
| C2, C3 | Ceramic capacitors | 100 nF | Local decoupling, one per supply pin |
| C4 | Output capacitor | 10 µF | LDO stability |
| C5 | Ferrite/filter cap | 100 nF | USB VBUS filtering |
| R1, R2 | Resistors | 27 Ω | USB D+/D− series termination |
| R3, R4 | Resistors | 5.1 kΩ | USB-C CC pulldowns, required for host detection |
| D1, D2 | LEDs + resistors | 3 mm, 330 Ω | TX and RX activity indication |
| J2 | Pin header | 6-pin 2.54 mm | Breakout: GND, VCC, TX, RX, RTS, CTS |

---

## Step by step

### 1. Set up (10 min)
Open **KiCad → Schematic Editor**. Save the project as `uart-usb-breakout`.

### 2. Place the bridge (15 min)
Press **A** to add a symbol, search `FT232RL`. If it isn't in the default library, use a
generic 28-pin IC symbol and rename it — the point is the circuit, not the exact footprint.

Place it centrally. The pins that matter: `USBDP`, `USBDM`, `TXD`, `RXD`, `VCC`, `VCCIO`,
`GND`, `3V3OUT`, `RESET`.

### 3. USB connector and its two non-obvious details (20 min)
Add the USB-C receptacle. Two things people get wrong and interviewers like asking about:

- **CC1 and CC2 each need a 5.1 kΩ pulldown to ground.** Without them, a USB-C host never
  detects the device and supplies no power at all. This is the single most common USB-C
  design mistake.
- **D+ and D− get 27 Ω series resistors** near the connector, for impedance matching to the
  differential pair.

Wire `D+ → R1 → USBDP` and `D− → R2 → USBDM`.

### 4. Power (20 min)
`VBUS` (5V from USB) → C1 (10 µF bulk) → AMS1117 input.
AMS1117 output → C4 (10 µF) → the 3.3V rail.
Place a **100 nF capacitor next to every supply pin** on the FT232RL.

Say out loud why: the bulk cap handles slow, large current swings; the 100 nF handles fast
transients and must be physically close to the pin because trace inductance would otherwise
defeat it. That reasoning is the actual content of this exercise.

### 5. Signals and indicators (15 min)
Bring `TXD` and `RXD` out to the 6-pin header along with GND and 3.3V. Add the two LEDs with
330 Ω series resistors on the activity pins.

### 6. Check your work (10 min)
Run **Inspect → Electrical Rules Checker**. Fix every error. Typical findings: unconnected
pins, missing power flags, conflicting outputs.

Add a `PWR_FLAG` symbol to your power nets — this is the fix for the "power input not driven"
error that confuses everyone their first time.

### 7. Export
`File → Export → Netlist`, and take a PNG or PDF of the schematic. Commit both to the repo so
there's an artifact to point at.

---

## What to say about it

**On the CV, under skills:** `KiCad schematic capture` — nothing stronger.

**If asked in interview:**
> "I drew a USB-to-UART breakout in KiCad to go with a UART controller I'd implemented in
> Verilog. Schematic capture, ERC clean, exported the netlist. I haven't done board layout or
> fabricated it, so I'd be learning the layout side."

That answer is honest, shows initiative, and pre-empts the follow-up rather than getting
caught by it.

**Three things worth being able to explain**, because they're the natural questions:
1. Why 5.1 kΩ on the CC pins (USB-C host detection).
2. Why both a 10 µF and a 100 nF cap rather than one bigger one (different frequency ranges;
   the small one must sit close to the pin).
3. Why 27 Ω on D+/D− (series termination for the differential pair).

---

## Result

Live at `hardware/uart-usb-breakout/`: `uart-usb-breakout.kicad_sch`, the exported netlist
(`uart-usb-breakout.net`), a rendered PDF, and the ERC report. Electrical rules check comes
back at **0 errors, 1 expected warning** (a cosmetic library-copy notice on the AMS1117-3.3
regulator, explained in the schematic's own title-block comment). Every net was checked by
hand against this brief's bill of materials -- CC1/CC2 pulldowns, D+/D- termination, both
LED activity indicators, and the 3.3V rail all land exactly where the BOM says they should.
