// ==UserScript==
// @name         JetBrains Redirect on 451
// @namespace    http://tampermonkey.net/
// @author       https://github.com/unurgunite
// @version      1.0
// @description  Redirects from download.jetbrains.com to download-cdn.jetbrains.com on 451 error
// @match        https://download.jetbrains.com/*
// @match        https://plugins.jetbrains.com/*
// @grant        none
// ==/UserScript==

(function() {
    'use strict';
    fetch(window.location.href, { method: 'HEAD' })
        .then(response => {
        if (response.status === 451) {
            let originalUrl = window.location.href;
            let newUrl = null;
            if (originalUrl.match(/plugins.jetbrains.com/)) {
                newUrl = window.location.href.replace('plugins.jetbrains.com', 'downloads.marketplace.jetbrains.com');
            } else if (originalUrl.match(/download.jetbrains.com/)) {
                newUrl = window.location.href.replace('download.jetbrains.com', 'download-cdn.jetbrains.com');
            }
            window.location.replace(newUrl);
        }
    })
        .catch(error => {
        console.error('Error checking status:', error);
    });
})();

