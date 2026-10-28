{{flutter_js}}
{{flutter_build_config}}

// The renderer (canvaskit / skwasm) comes from this origin, never from gstatic.com: the page's Content Security Policy
// (index.html) allows scripts from 'self' only, and nothing in the app should depend on a CDN.
// Not changed: `fontFallbackBaseUrl`. `flutter build web` ships no fallback fonts (build/web/assets/fonts holds only the icon font
// and canvaskit/ no Roboto/Noto), so CanvasKit still fetches fallback glyphs for text outside IBM Plex (other scripts, emoji) from
// fonts.gstatic.com. That is a fetch(), allowed by `connect-src https:`, not a script or a CSS font. The app's own fonts are bundled.
_flutter.loader.load({
  config: { canvasKitBaseUrl: 'canvaskit/' },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  }
});
