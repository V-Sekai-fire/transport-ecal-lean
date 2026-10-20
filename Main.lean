-- SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
-- SPDX-License-Identifier: MIT
import EcalLean
/-!
# ecallean: the two-process checks

`sub`/`pub` send N messages of varied size, each `[seq][fnv of payload][payload]`, written in
place in the memory file; the subscriber fails on a gap, a reorder or a wrong checksum.
Planted defects the subscriber must catch: `pub --skip K` never sends message K, and
`pub --corrupt K` changes one payload byte of message K after its checksum is written.

`fsub`/`fpub` send 3840x2160 RGBA frames (33,177,600 bytes), each as one message: the publisher
copies the frame into the memory file, the subscriber copies it out into its frame buffer.

Start-up: the subscriber pings a `ready` topic until the publisher's first message arrives; the
publisher waits for one ping and for its own subscriber count before sending, so message 0 is
not sent before the shared-memory link exists.
-/
open Ecal

def dataTopic : String := "ecallean_data"
def readyTopic : String := "ecallean_ready"
def frameBytes : UInt64 := 3840 * 2160 * 4
def ackMs : UInt32 := 5000

def msgLen (seq : UInt64) : UInt64 := 16 + (seq * 7919) % 60000
def seedOf (seq : UInt64) : UInt64 := seq * 2654435761 + 1

/-- ECALLEAN_REGISTRATION=udp keeps eCAL's UDP registration; anything else uses shared memory. -/
def shmRegistration : IO Bool := return (← IO.getEnv "ECALLEAN_REGISTRATION") != some "udp"

def fail (msg : String) : IO UInt32 := do IO.eprintln s!"FAIL {msg}"; return 1

/-- Receive `count` messages with `f`, pinging `ready` until the first one. Fails when nothing
arrives for `idleMs` once started, or for `startMs` before. -/
def receiveAll (s : Subscriber) (ready : Publisher) (count : Nat) (startMs idleMs : Nat)
    (f : View → IO Unit) : IO Unit := do
  let t0 ← IO.monoMsNow
  let mut got := 0
  let mut last := t0
  while got < count do
    if got == 0 then
      if (← s.publishers) > 0 then discard <| ready.send (ByteArray.mk #[1])
      if (← IO.monoMsNow) - t0 > startMs then throw <| IO.userError s!"no publisher within {startMs} ms"
    let c ← s.receive 20 f
    if c > 0 then
      got := got + 1; last ← IO.monoMsNow
    else if got > 0 && (← IO.monoMsNow) - last > idleMs then
      throw <| IO.userError s!"nothing arrived for {idleMs} ms after {got} messages"

/-- Wait for a subscriber's ready ping and for this publisher to see it. -/
def awaitSubscriber (p : Publisher) (ready : Subscriber) : IO Unit := do
  let t0 ← IO.monoMsNow
  let mut pinged := false
  while !pinged || (← p.subscribers) == 0 do
    if (← IO.monoMsNow) - t0 > 15000 then throw <| IO.userError "no subscriber within 15000 ms"
    if (← ready.receive 20 fun _ => pure ()) > 0 then pinged := true

def runSub (n : Nat) : IO UInt32 := do
  start "ecallean-sub" (← shmRegistration)
  let s ← Subscriber.new dataTopic
  let ready ← Publisher.new readyTopic false 0 0
  let next ← IO.mkRef (0 : UInt64)
  let bytes ← IO.mkRef (0 : UInt64)
  try
    receiveAll s ready n 15000 5000 fun v => do
      let want ← next.get
      let seq ← v.getU64 0
      if seq != want then throw <| IO.userError s!"expected message {want}, got {seq}"
      if v.size != msgLen seq then throw <| IO.userError s!"message {seq} is {v.size} bytes, expected {msgLen seq}"
      if (← v.fnv 16 (v.size - 16)) != (← v.getU64 8) then throw <| IO.userError s!"message {seq} checksum differs"
      next.set (want + 1); bytes.modify (· + v.size)
  catch e => return ← fail s!"sub: {e}"
  IO.println s!"OK sub {n} messages, {← bytes.get} bytes, in order, checksums match"
  stop
  return 0

def runPub (n : Nat) (skip corrupt : Option Nat) : IO UInt32 := do
  start "ecallean-pub" (← shmRegistration)
  let p ← Publisher.new dataTopic true ackMs 0
  let ready ← Subscriber.new readyTopic
  awaitSubscriber p ready
  for i in [0:n] do
    if skip == some i then continue
    let seq := i.toUInt64
    let len := msgLen seq
    let r ← p.sendWith len fun v => do
      v.setU64 0 seq
      v.fill 16 (len - 16) (seedOf seq)
      v.setU64 8 (← v.fnv 16 (len - 16))
      if corrupt == some i then v.setU64 16 ((← v.getU64 16) ^^^ 1)
    if r == 0 then return ← fail s!"pub: message {seq} reached no subscriber"
  IO.println s!"OK pub {n} messages"
  stop
  return 0

def runFrameSub (frames : Nat) : IO UInt32 := do
  start "ecallean-fsub" (← shmRegistration)
  let s ← Subscriber.new dataTopic
  let ready ← Publisher.new readyTopic false 0 0
  let dst ← Buf.new frameBytes 0
  let next ← IO.mkRef (0 : UInt64)
  let t0 ← IO.mkRef (0 : Nat)
  try
    receiveAll s ready frames 15000 10000 fun v => do
      let f ← next.get
      if f == 0 then t0.set (← IO.monoNanosNow)
      if v.size != frameBytes then throw <| IO.userError s!"frame {f} is {v.size} bytes"
      v.copyTo 0 frameBytes dst 0
      let stamp ← dst.getU64 0
      if stamp != f then throw <| IO.userError s!"expected frame {f}, got {stamp}"
      next.set (f + 1)
  catch e => return ← fail s!"fsub: {e}"
  let secs := ((← IO.monoNanosNow) - (← t0.get)).toFloat / 1e9
  let fps := (frames - 1).toFloat / secs
  IO.println s!"OK fsub {frames} frames of {frameBytes} bytes: {fps} fps, {fps * frameBytes.toFloat / 1e9} GB/s, last frame fnv {← dst.fnv}"
  stop
  return 0

def runFramePub (frames : Nat) : IO UInt32 := do
  start "ecallean-fpub" (← shmRegistration)
  let p ← Publisher.new dataTopic true ackMs 0
  let ready ← Subscriber.new readyTopic
  awaitSubscriber p ready
  let src ← Buf.new frameBytes 7
  for i in [0:frames] do
    src.setU64 0 i.toUInt64
    let r ← p.sendWith frameBytes fun v => v.copyFrom 0 src 0 frameBytes
    if r == 0 then return ← fail s!"fpub: frame {i} reached no subscriber"
  IO.println s!"OK fpub {frames} frames, last frame fnv {← src.fnv}"
  stop
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["version"] => do IO.println (← version); return 0
  | ["sub", n] => runSub n.toNat!
  | ["pub", n] => runPub n.toNat! none none
  | ["pub", n, "--skip", k] => runPub n.toNat! (some k.toNat!) none
  | ["pub", n, "--corrupt", k] => runPub n.toNat! none (some k.toNat!)
  | ["fsub", n] => runFrameSub n.toNat!
  | ["fpub", n] => runFramePub n.toNat!
  | _ =>
    IO.eprintln "usage: ecallean version | (sub|pub|fsub|fpub) N [--skip K | --corrupt K]"
    return 2
