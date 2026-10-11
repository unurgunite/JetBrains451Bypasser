// ==UserScript==
// @name         JetBrains Redirect on 451
// @namespace    http://tampermonkey.net/
// @author       https://github.com/unurgunite
// @version      1.1
// @description  Redirects from download.jetbrains.com to download-cdn.jetbrains.com on 451 error
// @match        https://download.jetbrains.com/*
// @match        https://download-cdn.jetbrains.com/*
// @match        https://plugins.jetbrains.com/*
// @match        https://downloads.marketplace.jetbrains.com/*
// @grant        none
// @run-at       document-start
// ==/UserScript==

(function () {
  'use strict';

  // Hosts already on CDN/mirror — nothing to do, prevents redirect loops.
  var FINAL_HOSTS = [
    'download-cdn.jetbrains.com',
    'downloads.marketplace.jetbrains.com',
  ];

  var RULES = [
    {from: 'plugins.jetbrains.com', to: 'downloads.marketplace.jetbrains.com'},
    {from: 'download.jetbrains.com', to: 'download-cdn.jetbrains.com'},
  ];

  // Guard against redirect loops (e.g. mirror also returns 451):
  // only rewrite once per page load, remember retried URLs per tab.
  var RETRY_KEY = 'jb451_retried';
  var retried = [];
  try {
    retried = JSON.parse(sessionStorage.getItem(RETRY_KEY) || '[]');
  } catch (e) { /* storage unavailable — proceed without loop memory */ }

  function alreadyOnFinalHost(url) {
    for (var i = 0; i < FINAL_HOSTS.length; i++) {
      if (url.indexOf(FINAL_HOSTS[i]) !== -1) {
        return true;
      }
    }
    return false;
  }

  function rewrite(url) {
    for (var i = 0; i < RULES.length; i++) {
      if (url.indexOf(RULES[i].from) !== -1) {
        return url.replace(RULES[i].from, RULES[i].to);
      }
    }
    return null;
  }

  function doRedirect(newUrl) {
    if (!newUrl || newUrl === window.location.href) {
      return;
    }
    if (retried.indexOf(newUrl) !== -1) {
      console.warn('[jb451] already tried ' + newUrl + ' — not looping');
      return;
    }
    retried.push(newUrl);
    try {
      sessionStorage.setItem(RETRY_KEY, JSON.stringify(retried));
    } catch (e) { /* ignore */ }
    window.location.replace(newUrl);
  }

  function check() {
    var href = window.location.href;
    // Already on mirror host: only act if the page itself signals 451.
    // Otherwise the download/link is fine — stay.
    if (alreadyOnFinalHost(href)) {
      return;
    }
    var newUrl = rewrite(href);
    if (!newUrl) {
      return;
    }
    fetch(href, {method: 'HEAD', redirect: 'manual'})
      .then(function (response) {
        if (response.status === 451) {
          doRedirect(newUrl);
        }
      })
      .catch(function (error) {
        // HEAD is often blocked by CORS on these hosts — fall back to
        // checking the rendered error page for a 451 marker.
        var bodyText = (document.body && document.body.innerText) || '';
        if (/451|unavailable for legal reasons/i.test(document.title + ' ' + bodyText)) {
          doRedirect(newUrl);
        } else {
          console.error('[jb451] status check failed:', error);
        }
      });
  }

  // Run after DOM is readable for the CORS-fallback path.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', check);
  } else {
    check();
  }
})();
