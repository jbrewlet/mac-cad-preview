# Spike plate

A **40 × 24 × 8 mm** plate with a 12 mm bore and an 8 mm pin
standing on it. The same pair of parts as the mesh fixtures.

## Features

- 2 mm rounded edges
- Through bore at the plate centre
- Separate pin, standing on the top face

### Toolpath sketch

The G-code fixture mills the outline, then plunges the bore:

```
G0 X0 Y0
G1 X40.0 F800
G1 Y24.0
```

> First preview of a large file can take a while. This one will not.

See also [the README](https://github.com/jbrewlet/mac-cad-preview).
