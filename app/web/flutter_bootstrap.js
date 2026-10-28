{{flutter_js}}
{{flutter_build_config}}

// The renderer (canvaskit / skwasm) comes from this origin, never from gstatic.com: the page's Content Security Policy
// (index.html) allows scripts from 'self' only, and nothing in the app should depend on a CDN.
_flutter.loader.load({
  config: { canvasKitBaseUrl: 'canvaskit/' },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  }
});
