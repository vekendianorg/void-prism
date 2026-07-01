<p align="center">
  <img src="./assets/logo.png" alt="Void Prism Logo" width="420"/>
</p>

# Void Prism

> The first mod pack loader for Hill Climb Racing 2.

Void Prism is an open-source mod pack loader and format designed for Hill Climb Racing 2. It is part of the VEKENDIAN ecosystem and is designed to be embedded into Void while remaining a standalone project for mod pack creators.

## Features

- Simple `manifest.json` format
- Modular package-based structure
- JSON merging for supported game data
- Automatic `.packages` generation and checksum handling
- Multiple mod packs with configurable priority
- Lua reference implementation

## Status

Early development.

Current focus:
- Package loader
- Builder
- Validator
- `.packages` support

Future:
- Events
- Seasons
- Shop
- Standalone creator application

## Repository Layout

```
docs/        Documentation
examples/    Example mod packs
luajava/     Lua implementation
schema/      Manifest schema
app/         Future creator application
```
