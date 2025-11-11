# Skreenme Capture KIT

Native macOS screen, window, and camera capture module with audio support. Built with Swift and Node.js.

## Features

- Screen recording (full display, specific window, or region)
- Camera capture with customizable resolution and aspect ratio
- Audio capture from microphone
- Multiple simultaneous capture sources
- Mouse cursor tracking and recording
- Event-driven architecture
- TypeScript support with full type definitions
- Native Swift performance

## Requirements

- macOS 13.0 or later
- Node.js 14.0 or later
- Xcode Command Line Tools (for building from source)

## Installation

```bash
npm install @levskiy0/skreenme-capture-kit
```

The package includes a pre-built Swift binary, so no additional build steps are required for normal usage.

### Building from Source

If you need to rebuild the native Swift component (e.g., after modifying the source code):

```bash
# Navigate to the package directory
cd node_modules/@levskiy0/skreenme-capture-kit

# Build Swift binary and compile TypeScript
npm run build

# Or build components separately:
npm run build:swift  # Build only Swift binary
npm run build:ts     # Build only TypeScript
```

This will:
1. Build the Swift binary (`SkreenmeCaptureKIT`)
2. Compile TypeScript to JavaScript

**Note:** Building from source requires Xcode Command Line Tools to be installed.

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Credits

Created by [levskiy0](https://github.com/levskiy0)
