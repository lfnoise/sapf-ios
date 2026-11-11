//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Registers public/sw.js. The page is only cross-origin isolated when its navigation was handled by the service
// worker. That is not the case on the very first visit (the worker isn't installed yet) or after a hard reload
// (which bypasses service workers), so in those cases the page reloads once, normally, once the worker is active.

const reloadKey = 'sapf-sw-reload';

/** Returns false if the page is about to reload. */
export async function ensureServiceWorker(base: string): Promise<boolean> {
  try {
    await navigator.serviceWorker.register(`${base}sw.js`, { scope: base });
    if (self.crossOriginIsolated) {
      sessionStorage.removeItem(reloadKey);
      return true;
    }
    // reload at most once per tab session, so a browser that never isolates the page can't loop.
    if (sessionStorage.getItem(reloadKey)) return true;
    await navigator.serviceWorker.ready;
    sessionStorage.setItem(reloadKey, '1');
    location.reload();
    return false;
  } catch (e) {
    console.warn('service worker registration failed', e);
    return true;
  }
}
