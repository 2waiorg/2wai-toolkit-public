// Custom Flutter web bootstrap for the twai embed bundle.
//
// Flutter's default flutter_bootstrap.js (auto-generated when this file
// is absent) immediately calls loader.load() and boots the engine into
// <body> with no way to pass a hostElement. We need Flutter to mount
// inside the customer's custom element, so we override the template:
// load the engine loader + buildConfig, then stop and let embed.js
// call loader.load() once it has the host element.
//
// NOTE: Flutter's build substitutes the two template tokens below with
// the engine loader source and the runtime build config. The flutter.js
// substitution includes a multi-line template literal, so DO NOT put
// either token inside a // single-line comment — the substituted code
// will spill out across multiple lines and break the parse.
{{flutter_js}}
{{flutter_build_config}}

// Signal embed.js that loader + buildConfig are ready. If embed.js is
// already waiting (registered a callback), invoke it; otherwise set a
// flag so its later check sees we're ready.
window.__twaiFlutterReady = true;
if (typeof window.__twaiOnFlutterReady === 'function') {
  window.__twaiOnFlutterReady();
}
