-- SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
-- SPDX-License-Identifier: MIT
import Lake
open Lake DSL System

package «ecal-lean» where
  leanOptions := #[⟨`autoImplicit, false⟩]

/-- eCAL's source and build tree, made by scripts/build-ecal.sh at the pinned tag. -/
def ecalRoot (pkg : Package) : FilePath := pkg.dir / ".ecal"

target shim.o pkg : FilePath := do
  let src ← inputTextFile (pkg.dir / "ffi" / "ecal_lean.c")
  let e := ecalRoot pkg
  let includes := #["-I", (← getLeanIncludeDir).toString,
    "-I", (e / "src" / "lang" / "c" / "core" / "include").toString,
    "-I", (e / "build" / "lang" / "c" / "core" / "include").toString]
  buildO (pkg.buildDir / "ffi" / "ecal_lean.o") src includes #["-O2", "-fPIC", "-std=gnu11"] "cc"

extern_lib ecallean_ffi pkg := do
  let o ← shim.o.fetch
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "ecallean_ffi") #[o]

lean_lib EcalLean

@[default_target]
lean_exe ecallean where
  root := `Main
  moreLinkArgs := #["-L.ecal/build/lib", "-lecal_core_c", "-lecal_core",
    s!"-Wl,-rpath,{(__dir__ / ".ecal" / "build" / "lib").toString}"] ++
    (if System.Platform.isOSX then #[] else #["-lpthread"])
