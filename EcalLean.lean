-- SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
-- SPDX-License-Identifier: MIT
/-!
# Eclipse eCAL from Lean

Publishers and subscribers over eCAL's C API (ffi/ecal_lean.c), local shared memory only.
`Publisher.sendWith` hands a closure a writable `View` of the memory file the message goes into;
`Subscriber.receive` hands one a read-only `View` of the memory file it arrived in. Neither view
can be read after its closure returns.
-/
namespace Ecal

opaque PublisherP : NonemptyType
def Publisher : Type := PublisherP.type
instance : Nonempty Publisher := PublisherP.property
opaque SubscriberP : NonemptyType
def Subscriber : Type := SubscriberP.type
instance : Nonempty Subscriber := SubscriberP.property
opaque ViewP : NonemptyType
def View : Type := ViewP.type
instance : Nonempty View := ViewP.property
opaque BufP : NonemptyType
/-- A host memory block: a frame being sent or assembled. -/
def Buf : Type := BufP.type
instance : Nonempty Buf := BufP.property

@[extern "el_initialize"] opaque start (unitName : @& String) (shmRegistration : Bool := true) : IO Unit
@[extern "el_finalize"] opaque stop : IO Unit
@[extern "el_version"] opaque version : IO String

/-- `zeroCopy` writes into the memory file in place; `ackMs > 0` makes each send wait until
every subscriber has released the message (no drops); `buffers` is the memory file count. -/
@[extern "el_pub_new"] opaque Publisher.new (topic : @& String) (zeroCopy : Bool) (ackMs buffers : UInt32) : IO Publisher
@[extern "el_pub_subscribers"] opaque Publisher.subscribers (p : @& Publisher) : IO UInt64
/-- Send a copy of `b`. Returns 0 when sent, non-zero otherwise. -/
@[extern "el_pub_send"] opaque Publisher.send (p : @& Publisher) (b : @& ByteArray) : IO UInt32
/-- Send `len` bytes that `f` writes in place. Returns eCAL's result: 0 when sent, non-zero otherwise. -/
@[extern "el_pub_send_with"] opaque Publisher.sendWith (p : @& Publisher) (len : UInt64) (f : @& (View → IO Unit)) : IO UInt32

@[extern "el_sub_new"] opaque Subscriber.new (topic : @& String) : IO Subscriber
@[extern "el_sub_publishers"] opaque Subscriber.publishers (s : @& Subscriber) : IO UInt64
/-- Wait up to `waitMs` for one message and run `f` on it in place. Returns the publisher's send
clock + 1, or 0 when nothing came. -/
@[extern "el_sub_receive"] opaque Subscriber.receive (s : @& Subscriber) (waitMs : UInt64) (f : @& (View → IO Unit)) : IO UInt64

@[extern "el_view_size"] opaque View.size (v : @& View) : UInt64
@[extern "el_view_u64"] opaque View.getU64 (v : @& View) (off : UInt64) : IO UInt64
@[extern "el_view_set_u64"] opaque View.setU64 (v : @& View) (off x : UInt64) : IO Unit
@[extern "el_view_read"] opaque View.read (v : @& View) (off n : UInt64) : IO ByteArray
@[extern "el_view_write"] opaque View.write (v : @& View) (off : UInt64) (b : @& ByteArray) : IO Unit
@[extern "el_view_fill"] opaque View.fill (v : @& View) (off n seed : UInt64) : IO Unit
@[extern "el_view_fnv"] opaque View.fnv (v : @& View) (off n : UInt64) : IO UInt64
@[extern "el_view_copy_from"] opaque View.copyFrom (v : @& View) (off : UInt64) (b : @& Buf) (boff n : UInt64) : IO Unit
@[extern "el_view_copy_to"] opaque View.copyTo (v : @& View) (off n : UInt64) (b : @& Buf) (boff : UInt64) : IO Unit

/-- `n` bytes filled from `seed` (xorshift64). -/
@[extern "el_buf_new"] opaque Buf.new (n seed : UInt64) : IO Buf
@[extern "el_buf_set_u64"] opaque Buf.setU64 (b : @& Buf) (off x : UInt64) : IO Unit
@[extern "el_buf_u64"] opaque Buf.getU64 (b : @& Buf) (off : UInt64) : IO UInt64
@[extern "el_buf_fnv"] opaque Buf.fnv (b : @& Buf) : IO UInt64

end Ecal
