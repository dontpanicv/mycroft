# Mycroft's web runtime

Served to the screen at `mycroft-ui://app/lib/`. It ships with the app and is the same for every generation.

- `preact.js` is htm 3.1.1's `preact/standalone.module.js`: Preact with hooks, plus `html` (htm bound to Preact).
  Exports: `h, html, render, Component, createContext, useState, useReducer, useEffect, useLayoutEffect, useRef,
  useImperativeHandle, useMemo, useCallback, useContext, useDebugValue, useErrorBoundary`.
  Preact is MIT (© Jason Miller); htm is Apache-2.0 (© Google LLC).
- `fonts/JetBrainsMono.ttf` and `fonts/SchibstedGrotesk.ttf` are the app's fonts (SIL OFL, see docs/licenses).
