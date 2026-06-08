# Private Experimentation: dynamic Swift field offsets

The old diagnostic that read `self + 0x8` and `self + 0x30` was wrong for `WAPrivateExperimentationViews.PrivateExperimentationDebugViewController`.
The real initializer in `WhatsApp(10)` stores the manager existential at the Swift runtime field offset loaded from `0x107d2f940`, and stores `userContext` at the field offset loaded from `0x107d2f938`.

Confirmed in `WhatsApp(10)`:

```asm
0x1040067a8: bl   0x101bfb2a8     ; build PrivateExperimentationManager
0x1040067c4: bl   0x104008030     ; returns dynamic manager field offset
0x1040067c8: add  x8, x19, x8
0x1040067cc: stp  x23, xzr, [x8]
0x1040067d0: stp  xzr, x0, [x8, #0x10]
0x1040067d4: str  x22, [x8, #0x20]
```

The tweak now logs the 40-byte Swift existential container from the real dynamic offset and, when the native manager exists, calls `requestPropsIfNeededWithCompletionHandler:` and reloads visible table views on completion.
